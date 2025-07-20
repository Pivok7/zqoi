const std = @import("std");
const zqoi = @import("zqoi");

pub fn main() !void {
    var dba = std.heap.DebugAllocator(.{}){};
    defer _ = dba.deinit();
    const allocator = dba.allocator();

    // Load and save file
    var img = try zqoi.Image.fromFilePath(allocator, "image.qoi");
    defer img.deinit();

    try img.toFilePath("copy.qoi");

    // Manually create image
    var image = zqoi.Image{
        .allocator = allocator,
        .width = 1024,
        .height = 1024,
        .pixels = undefined,
        .format = .r8g8b8a8_srgb,
    };

    image.pixels = try allocator.alloc(zqoi.Rgba, image.width * image.height);
    defer allocator.free(image.pixels);

    for (image.pixels, 0..) |*pixel, i| {
        pixel.* = zqoi.Rgba{
            .r = @as(u8, @intCast(i % 256)),
            .g = @as(u8, @intCast(i % 128)),
            .b = @as(u8, @intCast(i % 64)),
            .a = 255,
        };
    }

    try image.toFilePath("generated.qoi");
}
