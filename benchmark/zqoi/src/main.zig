const std = @import("std");
const builtin = @import("builtin");
const zqoi = @import("zqoi");
const zstbi = @import("zstbi");
const cmd = @import("cmd.zig");

const Allocator = std.mem.Allocator;

pub const debug_mode = switch (builtin.mode) {
    .Debug => true,
    else => false,
};

const EncDecTime = struct {
    encode: i128,
    decode: i128,
};

pub const BenchmarkOptions = struct {
    runs: usize = 10,
    print_individual: bool = false,
    warmup: usize = 3,
};

var stdout: *std.Io.Writer = undefined;

fn printTime(nano: i128) !void {
    const fnano = @as(f64, @floatFromInt(nano));

    try stdout.print("{d:.2}ms", .{fnano / std.time.ns_per_ms});
}

fn printEncDec(enc: i128, dec: i128) !void {
    try stdout.print("encode: ", .{});
    try printTime(enc);
    try stdout.print("\n", .{});

    try stdout.print("decode: ", .{});
    try printTime(dec);
    try stdout.print("\n", .{});
}

fn testDecode(
    allocator: Allocator,
    pixels: []const u8,
    options: BenchmarkOptions,
) !i128 {
    var duration: i128 = 0;

    for (0..options.runs + options.warmup) |i| {
        //START
        const start_time = std.time.nanoTimestamp();

        const image = try zqoi.Image.fromBuffer(allocator, pixels);

        const end_time = std.time.nanoTimestamp();
        //END

        image.deinit(allocator);

        if (i < options.warmup) continue;

        duration += end_time - start_time;
    }
    duration = @divTrunc(duration, options.runs);

    return duration;
}

fn testEncode(
    allocator: Allocator,
    image: zqoi.Image,
    options: BenchmarkOptions,
) !struct{time: i128, pixels: []const u8} {
    const buf = try allocator.alloc(u8, image.width * image.height * 5);
    var writer = std.Io.Writer.fixed(buf);

    var duration: i128 = 0;

    for (0..options.runs + options.warmup) |i| {
        writer.end = 0;

        //START
        const start_time = std.time.nanoTimestamp();

        try image.toWriter(&writer);

        const end_time = std.time.nanoTimestamp();
        //END

        if (i < options.warmup) continue;

        duration += end_time - start_time;
    }
    duration = @divTrunc(duration, options.runs);

    const pixels = try allocator.realloc(buf, writer.buffered().len);
    return .{ .time = duration, .pixels = pixels };
}

fn benchFile(
    allocator: Allocator,
    path: [:0]const u8,
    options: BenchmarkOptions,
) !EncDecTime {
    if (!std.mem.endsWith(u8, path, ".png")) {
        return .{ .encode = 0, .decode = 0 };
    }

    var raw_image = try zstbi.Image.loadFromFile(path, 4);
    defer raw_image.deinit();

    // There is one example (pngimg/viber_PNG2.png) that for some reason
    // has misleading data len
    // width * height * 4 != data.len
    const proper_len = raw_image.width * raw_image.height * 4;

    const zimage = zqoi.Image{
        .pixels = @as([]zqoi.Rgba, @ptrCast(raw_image.data[0..proper_len])),
        .width = raw_image.width,
        .height = raw_image.height,
        .format = .r8g8b8a8_linear
    };

    const res = try testEncode(allocator, zimage, options);
    defer allocator.free(res.pixels);

    const decode_time = try testDecode(allocator, res.pixels, options);

    return .{ .encode = res.time, .decode = decode_time };
}

fn benchmarkDir(
    allocator: Allocator,
    path: [:0]const u8,
    options: BenchmarkOptions,
) !struct{ time: EncDecTime, timages: usize  } {
    var total_time: EncDecTime = .{ .encode = 0, .decode = 0 };
    var total_images: usize = 0;
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch {
        const time = try benchFile(allocator, path, options);

        if (options.print_individual) {
            try stdout.print("{s}\n", .{path});
            try printEncDec(time.encode, time.decode);
            try stdout.flush();
        }
        return .{
            .time = time,
            .timages = 0,
        };
    };
    defer dir.close();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var dir_iterator = dir.iterate();

    while (try dir_iterator.next()) |d| : (total_images += 1) {
        const name = d.name;

        const new_path = try std.fmt.bufPrintZ(
            &buf,
            "{s}/{s}",
            .{ path, name }
        );

        const res = try benchmarkDir(allocator, new_path, options);
        total_time.encode += res.time.encode;
        total_time.decode += res.time.decode;
        total_images += res.timages;
    }

    try stdout.print("{s}\n", .{path});
    try printEncDec(
        @divTrunc(total_time.encode, total_images),
        @divTrunc(total_time.decode, total_images),
    );
    try stdout.flush();

    return .{ .time = total_time, .timages = total_images };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = if (debug_mode) gpa.allocator()
        else std.heap.raw_c_allocator;

    zstbi.init(allocator);
    errdefer zstbi.deinit();
    defer zstbi.deinit();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    stdout = &stdout_writer.interface;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len <= 1) {
        cmd.printHelp();
        return;
    }

    // Check if dir exists
    const bench_dir_path: [:0]const u8 = args[1];

    var dir = std.fs.cwd().openDir(bench_dir_path, .{}) catch |err| {
        std.log.err("Couldn't open directory: \"{s}\"", .{bench_dir_path});
        return err;
    };
    dir.close();

    const options = try cmd.porcessArgs(args[2..]);

    _ = try benchmarkDir(allocator, bench_dir_path, options);
}
