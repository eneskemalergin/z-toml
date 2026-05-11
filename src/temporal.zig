const std = @import("std");
const types = @import("value.zig");

fn appendFraction(buf: []u8, nanosecond: u32) []const u8 {
    if (nanosecond == 0) return "";

    var digits_buf: [9]u8 = undefined;
    _ = std.fmt.bufPrint(&digits_buf, "{d:0>9}", .{nanosecond}) catch return "";

    var end = digits_buf.len;
    while (end > 0 and digits_buf[end - 1] == '0') : (end -= 1) {}
    return std.fmt.bufPrint(buf, ".{s}", .{digits_buf[0..end]}) catch "";
}

pub fn writeOffset(w: *std.Io.Writer, offset_minutes: i16) std.Io.Writer.Error!void {
    if (offset_minutes == 0) return w.writeByte('Z');
    const abs = if (offset_minutes < 0) @as(u16, @intCast(-offset_minutes)) else @as(u16, @intCast(offset_minutes));
    const sign: u8 = if (offset_minutes < 0) '-' else '+';
    try w.print("{c}{d:0>2}:{d:0>2}", .{ sign, abs / 60, abs % 60 });
}

pub fn writeLocalDate(w: *std.Io.Writer, d: types.LocalDate) std.Io.Writer.Error!void {
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ d.year, d.month, d.day });
}

pub fn writeLocalTime(w: *std.Io.Writer, t: types.LocalTime) std.Io.Writer.Error!void {
    try w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ t.hour, t.minute, t.second });
    if (t.nanosecond != 0) {
        var digits_buf: [9]u8 = undefined;
        const digits = std.fmt.bufPrint(&digits_buf, "{d:0>9}", .{t.nanosecond}) catch return;
        var end = digits.len;
        while (end > 0 and digits[end - 1] == '0') end -= 1;
        try w.print(".{s}", .{digits[0..end]});
    }
}

pub fn formatLocalDate(buf: []u8, value: types.LocalDate) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ value.year, value.month, value.day }) catch "";
}

pub fn formatLocalTime(buf: []u8, value: types.LocalTime) []const u8 {
    var fraction_buf: [16]u8 = undefined;
    const fraction = appendFraction(&fraction_buf, value.nanosecond);
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}{s}", .{
        value.hour,
        value.minute,
        value.second,
        fraction,
    }) catch "";
}

pub fn formatLocalDateTime(buf: []u8, value: types.LocalDateTime) []const u8 {
    var date_buf: [16]u8 = undefined;
    var time_buf: [24]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}T{s}", .{
        formatLocalDate(&date_buf, value.date),
        formatLocalTime(&time_buf, value.time),
    }) catch "";
}

pub fn formatOffsetDateTime(buf: []u8, value: types.OffsetDateTime) []const u8 {
    var local_buf: [48]u8 = undefined;
    const local = formatLocalDateTime(&local_buf, .{ .date = value.date, .time = value.time });
    if (value.offset_minutes == 0) {
        return std.fmt.bufPrint(buf, "{s}Z", .{local}) catch "";
    }

    const total_minutes = @abs(value.offset_minutes);
    const offset_hours = @divTrunc(total_minutes, 60);
    const offset_mins = @mod(total_minutes, 60);
    const sign: u8 = if (value.offset_minutes < 0) '-' else '+';
    return std.fmt.bufPrint(buf, "{s}{c}{d:0>2}:{d:0>2}", .{ local, sign, offset_hours, offset_mins }) catch "";
}
