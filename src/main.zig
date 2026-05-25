const std = @import("std");
const li2c = @import("li2c");
var global_home: ?[]const u8 = null;

pub const std_options: std.Options = .{
    .logFn = log,
};

fn open_log_writer(allocator: std.mem.Allocator, io: std.Io) !std.Io.File {
    const home = global_home orelse return error.HomeError;

    const dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, ".local/state/ddc" });
    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, ".local/state/ddc/ddc.log" });

    std.Io.Dir.createDirAbsolute(io, dir_path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const file = try std.Io.Dir.createFileAbsolute(io, file_path, .{ .truncate = false });

    return file;
}

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const io = std.Options.debug_io;

    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const file = open_log_writer(allocator, io) catch |err| {
        std.debug.print("Failed to create log writer: {}\n", .{err});
        return;
    };
    defer file.close(io);

    file.lock(io, .exclusive) catch |err| {
        std.debug.print("Failed to lock the log file: {}\n", .{err});
        return;
    };
    defer file.unlock(io);

    var write_buffer: [0]u8 = undefined;
    var writer = file.writer(io, &write_buffer);

    const stat = file.stat(io) catch |err| {
        std.debug.print("Failed to stat log file: {}\n", .{err});
        return;
    };
    writer.seekTo(stat.size) catch |err| {
        std.debug.print("Failed to seek log file: {}\n", .{err});
        return;
    };

    const level_txt = comptime level.asText();
    const scope_txt = @tagName(scope);

    const timestamp_string = construct_timestamp_string(io, allocator) catch |err| {
        std.debug.print("Failed to construct timestamp string: {}\n", .{err});
        return;
    };
    const message = std.fmt.allocPrint(allocator, "[{s}] [{s}]({s}) " ++ format ++ "\n", .{ timestamp_string, level_txt, scope_txt } ++ args) catch |err| {
        std.debug.print("Failed to create log message: {}\n", .{err});
        return;
    };

    writer.interface.writeAll(message) catch |err| {
        std.debug.print("Failed to write to log file: {}\n", .{err});
        return;
    };
    writer.flush() catch |err| {
        std.debug.print("Failed to flush the log file: {}\n", .{err});
        return;
    };
}

fn construct_timestamp_string(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    const ts = std.Io.Timestamp.now(io, .real);
    const now: u64 = @intCast(ts.toSeconds());
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

fn get(io: std.Io, allocator: std.mem.Allocator, i2c_file: std.Io.File, dir_path: []const u8, file_path: []const u8) !u8 {
    if (std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only })) |existing_file| {
        defer existing_file.close(io);

        const file_size = (try existing_file.stat(io)).size;
        const buffer = try allocator.alloc(u8, file_size + 1);
        var reader = existing_file.reader(io, buffer);
        const line = try reader.interface.takeDelimiterExclusive('\n');
        const current_brightness: u8 = try std.fmt.parseInt(u8, line, 10);

        return current_brightness;
    } else |open_err| {
        if (open_err == error.FileNotFound) {
            if (std.Io.Dir.cwd().createFile(io, file_path, .{ .read = false })) |new_file| {
                defer new_file.close(io);
            } else |create_err| {
                if (create_err == error.FileNotFound) {
                    try std.Io.Dir.cwd().createDir(io, dir_path, .default_dir);
                    const new_file = try std.Io.Dir.cwd().createFile(io, file_path, .{ .read = false });
                    defer new_file.close(io);
                }
            }

            const get_luminance: [5]u8 = .{ 0x51, 0x82, 0x01, 0x10, (0x51 ^ 0x82 ^ 0x01 ^ 0x10) };
            try i2c_file.writeStreamingAll(io, &get_luminance);

            try std.Io.sleep(io, .fromMilliseconds(10), .awake);

            // To understand magic numbers, see Page 19 of https://glenwing.github.io/docs/VESA-DDCCI-1.1.pdf
            var luminance_reply: [15]u8 = undefined;
            const n = try i2c_file.readStreaming(io, &.{luminance_reply[0..]});
            if (n < 10) return error.ShortI2cRead;
            const current_brightness: u8 = luminance_reply[9];

            return current_brightness;
        }
    }

    return error.FailedToGetBrightness;
}

fn set(io: std.Io, i2c_file: std.Io.File, new_brightness: u8) !void {
    const set_luminance: [7]u8 = .{ 0x51, 0x84, 0x03, 0x10, 0x00, new_brightness, (0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x00 ^ new_brightness) };
    _ = try i2c_file.writeStreamingAll(io, &set_luminance);

    try std.Io.sleep(io, .fromMilliseconds(5), .awake);
}

fn run_protocol(io: std.Io, allocator: std.mem.Allocator, monitor: []const u8, get_only: bool, increase: bool, brightness: u8, i: u8) !void {
    const addr: u8 = 0x37;

    var file_name: []const u8 = undefined;

    const i2c_file = try std.Io.Dir.openFileAbsolute(io, monitor, .{ .mode = .read_write, .allow_directory = false });
    defer i2c_file.close(io);
    try i2c_file.lock(io, .exclusive);
    defer i2c_file.unlock(io);

    const i2c: i32 = i2c_file.handle;

    const ioctl_result = std.os.linux.ioctl(i2c, li2c.I2C_SLAVE, addr);
    switch (std.os.linux.errno(ioctl_result)) {
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

    const home = global_home orelse {
        std.debug.print("Failed to get $HOME.", .{});
        return;
    };
    var dir_paths: [2][]const u8 = .{
        home,
        ".local/state/ddc",
    };
    const dir_path = try std.fs.path.join(allocator, &dir_paths);

    var file_paths: [2][]const u8 = .{ dir_path, file_name };
    const file_path = try std.fs.path.join(allocator, &file_paths);

    const current_brightness: u8 = try get(io, allocator, i2c_file, dir_path, file_path);
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
            try set(io, i2c_file, new_brightness);
        }
    } else {
        new_brightness = current_brightness;
        if (i == 0) {
            var stdout_buffer: [3]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
            const stdout = &stdout_writer.interface;
            try stdout.print("{{\"brightness\": {d}}}\n", .{new_brightness});
            try stdout.flush();
        }
    }

    const brightness_file = try std.Io.Dir.cwd().createFile(io, file_path, .{ .read = false });
    defer brightness_file.close(io);
    var write_buffer: [0]u8 = undefined;
    var writer = brightness_file.writer(io, &write_buffer);

    var buffer: [4]u8 = undefined;
    const brightness_string = try std.fmt.bufPrint(&buffer, "{}\n", .{new_brightness});
    try writer.interface.writeAll(brightness_string);

    try writer.flush();
}

fn run_protocol_logged(
    io: std.Io,
    allocator: std.mem.Allocator,
    monitor: []const u8,
    get_only: bool,
    increase: bool,
    brightness: u8,
    i: u8,
) void {
    run_protocol(io, allocator, monitor, get_only, increase, brightness, i) catch |err| {
        std.log.err("run_protocol failed for monitor {s} with get_only `{}`, increase `{}` and brightness `{d}`: {}", .{
            monitor,
            get_only,
            increase,
            brightness,
            err,
        });

        if (@errorReturnTrace()) |trace| {
            const file = open_log_writer(allocator, io) catch |open_err| {
                std.log.err("Failed to create log writer: {}\n", .{open_err});
                return;
            };
            defer file.close(io);

            file.lock(io, .exclusive) catch |lock_err| {
                std.debug.print("Failed to lock the log file: {}\n", .{lock_err});
                return;
            };
            defer file.unlock(io);

            const stat = file.stat(io) catch |stat_err| {
                std.log.err("Failed to stat log file: {}\n", .{stat_err});
                return;
            };

            var write_buffer: [0]u8 = undefined;
            var writer = file.writer(io, &write_buffer);

            writer.seekTo(stat.size) catch |seek_err| {
                std.log.err("Failed to seek log file: {}\n", .{seek_err});
                return;
            };
            std.debug.writeErrorReturnTrace(trace, .{ .writer = &writer.interface, .mode = .no_color }) catch |trace_err| {
                std.log.err("Failed to write error return trace: {}\n", .{trace_err});
                return;
            };
            writer.flush() catch |flush_err| {
                std.log.err("Failed to flush the log file: {}\n", .{flush_err});
                return;
            };
        }
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    global_home = init.environ_map.get("HOME") orelse return error.MissingHome;
    var args = init.minimal.args.iterate();
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
                    std.debug.print("Invalid brightness value {any}. Please provide a numeric brightness value between 0 and 100\n", .{brightness});
                    return;
                },
            }
            if (brightness > 100) {
                std.debug.print("Invalid brightness value {d}. Please provide a brightness value between 0 and 100\n", .{brightness});
                return;
            }
        } else {
            std.debug.print("Invalid argument. Valid uses are: ddc -i <brightness>, ddc -d <brightness>, ddc -g\n", .{});
            return;
        }
    }

    if (!flag) {
        std.debug.print("No flag was given. Please pass at least one flag. Valid uses are: ddc -i <brightness>, ddc -d <brightness>, ddc -g\n", .{});
        return;
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const monitors: [2][]const u8 = .{ "/dev/i2c-3", "/dev/i2c-4" };
    var handles: [2]std.Thread = undefined;

    i = 0;
    for (monitors) |monitor| {
        handles[i] = std.Thread.spawn(.{}, run_protocol_logged, .{ io, allocator, monitor, get_only, increase, brightness, i }) catch |err| {
            std.log.err("Failed to spawn thread for monitor {s}: {}", .{ monitor, err });
            return;
        };
        i += 1;
    }

    for (handles) |handle| handle.join();
}
