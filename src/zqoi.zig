const std = @import("std");
const Allocator = std.mem.Allocator;

const QoiOpRgb = 0b1111_1110;
const QoiOpRgba = 0b1111_1111;
const QoiOpIndex = 0b0000_0000;
const QoiOpDiff = 0b0100_0000;
const QoiOpLuma = 0b1000_0000;
const QoiOpRun = 0b1100_0000;

pub const DecodeError = error {
    TooShort,
    BadMagic,
    InvalidWidth,
    InvalidHeight,
    InvalidChannels,
    InvalidColorspace,
};

pub const Rgba = struct {
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

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.pixels);
    }

    pub fn fromMemory(allocator: Allocator, data: []const u8) !Self {
        var image: Image = undefined;
        image.allocator = allocator;

        try decodeFile(image.allocator, data, &image);
        return image;
    }

    pub fn fromFilePath(allocator: Allocator, path: []const u8) !Self {
        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const file_data = try file.reader().readAllAlloc(allocator, std.math.maxInt(usize));
        defer allocator.free(file_data);

        return try Image.fromMemory(allocator, file_data);
    }

    pub fn toFilePath(self: *const @This(), file_path: []const u8) !void {
        const header = FileHeader{
            .width = self.width,
            .height = self.height,
            .channels = self.format.toChannels(),
            .colorspace = self.format.toColorspace(),
        };

        const stream_end = [_]u8{
            0, 0, 0, 0, 0, 0, 0, 1
        };

        var encoded_data = try std.ArrayList(u8).initCapacity(
            self.allocator,
            self.pixels.len * 5 + @sizeOf(FileHeader) + stream_end.len,
        );
        defer encoded_data.deinit();

        try encodeHeader(encoded_data.fixedWriter(), &header);
        try encodeData(encoded_data.fixedWriter(), self.pixels);
        encoded_data.appendSliceAssumeCapacity(&stream_end);

        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();

        _ = try file.writeAll(encoded_data.items);
    }
};

pub const FileHeader = struct {
    magic: []const u8 = "qoif",
    width: u32,
    height: u32,
    channels: u8 = 4,
    colorspace: Colorspace = .srgb,
};

fn pixelCmp(pixel_1: Rgba, pixel_2: Rgba) bool {
    return std.meta.eql(pixel_1, pixel_2);
}

fn pixelHash(pixel: Rgba) u8 {
    return @intCast((
        @as(usize, pixel.r) * 3 +
        @as(usize, pixel.g) * 5 +
        @as(usize, pixel.b) * 7 +
        @as(usize, pixel.a) * 11) % 64);
}

fn checkLuma(diff: Rgba) bool {
    if ((diff.g +% 32) >= 64) return false;
    if ((diff.r -% diff.g +% 8) >= 16) return false;
    if ((diff.b -% diff.g +% 8) >= 16) return false;
    return true;
}

fn checkDiff(diff: Rgba) bool {
    if ((diff.r +% 2) >= 4) return false;
    if ((diff.g +% 2) >= 4) return false;
    if ((diff.b +% 2) >= 4) return false;
    return true;
}

fn colorDiff(pixel_1: Rgba, pixel_2: Rgba) Rgba {
    const diff = Rgba{
        .r = pixel_2.r -% pixel_1.r,
        .g = pixel_2.g -% pixel_1.g,
        .b = pixel_2.b -% pixel_1.b,
        .a = 0,
    };

    return diff;
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
                try writer.writeByte(0b11000000 + 61);
                current_run = 0;
            }

            continue;
        }

        if (current_run > 0) {
            try writer.writeByte(0b11000000 + current_run - 1);
            current_run = 0;
        }
        
        const lookup_index = pixelHash(current_pixel);

        // QOI_OP_INDEX
        if (pixelCmp(lookup_array[lookup_index], current_pixel)) {
            try writer.writeByte(@intCast(lookup_index));

        } else blk: {
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
                    0b01000000 + (0b010000 * (color_diff.r +% 2)) +
                    (0b0100 * (color_diff.g +% 2)) + (0b01 * (color_diff.b +% 2))
                );

                break :blk;
            }

            // QOI_OP_LUMA
            if (checkLuma(color_diff)) {
                try writer.writeAll(&[_]u8{
                    0b10000000 + (color_diff.g +% 32),
                    0b010000 * (color_diff.r -% color_diff.g +% 8) + (color_diff.b -% color_diff.g +% 8),
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
        try writer.writeByte(0b11000000 + current_run - 1);
    }
}

const PixelReader = struct {
    data: []const u8,
    index: usize = 0,

    pub fn readByte(self: *@This()) !u8 {
        if (self.index >= self.data.len) {
            return error.QoiDecodeReadOutOfBounds;
        }
        
        self.index += 1;
        return self.data[self.index - 1];
    }
};

fn decodeFile(allocator: Allocator, data: []const u8, image: *Image) !void {
    // File must be larger than 'header' + 'stream end'
    if (data.len <= 14 + 8) return DecodeError.TooShort;

    if (!std.mem.eql(u8, data[0..4], "qoif")) return DecodeError.BadMagic;
    if (std.mem.readInt(u32, data[4..8], .big) == 0) return DecodeError.InvalidWidth;
    if (std.mem.readInt(u32, data[4..8], .big) == 0) return DecodeError.InvalidHeight;
    if (data[12] < 3 or data[12] > 4) return DecodeError.InvalidChannels;
    if (data[13] > 1) return DecodeError.InvalidColorspace;

    const header = FileHeader{
        .magic = data[0..4],
        .width = std.mem.readInt(u32, data[4..8], .big),
        .height = std.mem.readInt(u32, data[8..12], .big),
        .channels = data[12],
        .colorspace = @enumFromInt(data[13]),
    };
    // Header processing end

    var lookup_array: [64]Rgba = undefined;
    @memset(&lookup_array, Rgba{ .r = 0, .g = 0, .b = 0, .a = 0 });

    var current_pixel = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };
    var current_run: u8 = 0;

    var pixel_reader = PixelReader {
        .data = data[14..(data.len - 8)],
    };

    const pixels = try allocator.alloc(Rgba, header.width * header.height);
    errdefer allocator.free(pixels);

    const mask2: u8 = 0b1100_0000;

    for (pixels) |*pixel| {
        if (current_run > 0) {
            current_run -= 1;
        }
        else if (pixel_reader.index < pixel_reader.data.len) {
            const b1: u8 = try pixel_reader.readByte();

            // QOI_OP_RGB
            if (b1 == QoiOpRgb) {
                current_pixel.r = try pixel_reader.readByte(); 
                current_pixel.g = try pixel_reader.readByte();
                current_pixel.b = try pixel_reader.readByte();
            }
            // QOI_OP_RGBA
            else if (b1 == QoiOpRgba) {
                current_pixel.r = try pixel_reader.readByte(); 
                current_pixel.g = try pixel_reader.readByte();
                current_pixel.b = try pixel_reader.readByte();
                current_pixel.a = try pixel_reader.readByte();
            }
            // QOI_OP_INDEX
            else if ((b1 & mask2) == QoiOpIndex) {
                current_pixel = lookup_array[b1];
            }
            // QOI_OP_DIFF
            else if ((b1 & mask2) == QoiOpDiff) {
                current_pixel.r +%= ((b1 >> 4) & 0x03) -% 2;
                current_pixel.g +%= ((b1 >> 2) & 0x03) -% 2;
                current_pixel.b +%= ( b1       & 0x03) -% 2;
            }
            // QOI_OP_LUMA
            else if ((b1 & mask2) == QoiOpLuma) {
                const b2: u8 = try pixel_reader.readByte();
                const vg: u8 = (b1 & 0x3f) -% 32;
                current_pixel.r +%= vg -% 8 +% ((b2 >> 4) & 0x0f);
                current_pixel.g +%= vg;
                current_pixel.b +%= vg -% 8 +%  (b2       & 0x0f);
            }
            // QOI_OP_RUN
            else if ((b1 & mask2) == QoiOpRun) {
                    current_run = (b1 & 0x3f);
            }

            lookup_array[pixelHash(current_pixel) & (64 - 1)] = current_pixel;
        }

        pixel.r = current_pixel.r;
        pixel.g = current_pixel.g;
        pixel.b = current_pixel.b;

        if (header.channels == 4) pixel.a = current_pixel.a
        else pixel.a = 255;
    }

    image.width = header.width;
    image.height = header.height;
    image.format = ImageFormat.new(header.colorspace, header.channels);
    image.pixels = pixels;
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

    var touch = try std.fs.cwd().makeOpenPath("test", .{});
    touch.close();
    try image.toFilePath("test/simple.qoi");
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

    var touch = try std.fs.cwd().makeOpenPath("test", .{});
    touch.close();
    try image.toFilePath("test/random.qoi");
}

test "read" {
    const allocator = std.testing.allocator;

    var img = try Image.fromFilePath(allocator, "test/random.qoi");
    try img.toFilePath("test/copy_random.qoi");
    img.deinit();

    img = try Image.fromFilePath(allocator, "test/simple.qoi");
    try img.toFilePath("test/copy_simple.qoi");
    img.deinit();
}

// This will probably throw errors but as long as
// 'Fuzz finished' gets printed it's fine
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
                    .width = rng.int(u14),
                    .height = rng.int(u14),
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
