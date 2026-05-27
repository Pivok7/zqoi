# Zqoi

QOI decoder/encoder written in pure Zig. Optimized for decoding speed.

## Using

You will need:

* Zig compiler 0.16.0

Fetch:
```bash
zig fetch --save git+https://github.com/Pivok7/zqoi
```

In build.zig:

```zig
const zqoi = b.dependency("zqoi", .{
    .target = target,
    .optimize = optimize,
}).module("root");
exe.root_module.addImport("zqoi", zqoi);
```
Example:

```zig
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
```

## Speed

You can run benchmarks yourself by following the instructions in the 'benchmark' directory.

Benchmarks performed on the images from https://qoiformat.org/benchmark/

CPU: AMD Ryzen 7 5700X

The results:

|Encoding           |zqoi    |reference  |
|-------------------|--------|-----------|
|textures_plants    |3.60ms  |4.2ms      |
|screenshot_game    |2.54ms  |2.6ms      |
|textures_pk02      |1.82ms  |1.8ms      |
|photo_kodak        |2.59ms  |2.6ms      |
|textures_pk01      |0.66ms  |0.7ms      |
|icon_512           |0.49ms  |0.7ms      |
|photo_tecnick      |10.02ms |10.0ms     |
|icon_64            |0.01ms  |0.0ms      |
|textures_photo     |6.45ms  |6.1ms      |
|textures_pk        |0.33ms  |0.3ms      |
|screenshot_web     |15.27ms |23.0ms     |
|photo_wikipedia    |7.71ms  |7.6ms      |
|pngimg             |6.18ms  |7.4ms      |
|total              |1.99ms  |2.1ms      |

|Decoding           |zqoi    |reference  |
|-------------------|--------|-----------|
|textures_plants    |2.07ms  |2.7ms      |
|screenshot_game    |1.69ms  |2.1ms      |
|textures_pk02      |1.23ms  |1.4ms      |
|photo_kodak        |1.58ms  |2.0ms      |
|textures_pk01      |0.41ms  |0.5ms      |
|icon_512           |0.31ms  |0.4ms      |
|photo_tecnick      |6.14ms  |7.6ms      |
|icon_64            |0.01ms  |0.0ms      |
|textures_photo     |3.97ms  |5.1ms      |
|textures_pk        |0.18ms  |0.2ms      |
|screenshot_web     |8.88ms  |20.4ms     |
|photo_wikipedia    |4.62ms  |5.8ms      |
|pngimg             |3.63ms  |5.8ms      |
|total              |1.24ms  |1.7ms      |
