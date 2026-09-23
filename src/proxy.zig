const std = @import("std");
const builtin = @import("builtin");

const SYSTEM_ID = "6b87ab66-af2c-49c7-b986-ef4c27c9e1fb";

// Global proxy config
var proxy_initialized: bool = false;
var proxy_mutex: std.Thread.Mutex = .{};
var proxy_host: ?[]const u8 = null;
var proxy_port: u16 = 0;

pub fn init(allocator: std.mem.Allocator) void {
    proxy_mutex.lock();
    defer proxy_mutex.unlock();
    if (proxy_initialized) return;
    defer proxy_initialized = true;

    const env_names = [_][]const u8{ "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy" };
    for (env_names) |name| {
        const val = std.process.getEnvVarOwned(allocator, name) catch continue;
        defer allocator.free(val);
        if (val.len == 0) continue;
        if (parseProxyUrl(allocator, val)) return;
    }

    if (comptime builtin.os.tag == .windows) {
        readWindowsSystemProxy(allocator);
    }
}

pub fn getHost() ?[]const u8 {
    proxy_mutex.lock();
    defer proxy_mutex.unlock();
    return proxy_host;
}

pub fn getPort() u16 {
    proxy_mutex.lock();
    defer proxy_mutex.unlock();
    return proxy_port;
}

fn parseProxyUrl(allocator: std.mem.Allocator, val: []const u8) bool {
    const uri = std.Uri.parse(val) catch return false;
    const raw_host = uri.host orelse return false;
    const host = switch (raw_host) {
        .raw => |h| h,
        .percent_encoded => |h| h,
    };
    proxy_host = allocator.dupe(u8, host) catch return false;
    proxy_port = uri.port orelse 7890;
    std.debug.print("[zed] using HTTPS proxy: {s}:{d}\n", .{ proxy_host.?, proxy_port });
    return true;
}

fn readWindowsSystemProxy(allocator: std.mem.Allocator) void {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "reg", "query", "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings", "/v", "ProxyEnable" },
        .max_output_bytes = 4096,
    }) catch return;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (std.mem.indexOf(u8, result.stdout, "0x1") == null) return;

    const result2 = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "reg", "query", "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings", "/v", "ProxyServer" },
        .max_output_bytes = 4096,
    }) catch return;
    defer allocator.free(result2.stdout);
    defer allocator.free(result2.stderr);

    if (std.mem.indexOf(u8, result2.stdout, "ProxyServer")) |idx| {
        const after = result2.stdout[idx..];
        if (std.mem.indexOf(u8, after, "REG_SZ")) |sz_idx| {
            var val_start = sz_idx + "REG_SZ".len;
            while (val_start < after.len and (after[val_start] == ' ' or after[val_start] == '\t')) val_start += 1;
            var val_end = val_start;
            while (val_end < after.len and after[val_end] != '\r' and after[val_end] != '\n') val_end += 1;
            const proxy_val = std.mem.trim(u8, after[val_start..val_end], " \t");
            if (proxy_val.len > 0) {
                if (std.mem.indexOf(u8, proxy_val, ":")) |colon| {
                    proxy_host = allocator.dupe(u8, proxy_val[0..colon]) catch return;
                    proxy_port = std.fmt.parseInt(u16, proxy_val[colon + 1 ..], 10) catch 7890;
                } else {
                    proxy_host = allocator.dupe(u8, proxy_val) catch return;
                    proxy_port = 7890;
                }
                std.debug.print("[zed] using system proxy: {s}:{d}\n", .{ proxy_host.?, proxy_port });
            }
        }
    }
}

/// A bounded HTTP request. curl is used for both direct and proxied requests so
/// neither path can wait indefinitely for a connection or response body.
pub fn request(allocator: std.mem.Allocator, url: []const u8, auth: []const u8, extra_header: ?[]const u8, body: ?[]const u8, max_seconds: []const u8) ![]u8 {
    init(allocator);
    const auth_header = try std.fmt.allocPrint(allocator, "authorization: {s}", .{auth});
    defer allocator.free(auth_header);

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    try args.appendSlice(allocator, &.{ "curl", "-sS", "--connect-timeout", "10", "--max-time", max_seconds, "-w", "\n__HTTP_STATUS__%{http_code}" });
    var proxy_url: ?[]u8 = null;
    defer if (proxy_url) |p| allocator.free(p);
    if (getHost()) |host| {
        proxy_url = try std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ host, getPort() });
        try args.appendSlice(allocator, &.{ "-x", proxy_url.?, "--noproxy", "" });
    } else {
        // Ignore curl's implicit environment proxy when our proxy discovery found none.
        try args.appendSlice(allocator, &.{ "--proxy", "" });
    }
    try args.appendSlice(allocator, &.{ "-H", auth_header });
    if (extra_header) |header| try args.appendSlice(allocator, &.{ "-H", header });

    var temp_path: ?[]u8 = null;
    defer if (temp_path) |p| {
        std.fs.cwd().deleteFile(p) catch {};
        allocator.free(p);
    };
    var at_path: ?[]u8 = null;
    defer if (at_path) |p| allocator.free(p);
    if (body) |payload| {
        try args.appendSlice(allocator, &.{ "-X", "POST", "-H", "content-type: application/json" });
        // A random exclusive name prevents simultaneous requests overwriting each other.
        var random_bytes: [16]u8 = undefined;
        while (true) {
            std.crypto.random.bytes(&random_bytes);
            const name = try std.fmt.allocPrint(allocator, "zed2api_req_{s}.json", .{std.fmt.bytesToHex(random_bytes, .lower)});
            const file = std.fs.cwd().createFile(name, .{ .exclusive = true }) catch |err| {
                allocator.free(name);
                if (err == error.PathAlreadyExists) continue;
                return error.UpstreamError;
            };
            temp_path = name;
            file.writeAll(payload) catch {
                file.close();
                return error.UpstreamError;
            };
            file.close();
            break;
        }
        at_path = try std.fmt.allocPrint(allocator, "@{s}", .{temp_path.?});
        try args.appendSlice(allocator, &.{ "--data-binary", at_path.? });
    }
    try args.append(allocator, url);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = args.items,
        .max_output_bytes = 4 * 1024 * 1024,
    }) catch return error.UpstreamError;
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);
    if (result.term != .Exited or result.term.Exited != 0) {
        std.debug.print("[zed] curl failed: {s}\n", .{result.stderr});
        return error.UpstreamError;
    }
    const marker = "\n__HTTP_STATUS__";
    const pos = std.mem.lastIndexOf(u8, result.stdout, marker) orelse return error.UpstreamError;
    const status = std.fmt.parseInt(u16, result.stdout[pos + marker.len ..], 10) catch return error.UpstreamError;
    const response_body = result.stdout[0..pos];
    if (status == 401 or status == 403) return error.TokenExpired;
    if (status == 429) return error.RateLimited;
    if (status != 200 or response_body.len == 0) {
        std.debug.print("[zed] upstream status {d}: {s}\n", .{ status, response_body[0..@min(response_body.len, 500)] });
        return error.UpstreamError;
    }
    return allocator.dupe(u8, response_body);
}

pub fn sendViaProxy(allocator: std.mem.Allocator, bearer: []const u8, body: []const u8) ![]const u8 {
    return request(allocator, "https://cloud.zed.dev/completions", bearer, "x-zed-version: 0.222.4+stable.147.b385025df963c9e8c3f74cc4dadb1c4b29b3c6f0", body, "120");
}

/// Send HTTP POST to Zed with retry logic
pub fn sendToZed(allocator: std.mem.Allocator, jwt: []const u8, body: []const u8) ![]const u8 {
    const bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{jwt});
    defer allocator.free(bearer);

    var attempt: u8 = 0;
    while (attempt < 3) : (attempt += 1) {
        const result = sendViaProxy(allocator, bearer, body);
        if (result) |data| {
            return data;
        } else |err| {
            std.debug.print("[zed] attempt {d} error: {}\n", .{ attempt + 1, err });
            if (err == error.TokenExpired) return err;
            if (err == error.RateLimited) {
                if (attempt < 2) std.Thread.sleep(3_000_000_000);
                continue;
            }
            if (attempt < 2) std.Thread.sleep(1_000_000_000 * (@as(u64, 1) << @intCast(attempt)));
        }
    }
    return error.UpstreamError;
}
