const std = @import("std");
const zqoi = @import("zqoi.zig");

const Rgba = zqoi.Rgba;
const Image = zqoi.Image;
const FileHeader = zqoi.FileHeader;

test "t1_simple_encode" {
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

    var touch = try std.fs.cwd().makeOpenPath("tests_output", .{});
    touch.close();
    try image.toFilePath(allocator, "tests_output/simple.qoi");
}

test "t2_noise" {
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

    var touch = try std.fs.cwd().makeOpenPath("tests_output", .{});
    touch.close();
    try image.toFilePath(allocator, "tests_output/random.qoi");
}

test "t3_read_write" {
    const allocator = std.testing.allocator;

    var img = try Image.fromFilePath(allocator, "tests_output/random.qoi");
    try img.toFilePath(allocator, "tests_output/copy_random.qoi");
    img.deinit(allocator);

    const file_1_path = "tests_output/random.qoi";
    const file_2_path = "tests_output/copy_random.qoi";

    var file_1 = try zqoi.Image.fromFilePath(allocator, file_1_path);
    var file_2 = try zqoi.Image.fromFilePath(allocator, file_2_path);

    if (!std.mem.eql(u8, file_1.asBytes(), file_2.asBytes())) {
        std.log.err("random.qoi: input != output!", .{});
        return error.CorruptedOutput;
    }

    file_1.deinit(allocator);
    file_2.deinit(allocator);

    img = try Image.fromFilePath(allocator, "tests_output/simple.qoi");
    try img.toFilePath(allocator, "tests_output/copy_simple.qoi");
    img.deinit(allocator);

    file_1 = try zqoi.Image.fromFilePath(allocator, file_1_path);
    file_2 = try zqoi.Image.fromFilePath(allocator, file_2_path);

    if (!std.mem.eql(u8, file_1.asBytes(), file_2.asBytes())) {
        std.log.err("simple.qoi: input != output!", .{});
        return error.CorruptedOutput;
    }

    file_1.deinit(allocator);
    file_2.deinit(allocator);
}

// Fuzzer taken from https://github.com/ikskuh/zig-qoi
test "t4_input_fuzzer" {
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

        var image_or_err = Image.fromMemory(allocator, &input_buffer);
        if (image_or_err) |*image| {
            defer image.deinit(allocator);
        } else |err| {
            // error is also okay, just no crashes plz
            err catch {};
        }
    }
}
