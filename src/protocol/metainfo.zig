const std = @import("std");
const bencoding = @import("bencoding.zig");
const Value = bencoding.Value;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

pub const FileInfo = struct {
    path: ArrayList(u8),
    length: usize,
};

/// All memory owned by the struct and freed on deinit
pub const MetaInfo = struct {
    arena: std.heap.ArenaAllocator,
    announce: ArrayList(u8),
    info: struct {
        name: ArrayList(u8),
        private: bool,
        piece_len: usize,
        files: ArrayList(FileInfo),
        pieces: []const [20]u8,
    },
    _val: bencoding.Value,

    pub fn parse(allocator: Allocator, reader: *Reader) !MetaInfo {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        const val = try bencoding.Value.parse(alloc, reader);
        const meta_inf = try ensureDict(val);

        const url: ArrayList(u8) = try getKey(meta_inf, "announce", .str);

        const info: StringHashMap(Value) = try getKey(meta_inf, "info", .dictionary);

        const name: ArrayList(u8) = try getKey(info, "name", .str);
        const piece_len: usize = @intCast(try getKey(info, "piece length", .int));

        const _private: i64 = try getKey(info, "private", .int);
        const private = _private == 1;

        const pieces: ArrayList(u8) = try getKey(info, "pieces", .str);
        if (pieces.items.len % 20 != 0) return error.InvalidPieces;

        const files = try parseFiles(alloc, info);

        return .{
            .arena = arena,
            .announce = url,
            .info = .{
                .name = name,
                .private = private,
                .pieces = try parsePieceHashes(pieces.items),
                .piece_len = piece_len,
                .files = files,
            },
            ._val = val,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
    }

    pub fn bencode(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try self._val.format(writer);
    }

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

fn validatePathComponent(component: []const u8) !void {
    if (component.len == 0)
        return error.InvalidPath;

    if (std.mem.eql(u8, component, ".") or
        std.mem.eql(u8, component, ".."))
        return error.InvalidPath;

    for (component) |c| {
        if (c == 0 or c == '/' or c == '\\' or c == ':')
            return error.InvalidPath;
    }
}

fn joinPath(alloc: Allocator, list: ArrayList(Value)) !ArrayList(u8) {
    var path: ArrayList(u8) = .empty;
    errdefer path.deinit(alloc);

    for (list.items, 0..) |item, i| {
        const sub_path = try ensureStr(item);
        try validatePathComponent(sub_path.items);

        if (i != 0) try path.append(alloc, std.fs.path.sep);
        try path.appendSlice(alloc, sub_path.items);
    }
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
            fi.path = try joinPath(alloc, try getKey(file_info, "path", .list));
            fi.length = @intCast(try getKey(file_info, "length", .int));
        }
    }
    return files;
}

fn parsePieceHashes(pieces: []const u8) ![]const [20]u8 {
    if (pieces.len % 20 != 0) return error.InvalidPieces;

    return std.mem.bytesAsSlice([20]u8, pieces);
}

test "metainf" {
    const alloc = std.testing.allocator;
    var file = try std.Io.Dir.openFile(std.Io.Dir.cwd(), std.testing.io, "test_folder-d984f67af9917b214cd8b6048ab5624c7df6a07a.torrent", .{ .mode = .read_only });

    var buf: [1024]u8 = undefined;

    var reader = file.reader(std.testing.io, &buf);
    // const str = "d8:announce3:yay4:infoi34ee";
    // var reader = std.Io.Reader.fixed(str);

    var t = try MetaInfo.parse(alloc, &reader.interface);
    defer t.deinit();
}
