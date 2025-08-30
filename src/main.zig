const std = @import("std");
const li2c = @cImport({
    @cInclude("linux/i2c-dev.h");
});

fn get(i2c: i32, file_name: []const u8) !u8 {
    if (std.fs.cwd().openFile(file_name, .{ .mode = .read_only })) |existing_file| {
        defer existing_file.close();

        const allocator = std.heap.page_allocator;

        const file_size = (try existing_file.stat()).size;
        const buffer = try allocator.alloc(u8, file_size);
        try existing_file.reader().readNoEof(buffer);
        const current_brightness: u8 = try std.fmt.parseInt(u8, buffer, 10);

        return current_brightness;
    } else |err| {
        if (err == error.FileNotFound) {
            const new_file = try std.fs.cwd().createFile(file_name, .{ .read = false });
            defer new_file.close();

            const get_luminance: [5]u8 = .{ 0x51, 0x82, 0x01, 0x10, (0x51 ^ 0x82 ^ 0x01 ^ 0x10) };
            _ = try std.posix.write(i2c, &get_luminance);

            std.Thread.sleep(10 * std.time.ns_per_us);

            var luminance_reply: [15]u8 = undefined;
            _ = try std.posix.read(i2c, &luminance_reply);
            const current_brightness: u8 = luminance_reply[9]; // Page 19 of https://glenwing.github.io/docs/VESA-DDCCI-1.1.pdf

            return current_brightness;
        }
    }

    return error.FailedToGetBrightness;
}

fn set(i2c: i32, new_brightness: u8) !void {
    const set_luminance: [7]u8 = .{ 0x51, 0x84, 0x03, 0x10, 0x00, new_brightness, (0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x00 ^ new_brightness) };
    _ = try std.posix.write(i2c, &set_luminance);

    std.Thread.sleep(5 * std.time.ns_per_us);
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
        } else if (!args.skip() and !get_only) {
            brightness = try std.fmt.parseInt(u8, arg, 10);
        } else {
            std.debug.print("Invalid argument. Valid uses are: ddc -i <brightness>, ddc -d <brightness>, ddc -g\n", .{});
        }
    }

    const monitors: [2][]const u8 = .{ "/dev/i2c-3", "/dev/i2c-4" };
    const addr: u8 = 0x37;

    var new_brightness: u8 = 0;
    var file_name: []const u8 = undefined;
    i = 0;
    for (monitors) |monitor| {
        const i2c: i32 = try std.posix.open(monitor, .{ .ACCMODE = .RDWR }, 0);
        try std.posix.flock(i2c, std.posix.LOCK.EX);
        _ = std.os.linux.ioctl(i2c, li2c.I2C_SLAVE, addr);

        if (i == 0) {
            file_name = "dev-i2c-3.txt";
        } else {
            file_name = "dev-i2c-4.txt";
        }

        const current_brightness: u8 = try get(i2c, file_name);

        if (!get_only) {
            if (increase) {
                new_brightness = current_brightness + brightness;
            } else {
                new_brightness = current_brightness - brightness;
            }

            if (new_brightness > 100) {
                new_brightness = 100;
            } else if (new_brightness < 0) {
                new_brightness = 0;
            }

            if (new_brightness != current_brightness) {
                try set(i2c, new_brightness);
            }
        } else {
            new_brightness = current_brightness;
            if (i == 0) {
                const outb = std.io.getStdOut().writer();
                try outb.print("{{\"brightness\": {d}}}\n", .{new_brightness});
            }
        }

        try std.posix.flock(i2c, std.posix.LOCK.UN);

        const brightness_file = try std.fs.cwd().createFile(file_name, .{ .read = false });
        defer brightness_file.close();
        var buffer: [3]u8 = undefined;
        const brightness_string = try std.fmt.bufPrint(&buffer, "{}", .{new_brightness});
        try brightness_file.writeAll(brightness_string);

        i += 1;
    }
}
