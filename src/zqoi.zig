const std = @import("std");
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

const DecodeErrorSet = (
    DecodeError || std.Io.Reader.Error || Allocator.Error
);

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

    width: u32,
    height: u32,
    pixels: []Rgba,
    format: ImageFormat,

    pub fn fromBuf(
        allocator: Allocator,
        data: []const u8
    ) DecodeErrorSet!Self {
        var image: Image = undefined;

        const header = try decodeHeader(data);
        image.width = header.width;
        image.height = header.height;
        image.format = ImageFormat.new(header.colorspace, header.channels);

        image.pixels = try allocator.alloc(Rgba, header.width * header.height);
        errdefer allocator.free(image.pixels);

        var reader = std.Io.Reader.fixed(data[14..]);

        try decodeData(header, image.pixels, &reader);
        return image;
    }

    pub fn fromReader(allocator: Allocator, reader: *std.Io.Reader) DecodeErrorSet!Self {
        var image: Image = undefined;

        const header = try decodeHeader(reader.takeArray(14));
        image.width = header.width;
        image.height = header.height;
        image.format = ImageFormat.new(header.colorspace, header.channels);

        image.pixels = try allocator.alloc(Rgba, header.width * header.height);
        errdefer allocator.free(image.pixels);

        try decodeData(header, image.pixels, reader);
        return image;
    }

    pub fn fromFilePath(allocator: Allocator, path: []const u8) !Self {
        const file_data = try readFileAlloc(allocator, path);
        defer allocator.free(file_data);

        return try fromBuf(allocator, file_data);
    }

    pub fn toBuf(
        self: *const Self,
        buf: []u8,
    ) (EncodeError || std.Io.Writer.Error)![]u8 {
        if (!self.isValidSize()) return EncodeError.InvalidSize;

        const header = FileHeader{
            .width = self.width,
            .height = self.height,
            .channels = self.format.toChannels(),
            .colorspace = self.format.toColorspace(),
        };

        if (!header.isValid()) return EncodeError.CorruptedHeader;

        var writer = std.Io.Writer.fixed(buf);
        try self.toWriter(&writer);

        return writer.buffered();
    }

    pub fn toWriter(
        self: *const Self,
        writer: *std.Io.Writer,
    ) !void {
        if (!self.isValidSize()) return EncodeError.InvalidSize;

        const header = FileHeader{
            .width = self.width,
            .height = self.height,
            .channels = self.format.toChannels(),
            .colorspace = self.format.toColorspace(),
        };

        try encodeHeader(writer, &header);
        try encodeData(writer, self.pixels);
        _ = try writer.writeAll(&QoiStreamEnd);
    }

    pub fn toFilePath(
        self: *const Self,
        file_path: []const u8
    ) !void {
        if (!self.isValidSize()) return EncodeError.InvalidSize;
        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();

        var buf: [4096]u8 = undefined;
        var file_fs_writer = file.writer(&buf);
        const file_writer = &file_fs_writer.interface;

        try self.toWriter(file_writer);
        try file_writer.flush();
    }

    pub fn asBytes(self: *const Self) []const u8 {
        return std.mem.sliceAsBytes(self.pixels);
    }

    pub fn isValidSize(self: *const Self) bool {
        return (self.width * self.height == self.pixels.len);
    }

    pub fn deinit(self: *const Self, allocator: Allocator) void {
        allocator.free(self.pixels);
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
    return (
        ((diff.g +% 32) < 64) and
        ((diff.r -% diff.g +% 8) < 16) and
        ((diff.b -% diff.g +% 8) < 16)
    );
}

inline fn checkDiff(diff: Rgba) bool {
    return (
        ((diff.r +% 2) < 4) and
        ((diff.g +% 2) < 4) and
        ((diff.b +% 2) < 4)
    );
}

inline fn colorDiff(a: Rgba, b: Rgba) Rgba {
    return .{
        .r = b.r -% a.r,
        .g = b.g -% a.g,
        .b = b.b -% a.b,
        .a = 0,
    };
}

pub fn encodeHeader(
    writer: *std.Io.Writer,
    header: *const FileHeader
) std.Io.Writer.Error!void {
    try writer.writeAll(header.magic);
    try writer.writeInt(u32, header.width, .big);
    try writer.writeInt(u32, header.height, .big);
    try writer.writeByte(header.channels);
    try writer.writeByte(@intFromEnum(header.colorspace));
}

pub fn encodeData(
    writer: *std.Io.Writer,
    data: []Rgba
) (EncodeError || std.Io.Writer.Error)!void {
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
                    QoiOp.Diff +
                        (0b01_0000 * (color_diff.r +% 2)) +
                        (0b0100 * (color_diff.g +% 2)) +
                        (0b01 * (color_diff.b +% 2))
                );

                break :blk;
            }

            // QOI_OP_LUMA
            if (checkLuma(color_diff)) {
                @branchHint(.likely);
                try writer.writeAll(&[_]u8{
                    QoiOp.Luma + (color_diff.g +% 32),
                    0b01_0000 *
                        (color_diff.r -% color_diff.g +% 8) +
                        (color_diff.b -% color_diff.g +% 8),
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

pub fn decodeHeader(data: []const u8) DecodeError!FileHeader {
    if (data.len <= 14) return DecodeError.FileTooShort;

    if (!std.mem.eql(u8, data[0..4], "qoif")) return DecodeError.NotQoi;
    if (std.mem.readInt(u32, data[4..8], .big) == 0) {
        return DecodeError.InvalidWidth;
    }
    if (std.mem.readInt(u32, data[8..12], .big) == 0) {
        return DecodeError.InvalidHeight;
    }
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

pub fn decodeData(
    header: FileHeader,
    buf: []Rgba,
    reader: *std.Io.Reader,
) (DecodeError || std.Io.Reader.Error)!void {
    const channel_mask: u8 = if (header.channels == 3) 0xff else 0x00;

    var lookup_array: [64]Rgba = undefined;
    @memset(&lookup_array, Rgba{ .r = 0, .g = 0, .b = 0, .a = 0 });

    var current_pixel = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };
    var current_run: u8 = 0;

    const mask2: u8 = 0b1100_0000;

    for (buf) |*b| {
        if (current_run > 0) {
            current_run -= 1;
        } else {
            @branchHint(.cold);
            const b1: u8 = try reader.takeByte();

            // QOI_OP_RGB
            if (b1 == QoiOp.Rgb) {
                const bytes = try reader.take(3);
                current_pixel.r = bytes[0];
                current_pixel.g = bytes[1];
                current_pixel.b = bytes[2];
            }
            // QOI_OP_RGBA
            else if (b1 == QoiOp.Rgba) {
                const bytes = try reader.take(4);
                current_pixel.r = bytes[0];
                current_pixel.g = bytes[1];
                current_pixel.b = bytes[2];
                current_pixel.a = bytes[3] & channel_mask;
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
                const b2: u8 = try reader.takeByte();
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

        b.* = current_pixel;
    }

    // Ignore last 8 bytes marking the end
    if (reader.seek + 8 < reader.end) {
        return DecodeError.LeftoverData;
    }
}

fn readFileAlloc(allocator: Allocator, path: []const u8) ![]const u8 {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var buf: [4096]u8 = undefined;
    var file_fs_reader = file.reader(&buf);
    const file_reader = &file_fs_reader.interface;

    return try file_reader.allocRemaining(allocator, .unlimited);
}

test {
    _ = @import("tests.zig");
}
