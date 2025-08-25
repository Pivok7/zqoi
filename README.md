# Zqoi

QOI decoder/encoder written in pure Zig with speed comparable to the reference implementation

## Using

You will need:

* Zig compiler 0.15.1

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
        defer img.deinit();

        try img.toFilePath("copy.qoi");
    }

    // Manually create image
    {
        var img = zqoi.Image{
            .allocator = allocator,
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

Benchmarks performed on the images from https://qoiformat.org/benchmark/

Allocator used: raw_c_allocator

CPU: AMD Ryzen 7 5700X

Here are some of the results:

|Benchmark      |zqoi   |reference  |
|-              |-      |-          |
|icon_512       |-      |-          |
|decode:        |0.37   |0.4        |
|encode:        |0.32   |0.4        |
|photo_kodak    |-      |-          |
|decode:		|1.88   |1.9        |
|encode:		|2.29   |2.5        |
|photo_tecnick  |-      |-          |
|decode:		|6.94   |7.0        |
|encode:		|8.48   |9.6        |
|pngimg         |-      |-          |
|decode:		|4.31   |4.2        |
|encode:		|4.68   |5.5        |
|screenshot_web |-      |-          |
|decode:		|11.72  |11.3       |
|encode:		|10.38  |13.6       |
|textures_photo |-      |-          |
|decode:		|4.63   |4.7        |
|encode:		|5.22   |5.9        |
|textures_plants|-      |-          |
|decode:		|2.34   |2.4        |
|encode:		|2.74   |3.3        |
