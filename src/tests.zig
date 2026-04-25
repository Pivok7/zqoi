const std = @import("std");
const zqoi = @import("zqoi.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const cwd = Io.Dir.cwd;

const Rgba = zqoi.Rgba;
const Image = zqoi.Image;
const FileHeader = zqoi.FileHeader;

const test_output = "test_output/";

fn compare_images(
    allocator: Allocator,
    io: Io,
    file_path_1: []const u8,
    file_path_2: []const u8,
) !void {
    const image_1_raw = blk: {
        var file = try cwd().openFile(io, file_path_1, .{});
        var buf: [4096]u8 = undefined;
        var fs_reader = file.reader(io, &buf);
        const reader = &fs_reader.interface;
        break :blk try reader.allocRemaining(allocator, .unlimited);
    };
    defer allocator.free(image_1_raw);

    const image_2_raw = blk: {
        var file = try cwd().openFile(io, file_path_2, .{});
        var buf: [4096]u8 = undefined;
        var fs_reader = file.reader(io, &buf);
        const reader = &fs_reader.interface;
        break :blk try reader.allocRemaining(allocator, .unlimited);
    };
    defer allocator.free(image_2_raw);

    const image_1 = try zqoi.Image.fromBuffer(allocator, image_1_raw);
    defer image_1.deinit(allocator);

    const image_2 = try zqoi.Image.fromBuffer(allocator, image_2_raw);
    defer image_2.deinit(allocator);

    try std.testing.expectEqualSlices(u8, image_1.asBytes(), image_2.asBytes());
    try std.testing.expectEqualSlices(u8, image_1_raw, image_2_raw);
}

test "simple_encode" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

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

    try cwd().createDirPath(io, test_output);
    try image.toFilePath(io, test_output ++ "simple.qoi");
}

test "noise" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var prng = std.Random.DefaultPrng.init(0x1337);
    const rand = prng.random();

    var image = Image{
        .width = 1024,
        .height = 1024,
        .pixels = undefined,
        .format = .r8g8b8a8_srgb,
    };

    image.pixels = try allocator.alloc(Rgba, image.width * image.height);
    defer allocator.free(image.pixels);

    var changer: Rgba = .{ .r = 0, .g = 0, .b = 0, .a = 255 };

    for (image.pixels) |*pixel| {
        switch (rand.intRangeAtMost(u8, 0, 2)) {
            0 => changer.r +%= rand.uintAtMost(u8, 8) -% 4,
            1 => changer.g +%= rand.uintAtMost(u8, 8) -% 4,
            2 => changer.b +%= rand.uintAtMost(u8, 8) -% 4,
            else => unreachable,
        }

        pixel.* = changer;
    }

    try cwd().createDirPath(io, test_output);
    try image.toFilePath(io, test_output ++ "random.qoi");
}

test "image" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const image = zqoi.Image.fromFilePath(allocator, io, "image.qoi") catch {
        std.log.err("File image.qoi not found!", .{});
        std.debug.print("Please run tests from root dir\n", .{});
        return error.FileNotFound;
    };
    defer image.deinit(allocator);

    try image.toFilePath(io, test_output ++ "image_copy.qoi");

    try compare_images(allocator, io, "image.qoi", test_output ++ "image_copy.qoi");
}

test "read_write" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

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

    try cwd().createDirPath(io, test_output);

    for (file_paths) |path_pair| {
        var img = try Image.fromFilePath(allocator, io, path_pair[0]);
        try img.toFilePath(io, path_pair[1]);
        img.deinit(allocator);

        try compare_images(allocator, io, path_pair[0], path_pair[1]);
    }
}

test "interfaces" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

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

    try cwd().createDirPath(io, test_output);

    for (file_paths) |path_pair| {
        var img = try Image.fromFilePath(allocator, io, path_pair[0]);
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

        try std.testing.expectEqualSlices(u8, img_out_buf, writer.buffered());
    }
}

// Fuzzer taken from https://github.com/ikskuh/zig-qoi
test "input_fuzzer" {
    const allocator = std.testing.allocator;

    var rng_engine = std.Random.DefaultPrng.init(0x1337);
    const rng = rng_engine.random();

    var rounds: usize = 16;
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
