const std = @import("std");
const builtin = @import("builtin");

pub fn recv(stream: std.net.Stream, buf: []u8) !usize {
    if (comptime builtin.os.tag == .windows) {
        const ws2 = std.os.windows.ws2_32;
        const rc = ws2.recv(stream.handle, buf.ptr, @intCast(buf.len), 0);
        if (rc == ws2.SOCKET_ERROR) {
            const err = ws2.WSAGetLastError();
            return switch (err) {
                ws2.WinsockError.WSAECONNRESET => error.ConnectionResetByPeer,
                ws2.WinsockError.WSAECONNABORTED => error.BrokenPipe,
                else => error.Unexpected,
            };
        }
        if (rc == 0) return 0;
        return @intCast(rc);
    } else {
        return stream.read(buf);
    }
}

pub fn send(stream: std.net.Stream, data: []const u8) !void {
    if (comptime builtin.os.tag == .windows) {
        const ws2 = std.os.windows.ws2_32;
        var sent: usize = 0;
        while (sent < data.len) {
            const rc = ws2.send(stream.handle, data[sent..].ptr, @intCast(data.len - sent), 0);
            if (rc == ws2.SOCKET_ERROR) {
                const err = ws2.WSAGetLastError();
                return switch (err) {
                    ws2.WinsockError.WSAECONNRESET => error.ConnectionResetByPeer,
                    ws2.WinsockError.WSAECONNABORTED => error.BrokenPipe,
                    else => error.Unexpected,
                };
            }
            sent += @intCast(rc);
        }
    } else {
        _ = try stream.write(data);
    }
}

pub fn writeResponse(stream: std.net.Stream, status: u16, body: []const u8) void {
    writeResponseWithType(stream, status, body, "application/json");
}

pub fn writeResponseWithType(stream: std.net.Stream, status: u16, body: []const u8, content_type: []const u8) void {
    writeResponseFull(stream, status, &.{}, body, content_type);
}

/// Write a response, optionally inserting extra header lines (e.g. `Set-Cookie`)
/// before the terminating blank line. `extra_headers` entries should already be
/// full `Name: value` lines without the trailing CRLF.
pub fn writeResponseFull(stream: std.net.Stream, status: u16, extra_headers: []const []const u8, body: []const u8, content_type: []const u8) void {
    const status_text = switch (status) {
        200 => "OK", 400 => "Bad Request", 401 => "Unauthorized", 404 => "Not Found",
        500 => "Internal Server Error", 502 => "Bad Gateway", else => "Unknown",
    };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.heap.page_allocator);
    const w = buf.writer(std.heap.page_allocator);

    w.print("HTTP/1.1 {d} {s}\r\n", .{ status, status_text }) catch return;
    w.print("Content-Type: {s}\r\n", .{content_type}) catch return;
    w.print("Content-Length: {d}\r\n", .{body.len}) catch return;
    w.writeAll("Access-Control-Allow-Origin: *\r\n") catch return;
    w.writeAll("Access-Control-Allow-Headers: *\r\n") catch return;
    w.writeAll("Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n") catch return;
    for (extra_headers) |line| {
        w.writeAll(line) catch return;
        w.writeAll("\r\n") catch return;
    }
    w.writeAll("Connection: close\r\n\r\n") catch return;
    w.writeAll(body) catch return;

    send(stream, buf.items) catch {};
}
