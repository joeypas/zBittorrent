const std = @import("std");
const bencoding = @import("bencoding.zig");
const Value = bencoding.Value;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;

pub const FileInfo = struct {
    path: ArrayList(u8),
    length: usize,
};

pub const MetaInfo = struct {
    announce: ArrayList(u8),
    info: struct {
        name: ArrayList(u8),
        private: bool,
        piece_len: usize,
        files: ArrayList(FileInfo),
        pieces: ArrayList(u8),
    },

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("announce: {s}\n", .{self.announce.items});
        try writer.print("info: [\n", .{});
        try writer.print("  name: {s}\n", .{self.info.name.items});
        try writer.print("  private: {any}\n", .{self.info.private});
        try writer.print("  files_len: {d}\n", .{self.info.files.items.len});
        try writer.print("  piece_len: {d}\n]", .{self.info.piece_len});
    }

};

fn ensureDict(val: Value) !StringHashMap(Value) {
    return switch (val) {
        .dictionary => |dict| dict,
        else => error.NotDict,
    };
}

fn getKey(dict: StringHashMap(Value), key: []const u8, comptime tag: std.meta.Tag(Value)) !@FieldType(Value, @tagName(tag)) {
    if (dict.get(key)) |val| {
        return switch (val) {
            tag => |ret| ret,
            else => error.InvalidType,
        };
    }
    return error.MissingKey;
}

fn ensureStr(val: Value) !ArrayList(u8) {
    return switch (val) {
        .str => |str| str,
        else => error.NotString,
    };
}

fn joinPath(alloc: Allocator, list: ArrayList(Value)) !ArrayList(u8) {
    var path: ArrayList(u8) = .empty;

    for (list.items) |item| {
        const sub_path = try ensureStr(item);
        try path.appendSlice(alloc, sub_path.items);
        try path.append(alloc, '/');
    }
    _ = path.pop();
    return path;
}

fn parseFiles(alloc: Allocator, info: StringHashMap(Value)) !ArrayList(FileInfo) {

    var files: ArrayList(FileInfo) = .empty;
    if (info.getKey("length")) |_| {
        var fi = try files.addOne(alloc);
        fi.path = try joinPath(alloc, try getKey(info, "path", .list));
        fi.length = @intCast(try getKey(info, "length", .int));
    } else {
        const files_list: ArrayList(Value) = try getKey(info, "files", .list);
        for (files_list.items) |entry| {
            const file_info = try ensureDict(entry); 
            var fi = try files.addOne(alloc);
            fi.path = try joinPath(alloc,try getKey(file_info, "path", .list));
            fi.length = @intCast(try getKey(file_info, "length", .int));
        }
    }
    return files;
}

pub fn parseMetaInfo(alloc: Allocator, reader: *Reader) !MetaInfo {
    const meta_inf = try ensureDict(try bencoding.parseValue(alloc, reader));

    const url: ArrayList(u8) = try getKey(meta_inf, "announce", .str);

    const info: StringHashMap(Value) = try getKey(meta_inf, "info", .dictionary);

    const name: ArrayList(u8) = try getKey(info, "name", .str);
    const piece_len: usize = @intCast(try getKey(info, "piece length", .int));

    const _private: i64 = try getKey(info, "private", .int);
    const private = _private == 1;

    const pieces: ArrayList(u8) = try getKey(info, "pieces", .str);

    const files = try parseFiles(alloc, info);

    return .{
        .announce = url,
        .info = .{
            .name = name,
            .private = private,
            .pieces = pieces,
            .piece_len = piece_len,
            .files = files,
        }
    };
}

test "metainf" {
    const alloc = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    var file = try std.Io.Dir.openFile(std.Io.Dir.cwd(), std.testing.io, "test_folder-d984f67af9917b214cd8b6048ab5624c7df6a07a.torrent", .{ .mode = .read_only });

    var buf: [1024]u8 = undefined;

    var reader = file.reader(std.testing.io, &buf);
    // const str = "d8:announce3:yay4:infoi34ee";
    // var reader = std.Io.Reader.fixed(str);

    const t = try parseMetaInfo(arena.allocator(), &reader.interface);

    std.debug.print("{f}\n", .{t});

    arena.deinit();
}
