const std = @import("std");
const main = @import("main.zig");

const BenchmarkOptions = main.BenchmarkOptions;

const CmdArgsState = enum {
    none,
    runs,
    warmup,
};

pub fn printHelp() void {
    std.debug.print(">>> Help <<<\n", .{});
    std.debug.print("\nUsage: zqoi-bench <directory> <options>\n", .{});
    std.debug.print("    --help             - display this menu\n", .{});
    std.debug.print("    --runs <number>    - number of runs per image (default 10)\n", .{});
    std.debug.print("    --warmup <number>  - number of warmup runs (default 3)\n", .{});
    std.debug.print("    --printindiv       - print times for individual images\n", .{});
    std.debug.print("\nExamples:\n", .{});
    std.debug.print("    zqoi-bench benchmark-dir\n", .{});
    std.debug.print("    zqoi-bench benchmark-dir/pngimg --runs 5 --warmup 0\n", .{});
}

pub fn porcessArgs(args: [][:0]u8) !BenchmarkOptions {
    var options: BenchmarkOptions = .{};
    var cmd_state: CmdArgsState = .none;

    for (args) |arg| {
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
            std.process.exit(0);
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

    return options;
}
