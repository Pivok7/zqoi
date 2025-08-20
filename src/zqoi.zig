const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const QoiOp = struct {
    pub const Rgb = 0b1111_1110;
    pub const Rgba = 0b1111_1111;
    pub const Index = 0b0000_0000;
    pub const Diff = 0b0100_0000;
    pub const Luma = 0b1000_0000;
    pub const Run = 0b1100_0000;
};

pub const QoiStreamEnd = [_]u8{
    0, 0, 0, 0, 0, 0, 0, 1
};

pub const EncodeError = error {
    InvalidSize,
    CorruptedHeader,
};

pub const DecodeError = error {
    FileTooShort,
    NotQoi,
    InvalidWidth,
    InvalidHeight,
    InvalidChannels,
    InvalidColorspace,
    OutOfBoundsRead,
    LeftoverData,
};

pub const Rgba = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8
};

pub const Colorspace = enum(u8) {
    srgb = 0,
    linear = 1,
};

pub const ImageFormat = enum(u8) {
    r8g8b8_linear,
    r8g8b8a8_linear,
    r8g8b8_srgb,
    r8g8b8a8_srgb,

    pub fn new(colorspace: Colorspace, channels: u8) @This() {
        return switch (colorspace) {
            .linear => switch (channels) {
                3 => .r8g8b8_linear,
                4 => .r8g8b8a8_linear,
                else => unreachable
            },
            .srgb => switch (channels) {
                3 => .r8g8b8_srgb,
                4 => .r8g8b8a8_srgb,
                else => unreachable,
            }
        };
    }

    pub fn toChannels(self: *const @This()) u8 {
        switch (self.*) {
            .r8g8b8_linear, .r8g8b8_srgb => return 3,
            .r8g8b8a8_linear, .r8g8b8a8_srgb => return 4,
        }
    }

    pub fn toColorspace(self: *const @This()) Colorspace {
        switch (self.*) {
            .r8g8b8_srgb, .r8g8b8a8_srgb => return .srgb,
            .r8g8b8_linear, .r8g8b8a8_linear => return .linear,
        }
    }
};

pub const Image = struct {
    const Self = @This();

    allocator: Allocator,
    width: u32,
    height: u32,
    pixels: []Rgba,
    format: ImageFormat,

    pub fn deinit(self: *const Self) void {
        self.allocator.free(self.pixels);
    }

    pub fn fromMemory(allocator: Allocator, data: []const u8) !Self {
        var image: Image = undefined;
        image.allocator = allocator;

        const header = try decodeHeader(data);
        image.width = header.width;
        image.height = header.height;
        image.format = ImageFormat.new(header.colorspace, header.channels);

        image.pixels = try allocator.alloc(Rgba, header.width * header.height);
        errdefer allocator.free(image.pixels);

        // We create reader from the fragment containing only the pixel info
        var pixel_reader = FastReader{
            .data = data[14..(data.len - 8)],
        };

        try decodeData(header, image.pixels, &pixel_reader);
        return image;
    }

    pub fn fromFilePath(allocator: Allocator, path: []const u8) !Self {
        var file = try std.fs.cwd().openFile(path, .{});

        const file_data = file.reader().readAllAlloc(allocator, std.math.maxInt(usize)) catch |err| {
            file.close();
            return err;
        };
        defer allocator.free(file_data);

        file.close();

        return try Image.fromMemory(allocator, file_data);
    }

    pub fn toFilePath(self: *const @This(), file_path: []const u8) !void {
        if (!self.isValidSize()) return EncodeError.InvalidSize;
        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();

        var encoded_data = try std.ArrayList(u8).initCapacity(
            self.allocator,
            self.pixels.len * (self.format.toChannels() + 1) + @sizeOf(FileHeader) + QoiStreamEnd.len,
        );
        defer encoded_data.deinit();

        try self.toMemory(encoded_data.writer());

        _ = try file.writeAll(encoded_data.items);
    }

    pub fn toMemory(self: *const Self, writer: anytype) !void {
        if (!self.isValidSize()) return EncodeError.InvalidSize;

        const header = FileHeader{
            .width = self.width,
            .height = self.height,
            .channels = self.format.toChannels(),
            .colorspace = self.format.toColorspace(),
        };

        if (!header.isValid()) return EncodeError.CorruptedHeader;

        try encodeHeader(writer, &header);
        try encodeData(writer, self.pixels);
        _ = try writer.writeAll(&QoiStreamEnd);
    }

    pub fn isValidSize(self: *const Self) bool {
        return (self.width * self.height == self.pixels.len);
    }
};

pub const FileHeader = struct {
    magic: []const u8 = "qoif",
    width: u32,
    height: u32,
    channels: u8 = 4,
    colorspace: Colorspace = .srgb,

    pub fn isValid(self: *const @This()) bool {
        if (!std.mem.eql(u8, self.magic, "qoif")) return false;
        if (self.width == 0) return false;
        if (self.height == 0) return false;
        if (self.channels < 3 or self.channels > 4) return false;
        // Don't need to check the colorspace since it's an enum
        return true;
    }
};

const FastReader = struct {
    data: []const u8,
    pos: usize = 0,

    pub inline fn readUnsafe(self: *@This()) u8 {
        self.pos += 1;
        return self.data[self.pos - 1];
    }

    pub fn readSafe(self: *@This()) DecodeError!u8 {
        if (self.pos >= self.data.len) {
            return DecodeError.OutOfBoundsRead;
        }

        self.pos += 1;
        return self.data[self.pos - 1];
    }
};

inline fn pixelCmp(a: Rgba, b: Rgba) bool {
    return @as(u32, @bitCast(a)) == @as(u32, @bitCast(b));
}

inline fn pixelHash(pixel: Rgba) u8 {
    const vp: @Vector(4, u8) = @bitCast(pixel);
    const weights = @Vector(4, u8){ 3, 5, 7, 11 };
    const sum = @reduce(.Add, vp *% weights);
    return @truncate(sum & 63);
}

inline fn checkLuma(diff: Rgba) bool {
    if ((diff.g +% 32) >= 64) return false;
    if ((diff.r -% diff.g +% 8) >= 16) return false;
    if ((diff.b -% diff.g +% 8) >= 16) return false;
    return true;
}

inline fn checkDiff(diff: Rgba) bool {
    if ((diff.r +% 2) >= 4) return false;
    if ((diff.g +% 2) >= 4) return false;
    if ((diff.b +% 2) >= 4) return false;
    return true;
}

inline fn colorDiff(a: Rgba, b: Rgba) Rgba {
    return .{
        .r = b.r -% a.r,
        .g = b.g -% a.g,
        .b = b.b -% a.b,
        .a = 0,
    };
}

fn encodeHeader(writer: anytype, header: *const FileHeader) !void {
    try writer.writeAll(header.magic);
    try writer.writeInt(u32, header.width, .big);
    try writer.writeInt(u32, header.height, .big);
    try writer.writeByte(header.channels);
    try writer.writeByte(@intFromEnum(header.colorspace));
}

fn encodeData(writer: anytype, data: []Rgba) !void {
    var lookup_array: [64]Rgba = undefined;
    @memset(&lookup_array, Rgba{ .r = 0, .g = 0, .b = 0, .a = 0 });

    var current_run: u8 = 0;
    var previous_pixel = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };

    for (data) |current_pixel| {
        // QOI_OP_RUN
        if (pixelCmp(current_pixel, previous_pixel)) {
            current_run += 1;

            if (current_run >= 62) {
                try writer.writeByte(QoiOp.Run + 61);
                current_run = 0;
            }

            continue;
        }

        if (current_run > 0) {
            try writer.writeByte(QoiOp.Run + current_run - 1);
            current_run = 0;
        }

        const lookup_index = pixelHash(current_pixel);

        // QOI_OP_INDEX
        if (pixelCmp(lookup_array[lookup_index], current_pixel)) {
            try writer.writeByte(@intCast(lookup_index));

        } else blk: {
            @branchHint(.likely);
            lookup_array[lookup_index] = current_pixel;

            // QOI_OP_RGBA
            if (previous_pixel.a != current_pixel.a) {
                try writer.writeAll(&[_]u8{
                    255,
                    current_pixel.r,
                    current_pixel.g,
                    current_pixel.b,
                    current_pixel.a,
                });

                break :blk;
            }

            // QOI_OP_DIFF
            const color_diff = colorDiff(previous_pixel, current_pixel);
            if (checkDiff(color_diff)) {
                try writer.writeByte(
                    QoiOp.Diff + (0b01_0000 * (color_diff.r +% 2)) +
                    (0b0100 * (color_diff.g +% 2)) + (0b01 * (color_diff.b +% 2))
                );

                break :blk;
            }

            // QOI_OP_LUMA
            if (checkLuma(color_diff)) {
                @branchHint(.likely);
                try writer.writeAll(&[_]u8{
                    QoiOp.Luma + (color_diff.g +% 32),
                    0b01_0000 * (color_diff.r -% color_diff.g +% 8) + (color_diff.b -% color_diff.g +% 8),
                });

                break :blk;
            }

            // QOI_OP_RGB
            try writer.writeAll(&[_]u8{
                254,
                current_pixel.r,
                current_pixel.g,
                current_pixel.b,
            });
        }

        previous_pixel = current_pixel;
    }

    // Write leftover run
    if (current_run > 0) {
        try writer.writeByte(QoiOp.Run + current_run - 1);
    }
}

fn decodeHeader(data: []const u8) DecodeError!FileHeader {
    // File must be larger than 'header' + 'stream_end'
    if (data.len <= 14 + QoiStreamEnd.len) return DecodeError.FileTooShort;

    if (!std.mem.eql(u8, data[0..4], "qoif")) return DecodeError.NotQoi;
    if (std.mem.readInt(u32, data[4..8], .big) == 0) return DecodeError.InvalidWidth;
    if (std.mem.readInt(u32, data[8..12], .big) == 0) return DecodeError.InvalidHeight;
    if (data[12] < 3 or data[12] > 4) return DecodeError.InvalidChannels;
    if (data[13] > 1) return DecodeError.InvalidColorspace;

    return .{
        .magic = data[0..4],
        .width = std.mem.readInt(u32, data[4..8], .big),
        .height = std.mem.readInt(u32, data[8..12], .big),
        .channels = data[12],
        .colorspace = @enumFromInt(data[13]),
    };
}

fn decodeData(header: FileHeader, pixels: []Rgba, reader: *FastReader) DecodeError!void {
    const channel_mask: u8 = if (header.channels == 3) 0xff else 0x00;

    var lookup_array: [64]Rgba = undefined;
    @memset(&lookup_array, Rgba{ .r = 0, .g = 0, .b = 0, .a = 0 });

    var current_pixel = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };
    var current_run: u8 = 0;

    const mask2: u8 = 0b1100_0000;

    for (pixels) |*pixel| {
        if (current_run > 0) {
            current_run -= 1;
        }
        // We only check array bounds if we are close to the array length
        // Unsafe version
        else if (reader.pos < reader.data.len - 4) {
            const b1: u8 = reader.readUnsafe();

            // QOI_OP_RGB
            if (b1 == QoiOp.Rgb) {
                current_pixel.r = reader.readUnsafe();
                current_pixel.g = reader.readUnsafe();
                current_pixel.b = reader.readUnsafe();
            }
            // QOI_OP_RGBA
            else if (b1 == QoiOp.Rgba) {
                current_pixel.r = reader.readUnsafe();
                current_pixel.g = reader.readUnsafe();
                current_pixel.b = reader.readUnsafe();
                current_pixel.a = reader.readUnsafe() | channel_mask;
            }
            // QOI_OP_INDEX
            else if ((b1 & mask2) == QoiOp.Index) {
                @branchHint(.likely);
                current_pixel = lookup_array[b1];
            }
            // QOI_OP_DIFF
            else if ((b1 & mask2) == QoiOp.Diff) {
                current_pixel.r +%= ((b1 >> 4) & 0x03) -% 2;
                current_pixel.g +%= ((b1 >> 2) & 0x03) -% 2;
                current_pixel.b +%= ( b1       & 0x03) -% 2;
            }
            // QOI_OP_LUMA
            else if ((b1 & mask2) == QoiOp.Luma) {
                @branchHint(.likely);
                const b2: u8 = reader.readUnsafe();
                const vg: u8 = (b1 & 0x3f) -% 32;
                current_pixel.r +%= vg -% 8 +% ((b2 >> 4) & 0x0f);
                current_pixel.g +%= vg;
                current_pixel.b +%= vg -% 8 +%  (b2       & 0x0f);
            }
            // QOI_OP_RUN
            else if ((b1 & mask2) == QoiOp.Run) {
                current_run = (b1 & 0x3f);
            }

            lookup_array[pixelHash(current_pixel)] = current_pixel;
        // Safe version
        } else {
            @branchHint(.cold);
            const b1: u8 = try reader.readSafe();

            // QOI_OP_RGB
            if (b1 == QoiOp.Rgb) {
                current_pixel.r = try reader.readSafe();
                current_pixel.g = try reader.readSafe();
                current_pixel.b = try reader.readSafe();
            }
            // QOI_OP_RGBA
            else if (b1 == QoiOp.Rgba) {
                current_pixel.r = try reader.readSafe();
                current_pixel.g = try reader.readSafe();
                current_pixel.b = try reader.readSafe();
                current_pixel.a = try reader.readSafe() | channel_mask;
            }
            // QOI_OP_INDEX
            else if ((b1 & mask2) == QoiOp.Index) {
                current_pixel = lookup_array[b1];
            }
            // QOI_OP_DIFF
            else if ((b1 & mask2) == QoiOp.Diff) {
                current_pixel.r +%= ((b1 >> 4) & 0x03) -% 2;
                current_pixel.g +%= ((b1 >> 2) & 0x03) -% 2;
                current_pixel.b +%= ( b1       & 0x03) -% 2;
            }
            // QOI_OP_LUMA
            else if ((b1 & mask2) == QoiOp.Luma) {
                const b2: u8 = try reader.readSafe();
                const vg: u8 = (b1 & 0x3f) -% 32;
                current_pixel.r +%= vg -% 8 +% ((b2 >> 4) & 0x0f);
                current_pixel.g +%= vg;
                current_pixel.b +%= vg -% 8 +%  (b2       & 0x0f);
            }
            // QOI_OP_RUN
            else if ((b1 & mask2) == QoiOp.Run) {
                current_run = (b1 & 0x3f);
            }

            lookup_array[pixelHash(current_pixel)] = current_pixel;
        }

        pixel.* = current_pixel;
    }

    if (reader.pos < reader.data.len) {
        return DecodeError.LeftoverData;
    }
}

test "simple_encode" {
    const allocator = std.testing.allocator;

    var image = Image{
        .allocator = allocator,
        .width = 1024,
        .height = 1024,
        .pixels = undefined,
        .format = .r8g8b8a8_srgb,
    };

    image.pixels = try allocator.alloc(Rgba, image.width * image.height);
    defer allocator.free(image.pixels);

    for (image.pixels, 0..) |*pixel, i| {
        pixel.* = Rgba{
            .r = @as(u8, @intCast(i % 256)),
            .g = @as(u8, @intCast(i % 128)),
            .b = @as(u8, @intCast(i % 64)),
            .a = 255,
        };
    }

    var touch = try std.fs.cwd().makeOpenPath("tests_output", .{});
    touch.close();
    try image.toFilePath("tests_output/simple.qoi");
}

test "noise" {
    const allocator = std.testing.allocator;

    var prng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const rand = prng.random();

    var image = Image{
        .allocator = allocator,
        .width = 1024,
        .height = 1024,
        .pixels = undefined,
        .format = .r8g8b8a8_srgb,
    };

    image.pixels = try allocator.alloc(Rgba, image.width * image.height);
    defer allocator.free(image.pixels);

    for (image.pixels) |*pixel| {
        pixel.* = Rgba{
            .r = rand.int(u8),
            .g = rand.int(u8),
            .b = rand.int(u8),
            .a = rand.int(u8),
        };
    }

    var touch = try std.fs.cwd().makeOpenPath("tests_output", .{});
    touch.close();
    try image.toFilePath("tests_output/random.qoi");
}

test "read_write" {
    const allocator = std.testing.allocator;

    var img = try Image.fromFilePath(allocator, "tests_output/random.qoi");
    try img.toFilePath("tests_output/copy_random.qoi");
    img.deinit();

    var file_1 = try std.fs.cwd().openFile("tests_output/random.qoi", .{});
    var file_2 = try std.fs.cwd().openFile("tests_output/copy_random.qoi", .{});
    var file_1_data = try file_1.readToEndAlloc(allocator, std.math.maxInt(usize));
    var file_2_data = try file_2.readToEndAlloc(allocator, std.math.maxInt(usize));

    if (!std.mem.eql(u8, file_1_data, file_2_data)) {
        std.log.err("random.qoi: input != output!", .{});
        return error.CorruptedOutput;
    }

    allocator.free(file_1_data);
    allocator.free(file_2_data);
    file_1.close();
    file_2.close();

    img = try Image.fromFilePath(allocator, "tests_output/simple.qoi");
    try img.toFilePath("tests_output/copy_simple.qoi");
    img.deinit();

    file_1 = try std.fs.cwd().openFile("tests_output/simple.qoi", .{});
    file_2 = try std.fs.cwd().openFile("tests_output/copy_simple.qoi", .{});
    file_1_data = try file_1.readToEndAlloc(allocator, std.math.maxInt(usize));
    file_2_data = try file_2.readToEndAlloc(allocator, std.math.maxInt(usize));

    if (!std.mem.eql(u8, file_1_data, file_2_data)) {
        std.log.err("simple.qoi: input != output!", .{});
        return error.CorruptedOutput;
    }

    allocator.free(file_1_data);
    allocator.free(file_2_data);
    file_1.close();
    file_2.close();
}

// Fuzzer taken from https://github.com/ikskuh/zig-qoi
test "input fuzzer" {
    const allocator = std.testing.allocator;

    var rng_engine = std.Random.DefaultPrng.init(0x1337);
    const rng = rng_engine.random();

    var rounds: usize = 32;
    while (rounds > 0) {
        rounds -= 1;
        var input_buffer: [1 << 20]u8 = undefined; // perform on a 1 MB buffer
        rng.bytes(&input_buffer);

        if ((rounds % 4) != 0) { // 25% is fully random 75% has a correct looking header
            var header: [14]u8 = undefined;
            var header_stream = std.io.fixedBufferStream(&header);

            try encodeHeader(header_stream.writer(),
                &FileHeader{
                    .width = rng.int(u16),
                    .height = rng.int(u16),
                    .channels = rng.int(u8) % 2 + 3,
                    .colorspace = @enumFromInt(rng.int(u8) % 2),
                }
            );
            @memcpy(input_buffer[0..header.len], &header);
        }

        var image_or_err = Image.fromMemory(allocator, &input_buffer);
        if (image_or_err) |*image| {
            defer image.deinit();
        } else |err| {
            // error is also okay, just no crashes plz
            err catch {};
        }
    }
}
