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

    pub fn toInt(self: @This()) u8 {
        return @intFromEnum(self);
    }

    pub fn fromInt(val: u8) @This() {
        return @enumFromInt(val);
    }
};

pub const ImageFormat = enum {
    r8g8b8_linear,
    r8g8b8a8_linear,
    r8g8b8_srgb,
    r8g8b8a8_srgb,
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
        width: u32,
        height: u32,
        format: ImageFormat,
    ) @This() {
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            //TODO: Encoding
            .pixels = @as([]Rgba, @alignCast(data)),
            .format = format,
        };
    }

    pub fn writeToFilePath(self: *@This()) !void {
        _ = self;
    }
};

pub const FileHeader = struct {
    magic: [4]u8 = .{ 'q', 'o', 'i', 'f' },
    width: u32,
    height: u32,
    channels: u8 = 4,
    colorspace: Colorspace = .srgb,
};

fn encodeHeader(file_stream_header: []u8, header: *const FileHeader) !void {
    @memcpy(file_stream_header[0..4], "qoif");
    std.mem.writeInt(u32, file_stream_header[4..8], header.width, .big);
    std.mem.writeInt(u32, file_stream_header[8..12], header.height, .big);
    file_stream_header[12] = header.channels;
    file_stream_header[13] = Colorspace.toInt(header.colorspace);
    return;
}

fn comparePixels(pixel_1: Rgba, pixel_2: Rgba) bool {

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

fn getcolor_diff(pixel_1: Rgba, pixel_2: Rgba) Rgba {
    const diff = Rgba{
        .r = pixel_2.r -% pixel_1.r,
        .g = pixel_2.g -% pixel_1.g,
        .b = pixel_2.b -% pixel_1.b,
        .a = 0,
    };

    return diff;
}

fn encodeData(file_stream_data: *std.ArrayList(u8), raw_data: []Rgba) !void {
    var lookup_array: [64]Rgba = undefined;
    @memset(&lookup_array, Rgba{.r = 0, .g = 0, .b = 0, .a = 0});

    var just_issued_lookup_index: bool = false;

    var previous_pixel = Rgba{
        .r = 0, 
        .g = 0, 
        .b = 0, 
        .a = 255
    };

    var current_run: u6 = 0;
    
    for (raw_data) |current_pixel| {
        
        // QOI_OP_RUN
        if (comparePixels(current_pixel, previous_pixel)) {
            current_run += 1;
            if (current_run == 1) {
                try file_stream_data.append(0b11000000);
            }
            else {
                file_stream_data.items[file_stream_data.items.len - 1] += 1;
            }

            if (current_run >= 62) {
                current_run = 0;
            }
        }
        else {
            current_run = 0;
            
            // QOI_OP_DIFF
            const color_diff = getcolor_diff(previous_pixel, current_pixel);
            if (checkDiff(color_diff)) {
                try file_stream_data.append(0b01000000 + (0b010000 * (color_diff.r +% 2)) + (0b0100 * (color_diff.g +% 2)) + (0b01 * (color_diff.b +% 2)));
                previous_pixel = current_pixel;
                continue;
            }
            
            // QOI_OP_INDEX
            const lookup_index: u8 = @intCast((@as(usize, current_pixel.r) * 3 + @as(usize, current_pixel.g) * 5 + @as(usize, current_pixel.b) * 7 + @as(usize, current_pixel.a) * 11) % 64);
            
            if (comparePixels(lookup_array[lookup_index], current_pixel) and false) {
                just_issued_lookup_index = true;
                if (file_stream_data.items[file_stream_data.items.len - 1] == lookup_index and just_issued_lookup_index) {
                    break;
                }
                else {
                    try file_stream_data.append(@intCast(lookup_index));
                    previous_pixel = current_pixel;
                    continue;
                }
            }

            just_issued_lookup_index = false;
            
            lookup_array[lookup_index] = current_pixel;

            // QOI_OP_LUMA
            if (checkLuma(color_diff)) {
                try file_stream_data.append(0b10000000 + (color_diff.g +% 32));
                try file_stream_data.append((0b010000 * (color_diff.r -% color_diff.g +% 8)) + (color_diff.b -% color_diff.g +% 8));
                previous_pixel = current_pixel;
                continue;
            }

            // QOI_OP_RGB
            if (current_pixel.a == previous_pixel.a) {
                try file_stream_data.append(254);
                try file_stream_data.append(current_pixel.r);
                try file_stream_data.append(current_pixel.g);
                try file_stream_data.append(current_pixel.b);
            }
            // QOI_OP_RGBA
            else {
                try file_stream_data.append(255);
                try file_stream_data.append(current_pixel.r);
                try file_stream_data.append(current_pixel.g);
                try file_stream_data.append(current_pixel.b);
                try file_stream_data.append(current_pixel.a);
            }
        }

        previous_pixel = current_pixel;
    }

    return;
}

pub fn exportImage(file_name: []const u8, header: *const FileHeader, raw_data: []Rgba) !void {
    var dba = std.heap.DebugAllocator(.{}){};
    defer _ = dba.deinit();
    const allocator = dba.allocator();

    var file_stream_header: [14]u8 = undefined;

    var file_stream_data = std.ArrayList(u8).init(allocator);
    defer file_stream_data.deinit();

    const file_stream_end = [_]u8{
        0, 0, 0, 0, 0, 0, 0, 1
    };

    try encodeHeader(&file_stream_header, header);
    try encodeData(&file_stream_data, raw_data);

    const file = try std.fs.cwd().createFile(
        file_name,
        .{ .read = true },
    );
    defer file.close();

    _ = try file.writeAll(&file_stream_header);
    _ = try file.writeAll(file_stream_data.items);
    _ = try file.writeAll(&file_stream_end);
}

test "encode" {
    var dba = std.heap.DebugAllocator(.{}){};
    defer _ = dba.deinit();
    const allocator = dba.allocator();

    const header = FileHeader{
        .width = 1024,
        .height = 1024
    };

    const data_stream = try allocator.alloc(Rgba, header.width * header.height);
    defer allocator.free(data_stream);

    //fill data_stream with rgba values
    for (0..data_stream.len) |i| {
        data_stream[i] = Rgba{
            .r = @as(u8, @intCast(i % 256)), .g = @as(u8, @intCast(i % 126)), .b = @as(u8, @intCast(i % 7)),
            .a = 255
        };
    }

    try exportImage("image.qoi", &header, data_stream);
}
