/// TOML v1.1.0 single-pass recursive-descent parser.
const std = @import("std");
const types = @import("types.zig");

pub const Table = types.Table;
pub const Array = types.Array;
pub const Value = types.Value;
pub const LocalDate = types.LocalDate;
pub const LocalTime = types.LocalTime;
pub const LocalDateTime = types.LocalDateTime;
pub const OffsetDateTime = types.OffsetDateTime;

const Allocator = std.mem.Allocator;

pub const ParseError = error{ ParseFailed, OutOfMemory };

pub const ErrorInfo = struct {
    line: u32 = 0,
    col: u32 = 0,
    _buf: [256]u8 = [_]u8{0} ** 256,
    _len: usize = 0,

    pub fn message(self: *const ErrorInfo) []const u8 {
        return self._buf[0..self._len];
    }
};

const TableKind = enum(u3) { root, implicit, dotted, header, inline_t, aot_array };
const KeyKind = enum(u3) { value, implicit_table, dotted_table, header_table, inline_table, aot_array };

const TableMeta = struct {
    kind: TableKind,
    key_kinds: std.StringHashMapUnmanaged(KeyKind),
};

const Parser = struct {
    gpa: Allocator,
    input: []const u8,
    pos: usize,
    line: u32,
    line_start: usize,
    root: *Table,
    cur: *Table,
    meta_arena: std.heap.ArenaAllocator,
    table_metas: std.AutoHashMapUnmanaged(*Table, *TableMeta),
    err_info: ErrorInfo,

    fn init(gpa: Allocator, input: []const u8) Allocator.Error!Parser {
        const root = try gpa.create(Table);
        root.* = .empty;
        errdefer {
            root.deinit(gpa);
            gpa.destroy(root);
        }

        var p = Parser{
            .gpa = gpa,
            .input = input,
            .pos = 0,
            .line = 1,
            .line_start = 0,
            .root = root,
            .cur = root,
            .meta_arena = std.heap.ArenaAllocator.init(gpa),
            .table_metas = .empty,
            .err_info = .{},
        };
        _ = try p.createMeta(root, .root);
        return p;
    }

    fn deinit(self: *Parser) void {
        self.meta_arena.deinit();
    }

    fn createMeta(self: *Parser, tbl: *Table, kind: TableKind) Allocator.Error!*TableMeta {
        const ma = self.meta_arena.allocator();
        const m = try ma.create(TableMeta);
        m.* = .{ .kind = kind, .key_kinds = .empty };
        try self.table_metas.put(ma, tbl, m);
        return m;
    }

    fn getMeta(self: *Parser, tbl: *Table) *TableMeta {
        return self.table_metas.get(tbl).?;
    }

    fn fail(self: *Parser, comptime fmt: []const u8, args: anytype) ParseError {
        self.err_info.line = self.line;
        self.err_info.col = @intCast(self.pos - self.line_start + 1);
        const msg = std.fmt.bufPrint(&self.err_info._buf, fmt, args) catch blk: {
            const s = "error message too long";
            @memcpy(self.err_info._buf[0..s.len], s);
            break :blk self.err_info._buf[0..s.len];
        };
        self.err_info._len = msg.len;
        return error.ParseFailed;
    }

    inline fn peek(self: *const Parser) ?u8 {
        if (self.pos >= self.input.len) return null;
        return self.input[self.pos];
    }

    inline fn peekAt(self: *const Parser, offset: usize) ?u8 {
        const i = self.pos + offset;
        if (i >= self.input.len) return null;
        return self.input[i];
    }

    inline fn advance(self: *Parser) void {
        if (self.pos < self.input.len) {
            if (self.input[self.pos] == '\n') {
                self.line += 1;
                self.line_start = self.pos + 1;
            }
            self.pos += 1;
        }
    }

    inline fn eat(self: *Parser, ch: u8) bool {
        if (self.peek() == ch) {
            self.advance();
            return true;
        }
        return false;
    }

    fn expect(self: *Parser, ch: u8) ParseError!void {
        if (!self.eat(ch)) return self.fail("expected '{c}', found '{?c}'", .{ ch, self.peek() });
    }

    fn skipInlineWs(self: *Parser) void {
        while (self.peek()) |c| {
            if (c == ' ' or c == '\t') self.advance() else break;
        }
    }

    fn skipTrivia(self: *Parser) ParseError!void {
        while (self.peek()) |c| switch (c) {
            ' ', '\t', '\n' => self.advance(),
            '\r' => if (self.peekAt(1) == '\n') {
                self.advance();
                self.advance();
            } else return self.fail("bare CR not allowed", .{}),
            '#' => try self.skipComment(),
            else => break,
        };
    }

    fn skipComment(self: *Parser) ParseError!void {
        self.advance();
        while (self.peek()) |c| {
            if (c == '\n' or c == '\r') break;
            if (c != '\t' and (c < 0x20 or c == 0x7F))
                return self.fail("control character U+{X:0>4} not allowed in comment", .{c});
            self.advance();
        }
    }

    fn skipToEOL(self: *Parser) ParseError!void {
        while (self.peek()) |c| {
            if (c == '\n') {
                self.advance();
                return;
            }
            if (c == '\r') {
                if (self.peekAt(1) != '\n') return self.fail("bare CR not allowed", .{});
                self.advance();
                self.advance();
                return;
            }
            self.advance();
        }
    }

    inline fn isEOL(self: *const Parser) bool {
        const c = self.peek() orelse return true;
        return switch (c) {
            '\n' => true,
            '\r' => self.peekAt(1) == '\n',
            else => false,
        };
    }

    fn eatNewline(self: *Parser) ParseError!void {
        if (self.peek()) |c| switch (c) {
            '\n' => self.advance(),
            '\r' => {
                self.advance();
                if (self.peek() != '\n') return self.fail("bare CR not allowed", .{});
                self.advance();
            },
            else => {},
        };
    }

    // ─── key parsing ─────────────────────────────────────────────────────────

    fn parseKeyPart(self: *Parser) ParseError![]u8 {
        return switch (self.peek() orelse 0) {
            '"' => self.parseBasicStringRaw(),
            '\'' => self.parseLiteralStringRaw(),
            else => self.parseBareKey(),
        };
    }

    fn parseBareKey(self: *Parser) ParseError![]u8 {
        const start = self.pos;
        while (self.peek()) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') self.advance() else break;
        }
        if (self.pos == start) return self.fail("expected a key", .{});
        return self.gpa.dupe(u8, self.input[start..self.pos]) catch error.OutOfMemory;
    }

    fn parseDottedKey(self: *Parser) ParseError!std.ArrayList([]u8) {
        var parts: std.ArrayList([]u8) = .empty;
        errdefer {
            for (parts.items) |p| self.gpa.free(p);
            parts.deinit(self.gpa);
        }
        const first = try self.parseKeyPart();
        try parts.append(self.gpa, first);
        while (true) {
            self.skipInlineWs();
            if (!self.eat('.')) break;
            self.skipInlineWs();
            try parts.append(self.gpa, try self.parseKeyPart());
        }
        return parts;
    }

    // ─── string parsing ───────────────────────────────────────────────────────

    fn parseBasicStringRaw(self: *Parser) ParseError![]u8 {
        try self.expect('"');
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.gpa);
        try self.parseBasicStringContents(&buf, false);
        try self.expect('"');
        return buf.toOwnedSlice(self.gpa) catch error.OutOfMemory;
    }

    fn parseMLBasicString(self: *Parser) ParseError!Value {
        try self.expect('"');
        try self.expect('"');
        try self.expect('"');
        _ = self.eat('\r');
        _ = self.eat('\n');
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.gpa);
        outer: while (true) {
            const c = self.peek() orelse return self.fail("unterminated multi-line basic string", .{});
            if (c == '"') {
                var q: usize = 0;
                while (self.peek() == '"' and q < 5) {
                    self.advance();
                    q += 1;
                }
                if (q >= 3) {
                    for (0..q - 3) |_| try buf.append(self.gpa, '"');
                    break :outer;
                }
                for (0..q) |_| try buf.append(self.gpa, '"');
                continue;
            }
            if (c == '\\') {
                self.advance();
                try self.processEscape(&buf, true);
                continue;
            }
            if (c == '\r') {
                self.advance();
                if (self.peek() != '\n') return self.fail("bare CR not allowed in string", .{});
                try buf.append(self.gpa, '\n');
                self.advance();
                continue;
            }
            if (c != '\t' and c != '\n' and (c < 0x20 or c == 0x7F))
                return self.fail("control character U+{X:0>4} not allowed in string", .{c});
            self.advance();
            try buf.append(self.gpa, c);
        }
        return .{ .string = try buf.toOwnedSlice(self.gpa) };
    }

    fn parseBasicStringContents(self: *Parser, buf: *std.ArrayList(u8), multiline: bool) ParseError!void {
        while (true) {
            const c = self.peek() orelse return self.fail("unterminated string", .{});
            if (c == '"') return;
            if (c == '\\') {
                self.advance();
                try self.processEscape(buf, multiline);
                continue;
            }
            if (c == '\r') {
                if (!multiline) return self.fail("newline in single-line string", .{});
                self.advance();
                if (self.peek() != '\n') return self.fail("bare CR not allowed", .{});
                try buf.append(self.gpa, '\n');
                self.advance();
                continue;
            }
            if (c == '\n') {
                if (!multiline) return self.fail("newline in single-line string", .{});
                self.advance();
                try buf.append(self.gpa, '\n');
                continue;
            }
            if (c != '\t' and (c < 0x20 or c == 0x7F))
                return self.fail("control character U+{X:0>4} not allowed in string", .{c});
            self.advance();
            try buf.append(self.gpa, c);
        }
    }

    fn processEscape(self: *Parser, buf: *std.ArrayList(u8), multiline: bool) ParseError!void {
        const c = self.peek() orelse return self.fail("unterminated escape sequence", .{});
        switch (c) {
            'b' => {
                self.advance();
                try buf.append(self.gpa, '\x08');
            },
            't' => {
                self.advance();
                try buf.append(self.gpa, '\t');
            },
            'n' => {
                self.advance();
                try buf.append(self.gpa, '\n');
            },
            'f' => {
                self.advance();
                try buf.append(self.gpa, '\x0C');
            },
            'r' => {
                self.advance();
                try buf.append(self.gpa, '\r');
            },
            'e' => {
                self.advance();
                try buf.append(self.gpa, '\x1B');
            },
            '"' => {
                self.advance();
                try buf.append(self.gpa, '"');
            },
            '\\' => {
                self.advance();
                try buf.append(self.gpa, '\\');
            },
            'x' => {
                self.advance();
                const cp = try self.parseHexEscape(2);
                try appendCodepoint(self, buf, cp);
            },
            'u' => {
                self.advance();
                const cp = try self.parseHexEscape(4);
                try appendCodepoint(self, buf, cp);
            },
            'U' => {
                self.advance();
                const cp = try self.parseHexEscape(8);
                try appendCodepoint(self, buf, cp);
            },
            '\n', '\r' => {
                if (!multiline) return self.fail("line-ending backslash only in multi-line strings", .{});
                while (self.peek()) |ch| {
                    if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') self.advance() else break;
                }
            },
            ' ', '\t' => {
                if (!multiline) return self.fail("invalid escape '\\{c}'", .{c});
                while (self.peek()) |ch| {
                    if (ch == ' ' or ch == '\t') self.advance() else break;
                }
                if (self.peek() != '\n' and self.peek() != '\r')
                    return self.fail("backslash-whitespace only valid before newline in ML strings", .{});
                while (self.peek()) |ch| {
                    if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') self.advance() else break;
                }
            },
            else => return self.fail("invalid escape sequence '\\{c}'", .{c}),
        }
    }

    fn appendCodepoint(self: *Parser, buf: *std.ArrayList(u8), cp: u32) ParseError!void {
        if (cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF))
            return self.fail("invalid unicode scalar U+{X:0>6}", .{cp});
        var tmp: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(@intCast(cp), &tmp) catch
            return self.fail("invalid unicode scalar U+{X:0>6}", .{cp});
        try buf.appendSlice(self.gpa, tmp[0..len]);
    }

    fn parseHexEscape(self: *Parser, digits: usize) ParseError!u32 {
        var val: u32 = 0;
        for (0..digits) |_| {
            const c = self.peek() orelse return self.fail("incomplete hex escape", .{});
            const d: u32 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => return self.fail("invalid hex digit '{c}'", .{c}),
            };
            val = (val << 4) | d;
            self.advance();
        }
        return val;
    }

    fn parseLiteralStringRaw(self: *Parser) ParseError![]u8 {
        try self.expect('\'');
        const start = self.pos;
        while (true) {
            const c = self.peek() orelse return self.fail("unterminated literal string", .{});
            if (c == '\'') break;
            if (c == '\n' or c == '\r') return self.fail("newline in single-line literal string", .{});
            if (c != '\t' and (c < 0x20 or c == 0x7F)) return self.fail("control character in literal string", .{});
            self.advance();
        }
        const s = try self.gpa.dupe(u8, self.input[start..self.pos]);
        try self.expect('\'');
        return s;
    }

    fn parseMLLiteralString(self: *Parser) ParseError!Value {
        try self.expect('\'');
        try self.expect('\'');
        try self.expect('\'');
        _ = self.eat('\r');
        _ = self.eat('\n');
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.gpa);
        outer: while (true) {
            const c = self.peek() orelse return self.fail("unterminated multi-line literal string", .{});
            if (c == '\'') {
                var q: usize = 0;
                while (self.peek() == '\'' and q < 5) {
                    self.advance();
                    q += 1;
                }
                if (q >= 3) {
                    for (0..q - 3) |_| try buf.append(self.gpa, '\'');
                    break :outer;
                }
                for (0..q) |_| try buf.append(self.gpa, '\'');
                continue;
            }
            if (c == '\r') {
                self.advance();
                if (self.peek() != '\n') return self.fail("bare CR not allowed", .{});
                try buf.append(self.gpa, '\n');
                self.advance();
                continue;
            }
            if (c != '\t' and c != '\n' and (c < 0x20 or c == 0x7F))
                return self.fail("control character in multi-line literal string", .{});
            self.advance();
            try buf.append(self.gpa, c);
        }
        return .{ .string = try buf.toOwnedSlice(self.gpa) };
    }

    // ─── value parsing ────────────────────────────────────────────────────────

    fn parseValue(self: *Parser) ParseError!Value {
        const c = self.peek() orelse return self.fail("expected a value", .{});
        return switch (c) {
            '"' => if (self.peekAt(1) == '"' and self.peekAt(2) == '"') self.parseMLBasicString() else .{ .string = try self.parseBasicStringRaw() },
            '\'' => if (self.peekAt(1) == '\'' and self.peekAt(2) == '\'') self.parseMLLiteralString() else .{ .string = try self.parseLiteralStringRaw() },
            't' => self.parseTrue(),
            'f' => self.parseFalse(),
            '[' => self.parseArray(),
            '{' => self.parseInlineTable(),
            '+', '-', '0'...'9' => self.parseNumericOrDatetime(),
            'i', 'n' => self.parseInfOrNan(),
            else => self.fail("unexpected character '{c}' while parsing value", .{c}),
        };
    }

    fn parseTrue(self: *Parser) ParseError!Value {
        if (self.input.len - self.pos >= 4 and std.mem.eql(u8, self.input[self.pos .. self.pos + 4], "true")) {
            self.pos += 4;
            return .{ .boolean = true };
        }
        return self.fail("expected 'true'", .{});
    }

    fn parseFalse(self: *Parser) ParseError!Value {
        if (self.input.len - self.pos >= 5 and std.mem.eql(u8, self.input[self.pos .. self.pos + 5], "false")) {
            self.pos += 5;
            return .{ .boolean = false };
        }
        return self.fail("expected 'false'", .{});
    }

    fn parseInfOrNan(self: *Parser) ParseError!Value {
        const sign: f64 = if (self.peek() == '+') blk: {
            self.advance();
            break :blk 1.0;
        } else if (self.peek() == '-') blk: {
            self.advance();
            break :blk -1.0;
        } else 1.0;
        const rem = self.input[self.pos..];
        if (rem.len >= 3 and std.mem.eql(u8, rem[0..3], "inf")) {
            self.pos += 3;
            return .{ .float = sign * std.math.inf(f64) };
        }
        if (rem.len >= 3 and std.mem.eql(u8, rem[0..3], "nan")) {
            self.pos += 3;
            return .{ .float = std.math.nan(f64) };
        }
        return self.fail("expected 'inf' or 'nan'", .{});
    }

    fn parseNumericOrDatetime(self: *Parser) ParseError!Value {
        const sign_offset: usize = if (self.peek() == '+' or self.peek() == '-') 1 else 0;
        if (sign_offset == 1) {
            const rest = self.input[self.pos + 1 ..];
            if (rest.len >= 3 and (std.mem.startsWith(u8, rest, "inf") or std.mem.startsWith(u8, rest, "nan")))
                return self.parseInfOrNan();
        }
        // Local time HH:MM
        if (sign_offset == 0 and isDigit(self.peek()) and isDigit(self.peekAt(1)) and self.peekAt(2) == ':')
            return self.parseDatetimeOrTime();
        // Date YYYY-MM-DD
        if (sign_offset == 0 and self.peekAt(4) == '-' and
            isDigit(self.peek()) and isDigit(self.peekAt(1)) and
            isDigit(self.peekAt(2)) and isDigit(self.peekAt(3)))
            return self.parseDatetimeOrTime();
        return self.parseIntOrFloat();
    }

    fn parseDatetimeOrTime(self: *Parser) ParseError!Value {
        if (isDigit(self.peek()) and isDigit(self.peekAt(1)) and
            self.peekAt(2) == ':' and self.peekAt(4) != '-')
        {
            return .{ .local_time = try self.parseLocalTime() };
        }
        const date = try self.parseLocalDate();
        const sep = self.peek();
        if (sep == 'T' or sep == 't' or (sep == ' ' and isDigit(self.peekAt(1)))) {
            self.advance();
            const time = try self.parseLocalTime();
            const off_ch = self.peek();
            if (off_ch == 'Z' or off_ch == 'z' or off_ch == '+' or off_ch == '-') {
                return .{ .offset_datetime = .{ .date = date, .time = time, .offset_minutes = try self.parseOffset() } };
            }
            return .{ .local_datetime = .{ .date = date, .time = time } };
        }
        return .{ .local_date = date };
    }

    fn parseLocalDate(self: *Parser) ParseError!LocalDate {
        const y = try self.parseNDigits(4);
        try self.expect('-');
        const mo = try self.parseNDigits(2);
        try self.expect('-');
        const d = try self.parseNDigits(2);
        if (mo < 1 or mo > 12) return self.fail("invalid month {d}", .{mo});
        const max_day = daysInMonth(y, mo);
        if (d < 1 or d > max_day) return self.fail("invalid day {d}", .{d});
        return .{ .year = @intCast(y), .month = @intCast(mo), .day = @intCast(d) };
    }

    fn parseLocalTime(self: *Parser) ParseError!LocalTime {
        const h = try self.parseNDigits(2);
        try self.expect(':');
        const m = try self.parseNDigits(2);
        if (h > 23) return self.fail("invalid hour {d}", .{h});
        if (m > 59) return self.fail("invalid minute {d}", .{m});
        var s: u32 = 0;
        if (self.peek() == ':') {
            self.advance();
            s = try self.parseNDigits(2);
            if (s > 60) return self.fail("invalid second {d}", .{s});
        }
        var ns: u32 = 0;
        if (self.eat('.')) {
            const start = self.pos;
            while (isDigit(self.peek())) self.advance();
            const frac = self.input[start..self.pos];
            if (frac.len == 0) return self.fail("expected digits after decimal point in time", .{});
            var v: u32 = 0;
            var used: usize = 0;
            for (frac) |dc| {
                if (used >= 9) break;
                v = v * 10 + (dc - '0');
                used += 1;
            }
            var scale: u32 = 1;
            var rem2: usize = 9 - used;
            while (rem2 > 0) : (rem2 -= 1) scale *= 10;
            ns = v * scale;
        }
        return .{ .hour = @intCast(h), .minute = @intCast(m), .second = @intCast(s), .nanosecond = ns };
    }

    fn parseOffset(self: *Parser) ParseError!i16 {
        const c = self.peek() orelse return self.fail("expected offset", .{});
        if (c == 'Z' or c == 'z') {
            self.advance();
            return 0;
        }
        const neg = c == '-';
        self.advance();
        const h = try self.parseNDigits(2);
        try self.expect(':');
        const m = try self.parseNDigits(2);
        if (h > 23 or m > 59) return self.fail("invalid UTC offset", .{});
        const tot: i16 = @intCast(h * 60 + m);
        return if (neg) -tot else tot;
    }

    fn parseNDigits(self: *Parser, n: usize) ParseError!u32 {
        var v: u32 = 0;
        for (0..n) |_| {
            const c = self.peek() orelse return self.fail("expected {d} digits", .{n});
            if (!isDigit(c)) return self.fail("expected digit, found '{c}'", .{c});
            v = v * 10 + (c - '0');
            self.advance();
        }
        return v;
    }

    fn consumeDigitsWithUnderscores(self: *Parser) ParseError!usize {
        const start = self.pos;
        var saw_digit = false;
        var last_was_underscore = false;

        while (self.peek()) |c| switch (c) {
            '0'...'9' => {
                saw_digit = true;
                last_was_underscore = false;
                self.advance();
            },
            '_' => {
                if (!saw_digit or last_was_underscore) return self.fail("invalid underscore in number", .{});
                const next = self.peekAt(1) orelse return self.fail("invalid underscore in number", .{});
                if (!isDigit(next)) return self.fail("invalid underscore in number", .{});
                last_was_underscore = true;
                self.advance();
            },
            else => break,
        };

        if (!saw_digit or last_was_underscore) return self.fail("expected digits", .{});
        return start;
    }

    fn sanitizedNumber(self: *Parser, start: usize, end: usize, buf: []u8) ParseError![]const u8 {
        var len: usize = 0;
        for (self.input[start..end]) |c| {
            if (c == '_') continue;
            if (len >= buf.len) return self.fail("number literal too long", .{});
            buf[len] = c;
            len += 1;
        }
        return buf[0..len];
    }

    fn parsePrefixedInt(self: *Parser, comptime base: u8, comptime prefix: []const u8) ParseError!Value {
        std.debug.assert(self.peek() == '0');
        std.debug.assert(self.peekAt(1) != null and self.peekAt(1).? == prefix[1]);

        self.pos += 2;
        const start = self.pos;
        var saw_digit = false;
        var last_was_underscore = false;

        while (self.peek()) |c| {
            if (isBaseDigit(c, base)) {
                saw_digit = true;
                last_was_underscore = false;
                self.advance();
                continue;
            }

            if (c == '_') {
                if (!saw_digit or last_was_underscore) return self.fail("invalid underscore in integer", .{});
                const next = self.peekAt(1) orelse return self.fail("invalid underscore in integer", .{});
                if (!isBaseDigit(next, base)) return self.fail("invalid underscore in integer", .{});
                last_was_underscore = true;
                self.advance();
                continue;
            }

            break;
        }

        if (!saw_digit or last_was_underscore) return self.fail("invalid {s} integer", .{prefix});

        var buf: [72]u8 = undefined;
        const numstr = try self.sanitizedNumber(start, self.pos, &buf);
        const v = std.fmt.parseInt(i64, numstr, base) catch return self.fail("invalid {s} integer", .{prefix});
        return .{ .integer = v };
    }

    fn parseIntOrFloat(self: *Parser) ParseError!Value {
        const start = self.pos;
        const has_sign = self.peek() == '+' or self.peek() == '-';
        if (has_sign) self.advance();
        if (self.peek() == '0') {
            if (self.peekAt(1) == 'X') return self.fail("uppercase hexadecimal prefix is not allowed", .{});
            if (self.peekAt(1) == 'x') {
                if (has_sign) return self.fail("sign not allowed for hexadecimal integer", .{});
                return self.parsePrefixedInt(16, "0x");
            }
            if (self.peekAt(1) == 'o') {
                if (has_sign) return self.fail("sign not allowed for octal integer", .{});
                return self.parsePrefixedInt(8, "0o");
            }
            if (self.peekAt(1) == 'b') {
                if (has_sign) return self.fail("sign not allowed for binary integer", .{});
                return self.parsePrefixedInt(2, "0b");
            }
        }

        const int_start = try self.consumeDigitsWithUnderscores();
        const int_end = self.pos;
        var is_float = false;

        const integer_digits = self.input[int_start..int_end];
        const integer_starts_with_zero = integer_digits.len > 0 and integer_digits[0] == '0';
        const integer_is_zero = std.mem.eql(u8, integer_digits, "0");

        if (self.peek() == '.') {
            is_float = true;
            self.advance();
            _ = try self.consumeDigitsWithUnderscores();
        }

        if (self.peek() == 'e' or self.peek() == 'E') {
            is_float = true;
            self.advance();
            if (self.peek() == '+' or self.peek() == '-') self.advance();
            _ = try self.consumeDigitsWithUnderscores();
        }

        if (is_float and integer_starts_with_zero and !integer_is_zero)
            return self.fail("leading zeros in float", .{});

        var buf: [64]u8 = undefined;
        const numstr = try self.sanitizedNumber(start, self.pos, &buf);
        if (is_float) {
            return .{ .float = std.fmt.parseFloat(f64, numstr) catch return self.fail("invalid float '{s}'", .{numstr}) };
        } else {
            const s = if (numstr[0] == '+' or numstr[0] == '-') numstr[1..] else numstr;
            if (s.len > 1 and s[0] == '0') return self.fail("leading zeros in integer", .{});
            return .{ .integer = std.fmt.parseInt(i64, numstr, 10) catch return self.fail("invalid integer '{s}'", .{numstr}) };
        }
    }

    fn parseArray(self: *Parser) ParseError!Value {
        try self.expect('[');
        const arr = try self.gpa.create(Array);
        arr.* = .empty;
        errdefer {
            for (arr.items) |item| item.deinit(self.gpa);
            arr.deinit(self.gpa);
            self.gpa.destroy(arr);
        }
        try self.skipTrivia();
        while (self.peek() != ']') {
            if (self.peek() == null) return self.fail("unterminated array", .{});
            const v = try self.parseValue();
            try arr.append(self.gpa, v);
            try self.skipTrivia();
            if (!self.eat(',')) {
                try self.skipTrivia();
                break;
            }
            try self.skipTrivia();
        }
        try self.expect(']');
        return .{ .array = arr };
    }

    fn parseInlineTable(self: *Parser) ParseError!Value {
        try self.expect('{');
        const tbl = try self.gpa.create(Table);
        tbl.* = .empty;
        errdefer {
            types.deinitTable(tbl, self.gpa);
            self.gpa.destroy(tbl);
        }
        _ = try self.createMeta(tbl, .inline_t);
        try self.skipTrivia();
        while (self.peek() != '}') {
            if (self.peek() == null) return self.fail("unterminated inline table", .{});
            var key_parts = try self.parseDottedKey();
            defer {
                for (key_parts.items) |p| self.gpa.free(p);
                key_parts.deinit(self.gpa);
            }
            self.skipInlineWs();
            try self.expect('=');
            self.skipInlineWs();
            const val = try self.parseValue();
            errdefer val.deinit(self.gpa);
            try self.setNestedKey(tbl, key_parts.items, val, true);
            try self.skipTrivia();
            if (!self.eat(',')) {
                try self.skipTrivia();
                break;
            }
            try self.skipTrivia();
        }
        try self.expect('}');
        return .{ .table = tbl };
    }

    // ─── nested key assignment ────────────────────────────────────────────────

    fn setNestedKey(self: *Parser, base: *Table, parts: [][]u8, value: Value, inline_ctx: bool) ParseError!void {
        std.debug.assert(parts.len > 0);
        const ma = self.meta_arena.allocator();
        var tbl = base;
        var meta = self.getMeta(tbl);

        for (parts[0 .. parts.len - 1]) |part| {
            if (meta.kind == .inline_t and !inline_ctx)
                return self.fail("cannot extend inline table", .{});
            const gop = tbl.getOrPut(self.gpa, part) catch return error.OutOfMemory;
            if (!gop.found_existing) {
                // Initialize sentinels immediately: deinitTable is safe even if
                // subsequent allocations fail (free of zero-len key = no-op,
                // deinit of boolean = no-op; no errdefer needed).
                gop.value_ptr.* = .{ .boolean = false };
                gop.key_ptr.* = &.{};
                const sub = try self.gpa.create(Table);
                sub.* = .empty;
                gop.value_ptr.* = .{ .table = sub };
                const sub_meta = try self.createMeta(sub, .implicit);
                const key_copy = try self.gpa.dupe(u8, part);
                gop.key_ptr.* = key_copy;
                sub_meta.kind = .dotted;
                try meta.key_kinds.put(ma, gop.key_ptr.*, .dotted_table);
                tbl = sub;
                meta = self.getMeta(tbl);
            } else {
                const kk = meta.key_kinds.get(gop.key_ptr.*) orelse .value;
                switch (kk) {
                    .value, .inline_table => return self.fail("key '{s}' is already defined as a non-table value", .{part}),
                    .aot_array => return self.fail("cannot assign dotted key through array of tables '{s}'", .{part}),
                    .header_table => return self.fail("cannot append to explicitly defined table '{s}' with dotted keys", .{part}),
                    .implicit_table => {
                        try meta.key_kinds.put(ma, gop.key_ptr.*, .dotted_table);
                        tbl = gop.value_ptr.*.table;
                        const sm = self.getMeta(tbl);
                        if (sm.kind == .implicit) sm.kind = .dotted;
                        meta = self.getMeta(tbl);
                    },
                    .dotted_table => {
                        tbl = gop.value_ptr.*.table;
                        meta = self.getMeta(tbl);
                    },
                }
            }
        }

        const last = parts[parts.len - 1];
        if (meta.kind == .inline_t and !inline_ctx)
            return self.fail("cannot add keys to inline table after definition", .{});
        if (tbl.contains(last)) return self.fail("key '{s}' is already defined", .{last});

        // Ensure capacity first so the insertion below is infallible; this
        // prevents a partial-state slot that would corrupt deinitTable on OOM.
        try tbl.ensureUnusedCapacity(self.gpa, 1);
        const key_owned = try self.gpa.dupe(u8, last);
        var key_in_map = false;
        errdefer if (!key_in_map) self.gpa.free(key_owned);
        tbl.putAssumeCapacityNoClobber(key_owned, value);
        key_in_map = true; // table owns key_owned; deinitTable handles cleanup

        const kk: KeyKind = switch (value) {
            .table => |t| switch (self.getMeta(t).kind) {
                .inline_t => .inline_table,
                .implicit => .implicit_table,
                .dotted => .dotted_table,
                .header, .root => .header_table,
                .aot_array => .aot_array,
            },
            else => .value,
        };
        try meta.key_kinds.put(ma, key_owned, kk);
    }

    // ─── table header parsing ─────────────────────────────────────────────────

    fn parseTableHeader(self: *Parser) ParseError!void {
        try self.expect('[');
        self.skipInlineWs();
        var key_parts = try self.parseDottedKey();
        defer {
            for (key_parts.items) |p| self.gpa.free(p);
            key_parts.deinit(self.gpa);
        }
        self.skipInlineWs();
        try self.expect(']');
        self.skipInlineWs();
        if (!self.isEOL() and self.peek() != '#' and self.peek() != null)
            return self.fail("extra content after table header", .{});
        try self.skipToEOL();
        self.cur = try self.navigateToHeaderTable(self.root, key_parts.items);
    }

    fn parseAOTHeader(self: *Parser) ParseError!void {
        try self.expect('[');
        try self.expect('[');
        self.skipInlineWs();
        var key_parts = try self.parseDottedKey();
        defer {
            for (key_parts.items) |p| self.gpa.free(p);
            key_parts.deinit(self.gpa);
        }
        self.skipInlineWs();
        try self.expect(']');
        try self.expect(']');
        self.skipInlineWs();
        if (!self.isEOL() and self.peek() != '#' and self.peek() != null)
            return self.fail("extra content after array-of-tables header", .{});
        try self.skipToEOL();
        self.cur = try self.navigateToAOT(self.root, key_parts.items);
    }

    fn navigateToHeaderTable(self: *Parser, start_tbl: *Table, path: [][]u8) ParseError!*Table {
        std.debug.assert(path.len > 0);
        const ma = self.meta_arena.allocator();
        var tbl = start_tbl;
        var meta = self.getMeta(tbl);

        for (path[0 .. path.len - 1]) |part| {
            const gop = tbl.getOrPut(self.gpa, part) catch return error.OutOfMemory;
            if (!gop.found_existing) {
                gop.value_ptr.* = .{ .boolean = false };
                gop.key_ptr.* = &.{};
                const sub = try self.gpa.create(Table);
                sub.* = .empty;
                gop.value_ptr.* = .{ .table = sub };
                _ = try self.createMeta(sub, .implicit);
                const key_copy = try self.gpa.dupe(u8, part);
                gop.key_ptr.* = key_copy;
                try meta.key_kinds.put(ma, gop.key_ptr.*, .implicit_table);
                tbl = sub;
                meta = self.getMeta(tbl);
            } else {
                const kk = meta.key_kinds.get(gop.key_ptr.*) orelse .value;
                switch (kk) {
                    .value, .inline_table => return self.fail("cannot use '{s}' as a table — already a non-table value", .{part}),
                    .aot_array => {
                        const arr = gop.value_ptr.*.array;
                        tbl = arr.items[arr.items.len - 1].table;
                        meta = self.getMeta(tbl);
                    },
                    .implicit_table, .dotted_table, .header_table => {
                        tbl = gop.value_ptr.*.table;
                        meta = self.getMeta(tbl);
                    },
                }
            }
        }

        const last = path[path.len - 1];
        const gop = tbl.getOrPut(self.gpa, last) catch return error.OutOfMemory;
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .boolean = false };
            gop.key_ptr.* = &.{};
            const sub = try self.gpa.create(Table);
            sub.* = .empty;
            gop.value_ptr.* = .{ .table = sub };
            _ = try self.createMeta(sub, .header);
            const key_copy = try self.gpa.dupe(u8, last);
            gop.key_ptr.* = key_copy;
            try meta.key_kinds.put(ma, gop.key_ptr.*, .header_table);
            return sub;
        }
        const kk = meta.key_kinds.get(gop.key_ptr.*) orelse .value;
        switch (kk) {
            .implicit_table => {
                const sub = gop.value_ptr.*.table;
                self.getMeta(sub).kind = .header;
                try meta.key_kinds.put(ma, gop.key_ptr.*, .header_table);
                return sub;
            },
            .header_table => return self.fail("table [{s}] already defined", .{last}),
            .dotted_table => return self.fail("table [{s}] already defined via dotted keys", .{last}),
            .inline_table => return self.fail("cannot reopen inline table [{s}]", .{last}),
            .value => return self.fail("key '{s}' is a non-table value", .{last}),
            .aot_array => return self.fail("key '{s}' is an array of tables; use [[{s}]] syntax", .{ last, last }),
        }
    }

    fn navigateToAOT(self: *Parser, start_tbl: *Table, path: [][]u8) ParseError!*Table {
        std.debug.assert(path.len > 0);
        const ma = self.meta_arena.allocator();
        var tbl = start_tbl;
        var meta = self.getMeta(tbl);

        for (path[0 .. path.len - 1]) |part| {
            const gop = tbl.getOrPut(self.gpa, part) catch return error.OutOfMemory;
            if (!gop.found_existing) {
                gop.value_ptr.* = .{ .boolean = false };
                gop.key_ptr.* = &.{};
                const sub = try self.gpa.create(Table);
                sub.* = .empty;
                gop.value_ptr.* = .{ .table = sub };
                _ = try self.createMeta(sub, .implicit);
                const key_copy = try self.gpa.dupe(u8, part);
                gop.key_ptr.* = key_copy;
                try meta.key_kinds.put(ma, gop.key_ptr.*, .implicit_table);
                tbl = sub;
                meta = self.getMeta(tbl);
            } else {
                const kk = meta.key_kinds.get(gop.key_ptr.*) orelse .value;
                switch (kk) {
                    .value, .inline_table => return self.fail("cannot use '{s}' as a table", .{part}),
                    .aot_array => {
                        const arr = gop.value_ptr.*.array;
                        tbl = arr.items[arr.items.len - 1].table;
                        meta = self.getMeta(tbl);
                    },
                    .implicit_table, .dotted_table, .header_table => {
                        tbl = gop.value_ptr.*.table;
                        meta = self.getMeta(tbl);
                    },
                }
            }
        }

        const last = path[path.len - 1];
        const gop = tbl.getOrPut(self.gpa, last) catch return error.OutOfMemory;
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .boolean = false };
            gop.key_ptr.* = &.{};
            const arr = try self.gpa.create(Array);
            arr.* = .empty;
            gop.value_ptr.* = .{ .array = arr };
            const key_copy = try self.gpa.dupe(u8, last);
            gop.key_ptr.* = key_copy;
            try meta.key_kinds.put(ma, gop.key_ptr.*, .aot_array);
            return self.appendAOTElement(arr);
        }
        const kk = meta.key_kinds.get(gop.key_ptr.*) orelse .value;
        if (kk != .aot_array) return self.fail("key '{s}' is not an array of tables", .{last});
        return self.appendAOTElement(gop.value_ptr.*.array);
    }

    fn appendAOTElement(self: *Parser, arr: *Array) ParseError!*Table {
        const elem = try self.gpa.create(Table);
        elem.* = .empty;
        errdefer {
            elem.deinit(self.gpa);
            self.gpa.destroy(elem);
        }
        _ = try self.createMeta(elem, .header);
        arr.append(self.gpa, .{ .table = elem }) catch return error.OutOfMemory;
        return elem;
    }

    fn parseKeyVal(self: *Parser) ParseError!void {
        var key_parts = try self.parseDottedKey();
        defer {
            for (key_parts.items) |p| self.gpa.free(p);
            key_parts.deinit(self.gpa);
        }
        self.skipInlineWs();
        try self.expect('=');
        self.skipInlineWs();
        const val = try self.parseValue();
        errdefer val.deinit(self.gpa);
        try self.setNestedKey(self.cur, key_parts.items, val, false);
    }

    fn parseDocument(self: *Parser) ParseError!void {
        if (!std.unicode.utf8ValidateSlice(self.input))
            return self.fail("document is not valid UTF-8", .{});
        while (true) {
            try self.skipTrivia();
            const c = self.peek() orelse break;
            switch (c) {
                '[' => if (self.peekAt(1) == '[') try self.parseAOTHeader() else try self.parseTableHeader(),
                else => {
                    try self.parseKeyVal();
                    self.skipInlineWs();
                    const next = self.peek() orelse break;
                    switch (next) {
                        '\n', '\r' => try self.eatNewline(),
                        '#' => {
                            try self.skipComment();
                            try self.eatNewline();
                        },
                        else => return self.fail("expected newline after key/value pair, found '{c}'", .{self.peek().?}),
                    }
                },
            }
        }
    }
};

inline fn isDigit(c: ?u8) bool {
    return if (c) |ch| ch >= '0' and ch <= '9' else false;
}

inline fn isBaseDigit(c: u8, base: u8) bool {
    return switch (base) {
        16 => std.ascii.isHex(c),
        8 => c >= '0' and c <= '7',
        2 => c == '0' or c == '1',
        else => false,
    };
}

fn isLeapYear(year: u32) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

fn daysInMonth(year: u32, month: u32) u32 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

pub fn parseSlice(gpa: Allocator, input: []const u8, err_info: ?*ErrorInfo) ParseError!*Table {
    var parser = try Parser.init(gpa, input);
    defer parser.deinit();
    parser.parseDocument() catch |e| {
        if (err_info) |ei| ei.* = parser.err_info;
        types.deinitTable(parser.root, gpa);
        gpa.destroy(parser.root);
        return e;
    };
    return parser.root;
}
