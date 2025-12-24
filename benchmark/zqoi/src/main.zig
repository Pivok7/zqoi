const std = @import("std");
const builtin = @import("builtin");
const zqoi = @import("zqoi");
const zstbi = @import("zstbi");

const Allocator = std.mem.Allocator;

pub const debug_mode = switch (builtin.mode) {
    .Debug => true,
    else => false,
};

const EncDecTime = struct {
    encode: i128,
    decode: i128,
};

const BenchmarkOptions = struct {
    runs: usize = 10,
    print_individual: bool = false,
    warmup: usize = 3,
};

const CmdArgsState = enum {
    none,
    runs,
    warmup,
};

var stdout: *std.Io.Writer = undefined;

fn printTime(nano: i128) !void {
    const fnano = @as(f64, @floatFromInt(nano));

    try stdout.print("{d:.2}ms", .{fnano / std.time.ns_per_ms});
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

        const image = try zqoi.Image.fromMemory(allocator, pixels);

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
    const buf = try allocator.alloc(u8, image.width * image.height * 4);
    var writer = std.Io.Writer.fixed(buf);

    var duration: i128 = 0;

    for (0..options.runs + options.warmup) |i| {
        writer.end = 0;

        //START
        const start_time = std.time.nanoTimestamp();

        try image.toMemory(&writer);

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
    var buf: [std.fs.max_path_bytes]u8 = undefined;

    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch {
        return .{
            .time = try benchFile(allocator, path, options),
            .timages = 0,
        };
    };
    defer dir.close();

    var dir_iterator = dir.iterate();

    var total_time: EncDecTime = .{ .encode = 0, .decode = 0 };
    var total_images: usize = 0;

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

        if (options.print_individual) {
            try stdout.print("{s}\n", .{new_path});

            try stdout.print("encode: ", .{});
            try printTime(res.time.encode);
            try stdout.print("\n", .{});

            try stdout.print("decode: ", .{});
            try printTime(res.time.decode);
            try stdout.print("\n", .{});

            try stdout.flush();
        }
    }

    try stdout.print("{s}\n", .{path});

    try stdout.print("encode: ", .{});
    try printTime(@divTrunc(total_time.encode, total_images));
    try stdout.print("\n", .{});

    try stdout.print("decode: ", .{});
    try printTime(@divTrunc(total_time.decode, total_images));
    try stdout.print("\n", .{});

    try stdout.flush();

    return .{ .time = total_time, .timages = total_images };
}

fn printHelp() void {
    std.debug.print(">>> Help <<<\n", .{});
    std.debug.print("Usage: zqoi-bench <directory> <options>\n", .{});
    std.debug.print("    --help             - display this menu\n", .{});
    std.debug.print("    --runs <number>    - number of runs per image (default 10)\n", .{});
    std.debug.print("    --warmup <number>  - number of warmup runs (default 3)\n", .{});
    std.debug.print("    --printindiv       - print times for individual images\n", .{});
    std.debug.print("Examples:\n", .{});
    std.debug.print("    zqoi-bench benchmark-dir\n", .{});
    std.debug.print("    zqoi-bench benchmark-dir/pngimg --runs 5 --warmup 0\n", .{});
}



pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = if (debug_mode) gpa.allocator()
        else std.heap.smp_allocator;

    zstbi.init(allocator);
    errdefer zstbi.deinit();
    defer zstbi.deinit();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    stdout = &stdout_writer.interface;

    const args = try std.process.argsAlloc(allocator);
    errdefer std.process.argsFree(allocator, args);
    defer std.process.argsFree(allocator, args);

    if (args.len <= 1) {
        printHelp();
        return;
    }

    // Check if dir exists
    const bench_dir_path: [:0]const u8 = args[1];

    var dir = std.fs.cwd().openDir(bench_dir_path, .{}) catch |err| {
        std.log.err("Couldn't open directory: \"{s}\"", .{bench_dir_path});
        return err;
    };
    dir.close();

    // Args processing
    var options: BenchmarkOptions = .{};
    var cmd_state: CmdArgsState = .none;

    for (args[2..]) |arg| {
        const eql = std.mem.eql;

        if (cmd_state != .none) {
            switch (cmd_state) {
                .runs => {
                    const val = std.fmt.parseInt(
                        isize,
                        arg,
                        10,
                    ) catch |err| {
                        std.log.err("Invalid --runs value: \"{s}\"", .{arg});
                        return err;
                    };

                    if (val <= 0) {
                        std.log.err("Value for --runs must be greater than 0\nProvided: \"{s}\"", .{arg});
                        std.process.exit(1);
                    }

                    options.runs = @intCast(val);
                },
                .warmup => {
                    const val = std.fmt.parseInt(
                        isize,
                        arg,
                        10,
                    ) catch |err| {
                        std.log.err("Invalid --warmup value: \"{s}\"", .{arg});
                        return err;
                    };

                    if (val < 0) {
                        std.log.err("Value for --warmup must be positive\nProvided: \"{s}\"", .{arg});
                        std.process.exit(1);
                    }

                    options.warmup = @intCast(val);
                },
                else => unreachable,
            }
            cmd_state = .none;
            continue;
        }

        if (eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else if (eql(u8, arg, "--warmup")) {
            cmd_state = .warmup;
        } else if (eql(u8, arg, "--printindiv")) {
            options.print_individual = true;
        } else if (eql(u8, arg, "--runs")) {
            cmd_state = .runs;
        } else {
            std.log.err("Invalid argument \"{s}\"", .{arg});
            std.process.exit(1);
        }
    }

    if (cmd_state != .none) {
        switch (cmd_state) {
            .runs => {
                std.log.err("No value for --runs provided", .{});
            },
            .warmup => {
                std.log.err("No value for --warmup provided", .{});
            },
            .none => {},
        }
        std.process.exit(1);
    }

    _ = try benchmarkDir(allocator, bench_dir_path, options);
}
