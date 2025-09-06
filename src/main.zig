const std = @import("std");
const li2c = @cImport({
    @cInclude("linux/i2c-dev.h");
});

fn get(i2c: i32, file_path: []const u8) !u8 {
    if (std.fs.cwd().openFile(file_path, .{ .mode = .read_only })) |existing_file| {
        defer existing_file.close();

        const allocator = std.heap.page_allocator;

        const file_size = (try existing_file.stat()).size;
        const buffer = try allocator.alloc(u8, file_size + 1);
        var reader = existing_file.reader(buffer);
        const line = try reader.interface.takeDelimiterExclusive('\n');
        const current_brightness: u8 = try std.fmt.parseInt(u8, line, 10);

        return current_brightness;
    } else |err| {
        if (err == error.FileNotFound) {
            const new_file = try std.fs.cwd().createFile(file_path, .{ .read = false });
            defer new_file.close();

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

fn run_protocol(monitor: []const u8, get_only: bool, increase: bool, brightness: u8, i: u8) !void {
    const addr: u8 = 0x37;

    var file_name: []const u8 = undefined;

    const i2c: i32 = try std.posix.open(monitor, .{ .ACCMODE = .RDWR }, 0);
    try std.posix.flock(i2c, std.posix.LOCK.EX);
    _ = std.os.linux.ioctl(i2c, li2c.I2C_SLAVE, addr);

    if (i == 0) {
        file_name = "dev-i2c-3.txt";
    } else {
        file_name = "dev-i2c-4.txt";
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const gpa_allocator = gpa.allocator();

    const exe_dir = try std.fs.selfExeDirPathAlloc(gpa_allocator);
    defer gpa_allocator.free(exe_dir);

    var paths: [2][]const u8 = .{ exe_dir, file_name };
    const file_path = try std.fs.path.join(gpa_allocator, &paths);
    defer gpa_allocator.free(file_path);

    const current_brightness: u8 = try get(i2c, file_path);
    var test_brightness: struct { u8, u1 } = .{ undefined, undefined };
    var new_brightness: u8 = 0;

    if (!get_only) {
        if (increase) {
            test_brightness = @addWithOverflow(current_brightness, brightness);
            if (test_brightness[1] == 1) {
                new_brightness = 100;
            } else {
                new_brightness = current_brightness + brightness;
                if (new_brightness > 100) {
                    new_brightness = 100;
                }
            }
        } else {
            test_brightness = @subWithOverflow(current_brightness, brightness);
            if (test_brightness[1] == 1) {
                new_brightness = 0;
            } else {
                new_brightness = current_brightness - brightness;
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
                    std.log.err("Invalid brightness value {any}. Please provide a numeric brightness value between 0 and 100", .{brightness});
                    return;
                },
            }
            if (brightness > 100) {
                std.log.err("Invalid brightness value {d}. Please provide a brightness value between 0 and 100", .{brightness});
                return;
            }
        } else {
            std.log.err("Invalid argument. Valid uses are: ddc -i <brightness>, ddc -d <brightness>, ddc -g", .{});
            return;
        }
    }

    if (!flag) {
        std.log.err("No flag was given. Please pass at least one flag. Valid uses are: ddc -i <brightness>, ddc -d <brightness>, ddc -g", .{});
        return;
    }

    const monitors: [2][]const u8 = .{ "/dev/i2c-3", "/dev/i2c-4" };
    var handles: [2]std.Thread = undefined;

    i = 0;
    for (monitors) |monitor| {
        handles[i] = try std.Thread.spawn(.{}, run_protocol, .{ monitor, get_only, increase, brightness, i });
        i += 1;
    }

    for (handles) |handle| handle.join();
}
