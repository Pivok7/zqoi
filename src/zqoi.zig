const std = @import("std");
const Allocator = std.mem.Allocator;

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

pub const ImageFormat = enum {
    r8g8b8_linear,
    r8g8b8a8_linear,
    r8g8b8_srgb,
    r8g8b8a8_srgb,

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
    allocator: Allocator,
    width: u32,
    height: u32,
    pixels: []Rgba,
    format: ImageFormat,

    pub fn fromMemory(
        allocator: Allocator,
        data: []u8,
    ) @This() {
        return .{
            .allocator = allocator,
            //TODO: Encoding
            .pixels = @as([]Rgba, @alignCast(data)),
        };
    }

    pub fn writeToFilePath(self: *const @This(), file_path: []const u8) !void {
        const header = FileHeader{
            .width = self.width,
            .height = self.height,
            .channels = self.format.toChannels(),
            .colorspace = self.format.toColorspace(),
        };

        var encoded_data = std.ArrayList(u8).init(self.allocator);
        defer encoded_data.deinit();

        try encodeData(encoded_data.writer(), self.pixels);

        const stream_end = [_]u8{
            0, 0, 0, 0, 0, 0, 0, 1
        };

        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();

        try encodeHeader(file.writer(), &header);
        _ = try file.writeAll(encoded_data.items);
        _ = try file.writeAll(&stream_end);
    }
};

pub const FileHeader = struct {
    magic: []const u8 = "qoif",
    width: u32,
    height: u32,
    channels: u8 = 4,
    colorspace: Colorspace = .srgb,
};

fn encodeHeader(writer: anytype, header: *const FileHeader) !void {
    try writer.writeAll(header.magic);
    try writer.writeInt(u32, header.width, .big);
    try writer.writeInt(u32, header.height, .big);
    try writer.writeByte(header.channels);
    try writer.writeByte(@intFromEnum(header.colorspace));
}

fn pixelCmp(pixel_1: Rgba, pixel_2: Rgba) bool {
    if (pixel_1.r != pixel_2.r 
        or pixel_1.g != pixel_2.g 
        or pixel_1.b != pixel_2.b 
        or pixel_1.a != pixel_2.a) {
        return false;
    }
    return true;
}

fn checkLuma(diff: Rgba) bool {
    if ((diff.g +% 32) >= 64) { return false; }
    if ((diff.r -% diff.g +% 8) >= 16) { return false; }
    if ((diff.b -% diff.g +% 8) >= 16) { return false; }
    return true;
}

fn checkDiff(diff: Rgba) bool {
    if ((diff.r +% 2) >= 4) { return false; }
    if ((diff.g +% 2) >= 4) { return false; }
    if ((diff.b +% 2) >= 4) { return false; }
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

fn encodeData(writer: anytype, raw_data: []Rgba) !void {
    var lookup_array: [64]Rgba = undefined;
    @memset(&lookup_array, Rgba{.r = 0, .g = 0, .b = 0, .a = 0});

    var previous_pixel = Rgba{
        .r = 0, 
        .g = 0, 
        .b = 0, 
        .a = 255
    };

    var current_run: u8 = 0;
    var just_issued_lookup: bool = false;
    
    for (raw_data) |current_pixel| {

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
        
        // QOI_OP_INDEX
        const lookup_index: u8 = @intCast((
            @as(usize, current_pixel.r) * 3 +
            @as(usize, current_pixel.g) * 5 +
            @as(usize, current_pixel.b) * 7 +
            @as(usize, current_pixel.a) * 11) % 64);

        blk: {
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

            if (!just_issued_lookup and pixelCmp(lookup_array[lookup_index], current_pixel)) {
                just_issued_lookup = true;
                try writer.writeByte(@intCast(lookup_index));

                break :blk;
            }

            just_issued_lookup = false;

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
        lookup_array[lookup_index] = current_pixel;
    }

    // Write leftover run
    if (current_run > 0) {
        try writer.writeByte(0b11000000 + current_run - 1);
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

    //fill data_stream with rgba values
    for (image.pixels, 0..) |*pixel, i| {
        pixel.* = Rgba{
            .r = @as(u8, @intCast(i % 256)),
            .g = @as(u8, @intCast(i % 128)),
            .b = @as(u8, @intCast(i % 64)),
            .a = 255,
        };
    }

    try image.writeToFilePath("simple.qoi");
}

test "noise" {
    const allocator = std.testing.allocator;
    var rng = std.Random.DefaultPrng.init(0);
    const rand = rng.random();

    var image = Image{
        .allocator = allocator,
        .width = 1024,
        .height = 1024,
        .pixels = undefined,
        .format = .r8g8b8a8_srgb,
    };

    image.pixels = try allocator.alloc(Rgba, image.width * image.height);
    defer allocator.free(image.pixels);

    //fill data_stream with rgba values
    for (image.pixels) |*pixel| {
        pixel.* = Rgba{
            .r = rand.int(u8),
            .g = rand.int(u8),
            .b = rand.int(u8),
            .a = rand.int(u8),
        };
    }

    try image.writeToFilePath("random.qoi");
}
