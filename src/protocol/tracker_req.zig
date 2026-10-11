const std = @import("std");
const MetaInfo = @import("metainfo.zig").MetaInfo;
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Request = struct {
    info_hash: [20]u8 = undefined,
    peer_id: [20]u8 = undefined,
    port: u16,
    uploaded: usize = 0,
    downloaded: usize = 0,
    left: usize = 0,
    event: ?enum {
        started,
        completed,
        stopped,
    } = null,
    compact: bool = true,
    announce_url: []const u8,

    fn generatePeerId(io: Io) [20]u8 {
        var peer_id: [20]u8 = undefined;
        @memcpy(peer_id[0..8], "-ZT0001-");

        Io.random(io, peer_id[8..]);

        return peer_id;
    }

    pub fn fromMetaInfo(io: Io, inf: MetaInfo) !Request {
        var ret: Request = .{
            .port = 6881,
            .peer_id = generatePeerId(io),
            .announce_url = inf.announce.items,
        };

        var buf: [20]u8 = undefined;

        const sha = std.crypto.hash.Sha1.init(.{});
        var hw: Io.Writer.Hashing(std.crypto.hash.Sha1) = .initHasher(
            sha,
            &buf,
        );

        const w = &hw.writer;

        try inf.bencode(w);

        hw.hasher.final(&ret.info_hash);

        return ret;
    }

    pub fn toUrl(self: Request, writer: *Io.Writer) !void {
        const separator: u8 = if (std.mem.indexOfScalar(
            u8,
            self.announce_url,
            '?',
        ) != null) '&' else '?';

        try writer.print("{s}{c}info_hash={f}", .{
            self.announce_url,
            separator,
            std.fmt.alt(
                std.Uri.Component{ .raw = &self.info_hash },
                .formatEscaped,
            ),
        });

        try writer.print("&peer_id={f}", .{
            std.fmt.alt(
                std.Uri.Component{ .raw = &self.info_hash },
                .formatEscaped,
            ),
        });

        try writer.print("&peer_id={f}", .{
            std.fmt.alt(
                std.Uri.Component{ .raw = &self.info_hash },
                .formatEscaped,
            ),
        });

        try writer.print(
            "&port={d}&uploaded={d}&downloaded={d}&left={d}&compact={d}",
            .{
                self.port,
                self.uploaded,
                self.downloaded,
                self.left,
                @intFromBool(self.compact),
            },
        );

        if (self.event) |ev| {
            try writer.print("&event={s}", .{switch (ev) {
                .started => "started",
                .completed => "completed",
                .stopped => "stopped",
            }});
        }
    }
};

test "get req" {
    const allocator = std.testing.allocator;

    var file = try std.Io.Dir.openFile(std.Io.Dir.cwd(), std.testing.io, "test_folder-d984f67af9917b214cd8b6048ab5624c7df6a07a.torrent", .{ .mode = .read_only });

    var buf: [1024]u8 = undefined;

    var reader = file.reader(std.testing.io, &buf);

    var t = try MetaInfo.parse(allocator, &reader.interface);
    defer t.deinit();

    const req = try Request.fromMetaInfo(std.testing.io, t);

    std.debug.print("{f}\n", .{std.fmt.alt(
        req,
        .toUrl,
    )});
}
