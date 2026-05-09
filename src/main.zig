const std = @import("std");
const li2c = @cImport({
    @cInclude("linux/i2c-dev.h");
});
pub const std_options: std.Options = .{
    .logFn = log,
};

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const home = std.posix.getenv("HOME") orelse {
        std.debug.print("Failed to read $HOME.\n", .{});
        return;
    };

    const allocator = std.heap.page_allocator;
    const dir_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, ".local/state/ddc" }) catch |err| {
        std.debug.print("Failed to create dir path: {}\n", .{err});
        return;
    };
    defer allocator.free(dir_path);
    const file_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, ".local/state/ddc/ddc.log" }) catch |err| {
        std.debug.print("Failed to create file path: {}\n", .{err});
        return;
    };
    defer allocator.free(file_path);

    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            std.debug.print("Failed to create dir: {}\n", .{err});
            return;
        },
    };
    const created_file = std.fs.createFileAbsolute(file_path, .{ .truncate = false }) catch |err| {
        std.debug.print("Failed to create log file: {}\n", .{err});
        return;
    };
    created_file.close();

    const file = std.fs.openFileAbsolute(file_path, .{ .mode = .read_write }) catch |err| {
        std.debug.print("Failed to open log file: {}\n", .{err});
        return;
    };
    defer file.close();

    const stat = file.stat() catch |err| {
        std.debug.print("Failed to get stat of log file: {}\n", .{err});
        return;
    };
    file.seekTo(stat.size) catch |err| {
        std.debug.print("Failed to seek log file: {}\n", .{err});
        return;
    };

    const level_txt = comptime level.asText();
    const scope_txt = @tagName(scope);
    const timestamp_string = get_timestamp_string(allocator) catch |err| {
        std.debug.print("Failed to get timestamp string: {}\n", .{err});
        return;
    };
    defer allocator.free(timestamp_string);

    const message = std.fmt.allocPrint(allocator, "[{s}] [{s}]({s}) " ++ format ++ "\n", .{ timestamp_string, level_txt, scope_txt } ++ args) catch |err| {
        std.debug.print("Failed to create log message: {}\n", .{err});
        return;
    };
    defer allocator.free(message);

    file.writeAll(message) catch |err| {
        std.debug.print("Failed to write to log file: {}\n", .{err});
    };
}

fn get_timestamp_string(allocator: std.mem.Allocator) ![]u8 {
    const now: u64 = @intCast(std.time.timestamp());
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = now };
    const epoch_day = epoch_seconds.getEpochDay();

    const year_day = epoch_day.calculateYearDay();
    const year = year_day.year;
    const month_day = year_day.calculateMonthDay();
    const month = month_day.month.numeric();
    const day = month_day.day_index + 1;

    const day_seconds = epoch_seconds.getDaySeconds();
    const hour = day_seconds.getHoursIntoDay();
    const minute = day_seconds.getMinutesIntoHour();
    const second = day_seconds.getSecondsIntoMinute();

    const timestamp_string = try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{ year, month, day, hour, minute, second });

    return timestamp_string;
}

fn get(allocator: std.mem.Allocator, i2c: i32, dir_path: []const u8, file_path: []const u8) !u8 {
    if (std.fs.cwd().openFile(file_path, .{ .mode = .read_only })) |existing_file| {
        defer existing_file.close();

        const file_size = (try existing_file.stat()).size;
        const buffer = try allocator.alloc(u8, file_size + 1);
        var reader = existing_file.reader(buffer);
        const line = try reader.interface.takeDelimiterExclusive('\n');
        const current_brightness: u8 = try std.fmt.parseInt(u8, line, 10);

        return current_brightness;
    } else |open_err| {
        if (open_err == error.FileNotFound) {
            if (std.fs.cwd().createFile(file_path, .{ .read = false })) |new_file| {
                defer new_file.close();
            } else |create_err| {
                if (create_err == error.FileNotFound) {
                    try std.fs.cwd().makeDir(dir_path);
                    const new_file = try std.fs.cwd().createFile(file_path, .{ .read = false });
                    defer new_file.close();
                }
            }

            const get_luminance: [5]u8 = .{ 0x51, 0x82, 0x01, 0x10, (0x51 ^ 0x82 ^ 0x01 ^ 0x10) };
            _ = try std.posix.write(i2c, &get_luminance);

            std.Thread.sleep(10 * std.time.ns_per_ms);

            // To understand magic numbers, see Page 19 of https://glenwing.github.io/docs/VESA-DDCCI-1.1.pdf
            var luminance_reply: [15]u8 = undefined;
            _ = try std.posix.read(i2c, &luminance_reply);
            const current_brightness: u8 = luminance_reply[9];

            return current_brightness;
        }
    }

    return error.FailedToGetBrightness;
}

fn set(i2c: i32, new_brightness: u8) !void {
    const set_luminance: [7]u8 = .{ 0x51, 0x84, 0x03, 0x10, 0x00, new_brightness, (0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x00 ^ new_brightness) };
    _ = try std.posix.write(i2c, &set_luminance);

    std.Thread.sleep(5 * std.time.ns_per_ms);
}

fn run_protocol(allocator: std.mem.Allocator, monitor: []const u8, get_only: bool, increase: bool, brightness: u8, i: u8) !void {
    const addr: u8 = 0x37;

    var file_name: []const u8 = undefined;

    const i2c: i32 = try std.posix.open(monitor, .{ .ACCMODE = .RDWR }, 0);
    defer std.posix.close(i2c);
    try std.posix.flock(i2c, std.posix.LOCK.EX);
    const ioctl_result = std.os.linux.ioctl(i2c, li2c.I2C_SLAVE, addr);

    switch (std.os.linux.E.init(ioctl_result)) {
        .SUCCESS => {},
        .BADF => return error.InvalidFileDescriptor,
        .FAULT => return error.InaccessibleMemoryArea,
        .INVAL => return error.InvalidOpOrArgp,
        .NOTTY => return error.InvalidDevice,
        else => |errno| {
            std.log.err("I2C_SLAVE ioctl failed for {s}: errno {s}", .{
                monitor,
                @tagName(errno),
            });
            return error.IoctlFailed;
        },
    }

    if (i == 0) {
        file_name = "dev-i2c-3.txt";
    } else {
        file_name = "dev-i2c-4.txt";
    }

    const user_var = "USER";
    const user = std.posix.getenv(user_var);
    if (user) |name| {
        var dir_paths: [3][]const u8 = .{
            "/home",
            name,
            ".config/ddc",
        };
        const dir_path = try std.fs.path.join(allocator, &dir_paths);

        var file_paths: [4][]const u8 = .{ "/home", name, ".config/ddc", file_name };
        const file_path = try std.fs.path.join(allocator, &file_paths);

        const current_brightness: u8 = try get(allocator, i2c, dir_path, file_path);
        var test_brightness: struct { u8, u1 } = .{ undefined, undefined };
        var new_brightness: u8 = 0;

        if (!get_only) {
            if (increase) {
                test_brightness = @addWithOverflow(current_brightness, brightness);
                if (test_brightness[1] == 1) {
                    new_brightness = 100;
                } else {
                    new_brightness = test_brightness[0];
                    if (new_brightness > 100) {
                        new_brightness = 100;
                    }
                }
            } else {
                test_brightness = @subWithOverflow(current_brightness, brightness);
                if (test_brightness[1] == 1) {
                    new_brightness = 0;
                } else {
                    new_brightness = test_brightness[0];
                }
            }

            if (new_brightness != current_brightness) {
                try set(i2c, new_brightness);
            }
        } else {
            new_brightness = current_brightness;
            if (i == 0) {
                var stdout_buffer: [3]u8 = undefined;
                var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
                const stdout = &stdout_writer.interface;
                try stdout.print("{{\"brightness\": {d}}}\n", .{new_brightness});
                try stdout.flush();
            }
        }

        try std.posix.flock(i2c, std.posix.LOCK.UN);

        const brightness_file = try std.fs.cwd().createFile(file_path, .{ .read = false });
        defer brightness_file.close();
        var buffer: [3]u8 = undefined;
        const brightness_string = try std.fmt.bufPrint(&buffer, "{}", .{new_brightness});
        try brightness_file.writeAll(brightness_string);
    } else {
        return;
    }
}

fn run_protocol_logged(
    allocator: std.mem.Allocator,
    monitor: []const u8,
    get_only: bool,
    increase: bool,
    brightness: u8,
    i: u8,
) void {
    run_protocol(allocator, monitor, get_only, increase, brightness, i) catch |err| {
        std.log.err("run_protocol failed for monitor {s} with get_only `{}`, increase `{}` and brightness `{d}`: {}", .{
            monitor,
            get_only,
            increase,
            brightness,
            err,
        });
    };
}

pub fn main() !void {
    var args = std.process.args();
    var i: u8 = 0;
    var increase: bool = false;
    var flag: bool = false;
    var get_only: bool = false;
    var brightness: u8 = 0;
    while (args.next()) |arg| : (i += 1) {
        if (i == 0) {
            continue;
        }
        if (std.mem.eql(u8, arg, "-i") == true) {
            increase = true;
            flag = true;
        } else if (std.mem.eql(u8, arg, "-d") == true) {
            increase = false;
            flag = true;
        } else if (std.mem.eql(u8, arg, "-g") == true) {
            get_only = true;
            flag = true;
        } else if (!args.skip() and !get_only) {
            if (std.fmt.parseInt(u8, arg, 10)) |number| {
                brightness = number;
            } else |err| switch (err) {
                error.Overflow => {
                    if (increase) {
                        brightness = 100;
                    } else {
                        brightness = 0;
                    }
                },
                error.InvalidCharacter => {
                    std.debug.print("Invalid brightness value {any}. Please provide a numeric brightness value between 0 and 100", .{brightness});
                    return;
                },
            }
            if (brightness > 100) {
                std.debug.print("Invalid brightness value {d}. Please provide a brightness value between 0 and 100", .{brightness});
                return;
            }
        } else {
            std.debug.print("Invalid argument. Valid uses are: ddc -i <brightness>, ddc -d <brightness>, ddc -g", .{});
            return;
        }
    }

    if (!flag) {
        std.debug.print("No flag was given. Please pass at least one flag. Valid uses are: ddc -i <brightness>, ddc -d <brightness>, ddc -g", .{});
        return;
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const monitors: [2][]const u8 = .{ "/dev/i2c-3", "/dev/i2c-4" };
    var handles: [2]std.Thread = undefined;

    i = 0;
    for (monitors) |monitor| {
        handles[i] = std.Thread.spawn(.{}, run_protocol_logged, .{ allocator, monitor, get_only, increase, brightness, i }) catch |err| {
            std.log.err("Failed to spawn thread for monitor {s}: {}", .{ monitor, err });
            return;
        };
        i += 1;
    }

    for (handles) |handle| handle.join();
}
