const std = @import("std");
const zqoi = @import("zqoi");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Load and save file
    {
        var img = try zqoi.Image.fromFilePath(allocator, io, "../image.qoi");
        defer img.deinit(allocator);

        try img.toFilePath(io, "copy.qoi");
    }

    // Manually create image
    {
        var img = zqoi.Image{
            .width = 1024,
            .height = 1024,
            .pixels = undefined,
            .format = .r8g8b8a8_srgb,
        };

        img.pixels = try allocator.alloc(zqoi.Rgba, img.width * img.height);
        defer allocator.free(img.pixels);

        for (img.pixels, 0..) |*pixel, i| {
            pixel.* = zqoi.Rgba{
                .r = @as(u8, @intCast(i % 256)),
                .g = @as(u8, @intCast(i % 128)),
                .b = @as(u8, @intCast(i % 64)),
                .a = 255,
            };
        }

        try img.toFilePath(io, "generated.qoi");
    }
}
