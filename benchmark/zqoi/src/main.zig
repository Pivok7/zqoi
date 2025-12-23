const std = @import("std");
const builtin = @import("builtin");
const zqoi = @import("zqoi");
const zstbi = @import("zstbi");

const Allocator = std.mem.Allocator;

pub const debug_mode = switch (builtin.mode) {
    .Debug => true,
    else => false,
};

const EncDecTime = struct{
    encode: i128,
    decode: i128,
};

const BenchmarkOptions = struct{
    iters: usize = 10,
    print_individual: bool = false,
    warmup: bool = true,
};

fn printTime(nano: i128) void {
    const fnano = @as(f64, @floatFromInt(nano));

    std.debug.print("{d:.2}ms", .{fnano / std.time.ns_per_ms});
}

fn testDecode(
    allocator: Allocator,
    pixels: []const u8,
    options: BenchmarkOptions,
) !i128 {
    var duration: i128 = 0;

    for (0..options.iters) |_| {
        //START
        const start_time = std.time.nanoTimestamp();

        const image = try zqoi.Image.fromMemory(allocator, pixels);

        const end_time = std.time.nanoTimestamp();
        //END

        duration += end_time - start_time;
        image.deinit(allocator);
    }
    duration = @divTrunc(duration, options.iters);

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

    for (0..options.iters) |_| {
        writer.end = 0;

        //START
        const start_time = std.time.nanoTimestamp();

        try image.toMemory(&writer);

        const end_time = std.time.nanoTimestamp();
        //END

        duration += end_time - start_time;
    }
    duration = @divTrunc(duration, options.iters);

    const pixels = try allocator.realloc(buf, writer.buffered().len);
    return .{ .time = duration, .pixels = pixels };
}

fn benchFile(
    allocator: Allocator,
    path: [:0]const u8,
    options: BenchmarkOptions,
) !EncDecTime {
    //std.debug.print("{s}\n", .{path});

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
    }

    std.debug.print("{s}\n", .{path});

    std.debug.print("encode: ", .{});
    printTime(@divTrunc(total_time.encode, total_images));
    std.debug.print("\n", .{});

    std.debug.print("decode: ", .{});
    printTime(@divTrunc(total_time.decode, total_images));
    std.debug.print("\n", .{});

    return .{ .time = total_time, .timages = total_images };
}

pub fn main() !void {
    std.debug.print("TODO: ADD CMD ARGS!!!!!!\n^^^^^^^^^^^^^^^^^^^^^^^^\n\n\n", .{});


    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = if (debug_mode) gpa.allocator()
        else std.heap.smp_allocator;

    zstbi.init(allocator);
    defer zstbi.deinit();

    const args = try std.process.argsAlloc(allocator);
    errdefer std.process.argsFree(allocator, args);
    defer std.process.argsFree(allocator, args);

    for (args) |arg| {
        std.debug.print("{s}\n", .{arg});
    }

    _ = try benchmarkDir(allocator, "../qoi-benchmark-suite", .{});
}
