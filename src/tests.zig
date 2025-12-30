const std = @import("std");
const zqoi = @import("zqoi.zig");

const Rgba = zqoi.Rgba;
const Image = zqoi.Image;
const FileHeader = zqoi.FileHeader;

const test_output = "test_output/";

fn touch_output() !void {
    var touch = try std.fs.cwd().makeOpenPath(test_output, .{});
    touch.close();
}

test "simple_encode" {
    const allocator = std.testing.allocator;

    var image = Image{
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

    try touch_output();
    try image.toFilePath(test_output ++ "simple.qoi");
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

    try touch_output();
    try image.toFilePath(test_output ++ "random.qoi");
}

test "image" {
    const allocator = std.testing.allocator;

    const image = try zqoi.Image.fromFilePath(allocator, "image.qoi");
    defer image.deinit(allocator);

    try image.toFilePath(test_output ++ "image_copy.qoi");

    const image_copy = try zqoi.Image.fromFilePath(allocator, test_output ++ "image_copy.qoi");
    defer image_copy.deinit(allocator);

    if (!std.mem.eql(u8, image.asBytes(), image_copy.asBytes())) {
        std.log.err("{s} != {s}", .{"image.qoi", "image_copy.qoi"});
        return error.CorruptedOutput;
    }
}

test "read_write" {
    const allocator = std.testing.allocator;

    const file_paths = [_][2][]const u8{
        [2][]const u8{
            test_output ++ "simple.qoi",
            test_output ++ "simple_copy.qoi",
        },
        [2][]const u8{
            test_output ++ "random.qoi",
            test_output ++ "random_copy.qoi",
        },
    };

    try touch_output();

    for (file_paths) |path_pair| {
        var img = try Image.fromFilePath(allocator, path_pair[0]);
        try img.toFilePath(path_pair[1]);
        img.deinit(allocator);

        var file_1 = try zqoi.Image.fromFilePath(allocator, path_pair[0]);
        var file_2 = try zqoi.Image.fromFilePath(allocator, path_pair[1]);

        if (!std.mem.eql(u8, file_1.asBytes(), file_2.asBytes())) {
            std.log.err("{s} != {s}", .{path_pair[0], path_pair[1]});
            return error.CorruptedOutput;
        }

        file_1.deinit(allocator);
        file_2.deinit(allocator);
    }
}

test "interfaces" {
    const allocator = std.testing.allocator;

    const file_paths = [_][2][]const u8{
        [2][]const u8{
            test_output ++ "simple.qoi",
            test_output ++ "simple_copy.qoi",
        },
        [2][]const u8{
            test_output ++ "random.qoi",
            test_output ++ "random_copy.qoi",
        },
    };

    try touch_output();

    for (file_paths) |path_pair| {
        var img = try Image.fromFilePath(allocator, path_pair[0]);
        defer img.deinit(allocator);

        // Enough not to overflow
        const img_size = img.width * img.height * 5;

        const buf = try allocator.alloc(u8, img_size);
        defer allocator.free(buf);

        const img_out_buf = try img.toBuffer(buf);

        var writer_alloc = std.Io.Writer.Allocating.init(allocator);
        defer writer_alloc.deinit();

        const writer = &writer_alloc.writer;
        try img.toWriter(writer);

        if (!std.mem.eql(u8, img_out_buf, writer.buffered())) {
            std.log.err("{s} != {s}", .{path_pair[0], path_pair[1]});
            return error.CorruptedOutput;
        }
    }
}

// Fuzzer taken from https://github.com/ikskuh/zig-qoi
test "input_fuzzer" {
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
            var header_writer = std.Io.Writer.fixed(&header);

            try zqoi.encodeHeader(
                &header_writer,
                &FileHeader{
                    .width = rng.int(u16),
                    .height = rng.int(u16),
                    .channels = rng.int(u8) % 2 + 3,
                    .colorspace = @enumFromInt(rng.int(u8) % 2),
                }
            );
            @memcpy(input_buffer[0..header.len], &header);
        }

        var image_or_err = Image.fromBuffer(allocator, &input_buffer);
        if (image_or_err) |*image| {
            defer image.deinit(allocator);
        } else |err| {
            // error is also okay, just no crashes plz
            err catch {};
        }
    }
}
