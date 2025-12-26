# Zqoi

QOI decoder/encoder written in pure Zig. Optimized for decoding speed.

## Using

You will need:

* Zig compiler 0.15.2

Fetch:
```bash
zig fetch --save git+https://github.com/Pivok7/zqoi
```

In build.zig:

```zig
const zqoi_dep = b.dependency("zqoi", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zqoi", zqoi_dep.module("zqoi"));
```
Example:

```zig
const std = @import("std");
const zqoi = @import("zqoi");

pub fn main() !void {
    var dba = std.heap.DebugAllocator(.{}){};
    defer _ = dba.deinit();
    const allocator = dba.allocator();

    // Load and save file
    {
        var img = try zqoi.Image.fromFilePath(allocator, "image.qoi");
        defer img.deinit(allocator);

        try img.toFilePath("copy.qoi");
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

        try img.toFilePath("generated.qoi");
    }
}
```

## Speed

You can run benchmarks yourself by following the instructions in the 'benchmark' directory.

Benchmarks performed on the images from https://qoiformat.org/benchmark/

CPU: AMD Ryzen 7 5700X

Allocator used for zqoi: raw_c_allocator

Here are the results:

|Benchmark      |zqoi   |reference  |
|-              |-      |-          |
|WIP            |WIP    |WIP        |
