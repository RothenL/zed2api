const std = @import("std");
const auth = @import("auth"); // wired in build.zig to ../../src/auth.zig

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();
    const name_arg = args.next();

    std.debug.print(
        \\zed2api-auth — Windows authorization tool
        \\
        \\Opens a browser to sign in to Zed via GitHub OAuth, then writes
        \\accounts.json. Upload that file to your zed2api server's Web UI.
        \\
        \\
    , .{});

    const creds = try auth.login(allocator);
    defer allocator.free(creds.user_id);
    defer allocator.free(creds.access_token);

    std.debug.print("\n[ok] GitHub user_id: {s}\n", .{creds.user_id});

    const account_name = name_arg orelse creds.user_id;

    // The credential field is itself a JSON object; validate before writing so we
    // never emit a malformed file.
    {
        const probe = std.json.parseFromSlice(std.json.Value, allocator, creds.access_token, .{}) catch |err| {
            std.debug.print("[error] decoded access_token is not valid JSON: {}\n", .{err});
            return err;
        };
        probe.deinit();
    }

    try writeAccountsJson(allocator, account_name, creds.user_id, creds.access_token);
    std.debug.print(
        \\
        \\[ok] wrote accounts.json in the current directory.
        \\      Next: open your zed2api Web UI → Accounts → Upload accounts.json.
        \\
        \\
    , .{});
}

/// Append one account to accounts.json (creating or merging), mirroring the proven
/// string-based approach from src/accounts.zig so we don't depend on ObjectMap.put
/// allocator semantics that differ across Zig versions.
fn writeAccountsJson(allocator: std.mem.Allocator, name: []const u8, user_id: []const u8, credential_json: []const u8) !void {
    // Read existing content (up to 4 MiB).
    var buf: [4 * 1024 * 1024]u8 = undefined;
    var existing: ?[]const u8 = null;
    {
        const file = std.fs.cwd().openFile("accounts.json", .{}) catch null;
        if (file) |f| {
            defer f.close();
            const n = f.readAll(&buf) catch 0;
            if (n > 0) existing = buf[0..n];
        }
    }

    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);
    const w = output.writer(allocator);

    var merged = false;
    if (existing) |content| {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch null;
        if (parsed) |p| {
            defer p.deinit();
            if (p.value.object.get("accounts")) |accs| {
                try w.writeAll("{\n  \"accounts\": {\n");
                var it = accs.object.iterator();
                var first = true;
                while (it.next()) |entry| {
                    if (!first) try w.writeAll(",\n");
                    first = false;
                    try w.print("    \"{s}\": ", .{entry.key_ptr.*});
                    const val_str = try std.json.Stringify.valueAlloc(allocator, entry.value_ptr.*, .{});
                    defer allocator.free(val_str);
                    try w.writeAll(val_str);
                }
                if (!first) try w.writeAll(",\n");
                try w.print("    \"{s}\": {{\"user_id\":\"{s}\",\"credential\":{s}}}", .{ name, user_id, credential_json });
                try w.writeAll("\n  }\n}");
                merged = true;
            }
        }
    }

    if (!merged) {
        try w.print("{{\n  \"accounts\": {{\n    \"{s}\": {{\"user_id\":\"{s}\",\"credential\":{s}}}\n  }}\n}}", .{ name, user_id, credential_json });
    }

    const file = try std.fs.cwd().createFile("accounts.json", .{});
    defer file.close();
    try file.writeAll(output.items);
}
