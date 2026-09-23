const std = @import("std");
const server = @import("server.zig");
const accounts = @import("accounts.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    const cmd = args.next() orelse "serve";

    if (std.mem.eql(u8, cmd, "serve")) {
        // PORT env var is a fallback when no positional port is supplied.
        const port_arg = args.next();
        const port = if (port_arg) |p|
            std.fmt.parseInt(u16, p, 10) catch defaultPort(allocator)
        else
            defaultPort(allocator);
        try server.run(allocator, port);
    } else if (std.mem.eql(u8, cmd, "import")) {
        const file_path = args.next() orelse "accounts.json";
        try importAccounts(allocator, file_path);
    } else if (std.mem.eql(u8, cmd, "accounts")) {
        try listAccounts(allocator);
    } else {
        printUsage();
    }
}

fn defaultPort(allocator: std.mem.Allocator) u16 {
    if (std.process.getEnvVarOwned(allocator, "PORT") catch null) |p| {
        defer allocator.free(p);
        return std.fmt.parseInt(u16, p, 10) catch 8000;
    }
    return 8000;
}

fn printUsage() void {
    std.debug.print(
        \\zed2api - Zed LLM API Proxy
        \\
        \\Usage:
        \\  zed2api serve [port]    Start API server (default: 8000)
        \\                          Set HOST=0.0.0.0 to listen on all interfaces (Docker)
        \\                          PORT env var is an alternative to [port]
        \\  zed2api import [path]   Import accounts.json from a file (default: accounts.json)
        \\  zed2api accounts        List configured accounts
        \\
        \\Authentication is configured by uploading accounts.json (produced by the
        \\desktop auth tool) through the Web UI — there is no in-process OAuth flow.
        \\Set the AUTH_TOKEN env var to gate all endpoints behind a shared token.
        \\
        \\Endpoints:
        \\  GET  /healthz                Liveness probe (always open)
        \\  POST /zed/auth/login         Exchange a token for an auth cookie
        \\  POST /v1/chat/completions    OpenAI compatible
        \\  POST /v1/messages            Anthropic native
        \\  GET  /v1/models              List models
        \\  GET  /zed/accounts           List accounts
        \\  POST /zed/accounts/upload    Upload accounts.json content
        \\  POST /zed/accounts/delete    Remove an account
        \\  GET  /                       Web UI
        \\
    , .{});
}

fn importAccounts(allocator: std.mem.Allocator, file_path: []const u8) !void {
    // Validate the file exists and is a parseable accounts.json, then copy it into place.
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        std.debug.print("[error] cannot open {s}: {}\n", .{ file_path, err });
        return err;
    };
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 4 * 1024 * 1024);
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch |err| {
        std.debug.print("[error] {s} is not valid JSON: {}\n", .{ file_path, err });
        return err;
    };
    defer parsed.deinit();
    if (parsed.value != .object or parsed.value.object.get("accounts") == null) {
        std.debug.print("[error] {s}: missing 'accounts' field\n", .{file_path});
        return error.InvalidAccountsJson;
    }

    const out = try std.fs.cwd().createFile("accounts.json", .{});
    defer out.close();
    try out.writeAll(content);
    std.debug.print("[ok] imported {s} -> accounts.json\n", .{file_path});
}

fn listAccounts(allocator: std.mem.Allocator) !void {
    var mgr = accounts.AccountManager.init(allocator);
    defer mgr.deinit();
    mgr.loadFromFile() catch {};

    if (mgr.list.items.len == 0) {
        std.debug.print("No accounts. Upload one via the Web UI, or use: zed2api import <accounts.json>\n", .{});
        return;
    }
    for (mgr.list.items) |acc| {
        std.debug.print("  {s} (uid: {s})\n", .{ acc.name, acc.user_id });
    }
}
