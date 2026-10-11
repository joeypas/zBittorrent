const std = @import("std");
const Reader = std.Io.Reader;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;

pub const Value = union(enum) {
    str: ArrayList(u8),
    int: i64,
    list: ArrayList(Value),
    dictionary: StringHashMap(Value),

    pub const Error = Allocator.Error || error{ InvalidDelim, InvalidKey, InvalidValue, ReadFailed, EndOfStream, KeyExists };

    pub fn parse(alloc: Allocator, reader: *Reader) Error!Value {
        const prefix = try reader.peekByte();
        return switch (prefix) {
            'i' => parseInt(reader),
            'l' => parseList(alloc, reader),
            'd' => parseDictionary(alloc, reader),
            else => parseString(alloc, reader),
        };
    }

    pub fn deinit(self: *@This(), alloc: Allocator) void {
        switch (self.*) {
            .str => |*str| str.deinit(alloc),
            .int => return,
            .list => |*list| {
                for (list.items) |*value| {
                    value.deinit(alloc);
                }
                list.deinit(alloc);
            },
            .dictionary => |*dict| {
                var it = dict.iterator();
                while (it.next()) |entry| {
                    alloc.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(alloc);
                }
                dict.deinit();
            },
        }
    }

    fn expectDelim(delim: u8, reader: *Reader) Error!void {
        const byte = try reader.takeByte();
        if (byte != delim) return Error.InvalidDelim;
    }

    pub fn parseInt(reader: *Reader) Error!Value {
        try expectDelim('i', reader);
        const digs = reader.takeDelimiterExclusive('e') catch return Error.InvalidDelim;
        const ret = std.fmt.parseInt(i64, digs, 10) catch return Error.InvalidValue;
        try expectDelim('e', reader);
        return .{ .int = ret };
    }

    fn parseStrRaw(alloc: Allocator, reader: *Reader) Error![]const u8 {
        const len_str = reader.takeDelimiterExclusive(':') catch return Error.InvalidDelim;
        const len = std.fmt.parseInt(usize, len_str, 10) catch return Error.InvalidValue;
        try expectDelim(':', reader);
        const ret = try reader.readAllocAll(alloc, len);

        return ret;
    }

    pub fn parseString(alloc: Allocator, reader: *Reader) Error!Value {
        const len_str = reader.takeDelimiterExclusive(':') catch return Error.InvalidDelim;
        const len = std.fmt.parseInt(usize, len_str, 10) catch return Error.InvalidValue;
        try expectDelim(':', reader);
        var ret: ArrayList(u8) = .empty;
        try reader.appendExact(alloc, &ret, len);

        return .{ .str = ret };
    }

    pub fn parseList(alloc: Allocator, reader: *Reader) Error!Value {
        try expectDelim('l', reader);
        var ret: ArrayList(Value) = .empty;

        var delim: u8 = try reader.peekByte();

        while (delim != 'e') {
            const v = parse(alloc, reader) catch return Error.InvalidValue;
            try ret.append(alloc, v);
            delim = try reader.peekByte();
        }

        try expectDelim('e', reader);
        return .{ .list = ret };
    }

    pub fn parseDictionary(alloc: Allocator, reader: *Reader) Error!Value {
        try expectDelim('d', reader);
        var ret: StringHashMap(Value) = StringHashMap(Value).init(alloc);

        var delim: u8 = try reader.peekByte();

        while (delim != 'e') {
            const key = parseStrRaw(alloc, reader) catch return Error.InvalidKey;
            const value = parse(alloc, reader) catch return Error.InvalidValue;
            const res = try ret.getOrPut(key);
            if (res.found_existing) return Error.KeyExists;
            res.value_ptr.* = value;
            delim = try reader.peekByte();
        }

        try expectDelim('e', reader);
        return .{ .dictionary = ret };
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .str => |str| try writer.print("{d}:{s}", .{ str.items.len, str.items }),
            .int => |int| try writer.print("i{d}e", .{int}),
            .list => |list| {
                try writer.print("l", .{});
                for (list.items) |item| {
                    try writer.print("{f}", .{item});
                }
                try writer.print("e", .{});
            },
            .dictionary => |*dict| {
                var it = dict.iterator();
                try writer.print("d", .{});
                while (it.next()) |value| {
                    try writer.print("{d}:{s}{f}", .{ value.key_ptr.len, value.key_ptr.*, value.value_ptr.* });
                }
                try writer.print("e", .{});
            },
        }
    }
};

test "parse" {
    const alloc = std.testing.allocator;
    const str = "d7:meaningi42e4:wikil7:bencodei-20eee";
    var reader = std.Io.Reader.fixed(str);

    var val = try Value.parse(alloc, &reader);
    defer val.deinit(alloc);

    var it = val.dictionary.iterator();

    const first = it.next().?;
    try std.testing.expectEqualStrings(first.key_ptr.*, "meaning");
    try std.testing.expectEqual(first.value_ptr.*.int, 42);
    const second = it.next().?;
    try std.testing.expectEqualStrings(second.key_ptr.*, "wiki");
    const list = second.value_ptr.*.list.items;
    try std.testing.expectEqualStrings(list[0].str.items, "bencode");
    try std.testing.expectEqual(list[1].int, -20);

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    var w = &aw.writer;

    try w.print("{f}", .{val});

    try std.testing.expectEqualStrings(str, aw.written());
}
