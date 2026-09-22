const std = @import("std");
const accounts = @import("accounts.zig");
const zed = @import("zed.zig");
const proxy = @import("proxy.zig");
const providers = @import("providers.zig");
const stream = @import("stream.zig");
const socket = @import("socket.zig");
const web_ui = @embedFile("web_index_html");

var account_mgr: accounts.AccountManager = undefined;
var global_allocator: std.mem.Allocator = undefined;

// Dynamic models cache
var cached_models_openai: ?[]const u8 = null;
var cached_models_time: i64 = 0;
const MODELS_CACHE_TTL: i64 = 3600; // 1 hour

pub fn run(allocator: std.mem.Allocator, port: u16) !void {
    global_allocator = allocator;
    account_mgr = accounts.AccountManager.init(allocator);
    defer account_mgr.deinit();
    account_mgr.loadFromFile() catch {};

    std.debug.print("[zed2api] http://127.0.0.1:{d}\n[zed2api] {d} account(s) loaded\n", .{ port, account_mgr.list.items.len });

    proxy.init(allocator);
    if (proxy.getHost()) |host| {
        std.debug.print("[zed2api] proxy: {s}:{d}\n", .{ host, proxy.getPort() });
    } else {
        std.debug.print("[zed2api] proxy: none (set HTTPS_PROXY to use)\n", .{});
    }

    const addr = blk: {
        // Allow binding to a specific interface via the HOST env var.
        // Defaults to 127.0.0.1 for safety; set HOST=0.0.0.0 to listen on all
        // interfaces (required for Docker, where the container's traffic arrives
        // on a non-loopback interface).
        const host_env = std.process.getEnvVarOwned(allocator, "HOST") catch null;
        defer if (host_env) |h| allocator.free(h);
        if (host_env) |h| {
            if (std.mem.eql(u8, h, "0.0.0.0")) break :blk std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
            break :blk std.net.Address.parseIp(h, port) catch std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
        }
        break :blk std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    };
    var tcp_server = try addr.listen(.{ .reuse_address = true });
    defer tcp_server.deinit();

    while (true) {
        const conn = tcp_server.accept() catch continue;
        const thread = std.Thread.spawn(.{}, handleConnection, .{conn.stream}) catch {
            conn.stream.close();
            continue;
        };
        thread.detach();
    }
}

fn handleConnection(conn_stream: std.net.Stream) void {
    defer conn_stream.close();

    var hdr_buf: [8192]u8 = undefined;
    var hdr_total: usize = 0;

    while (hdr_total < hdr_buf.len) {
        const n = socket.recv(conn_stream, hdr_buf[hdr_total..]) catch return;
        if (n == 0) return;
        hdr_total += n;
        if (std.mem.indexOf(u8, hdr_buf[0..hdr_total], "\r\n\r\n") != null) break;
    }

    const header_end = std.mem.indexOf(u8, hdr_buf[0..hdr_total], "\r\n\r\n") orelse return;
    const headers = hdr_buf[0..header_end];
    const body_in_hdr = hdr_buf[header_end + 4 .. hdr_total];

    const first_line_end = std.mem.indexOf(u8, headers, "\r\n") orelse return;
    const first_line = headers[0..first_line_end];
    var parts = std.mem.splitScalar(u8, first_line, ' ');
    const method = parts.next() orelse return;
    const full_path = parts.next() orelse return;
    const path = if (std.mem.indexOf(u8, full_path, "?")) |i| full_path[0..i] else full_path;

    var content_length: usize = 0;
    var header_lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (header_lines.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const val = std.mem.trim(u8, line["content-length:".len..], " ");
            content_length = std.fmt.parseInt(usize, val, 10) catch 0;
        }
    }

    // Read body (up to 16MB)
    const max_body = 16 * 1024 * 1024;
    const actual_len = @min(content_length, max_body);
    var body: []const u8 = "";
    var body_alloc: ?[]u8 = null;
    defer if (body_alloc) |b| global_allocator.free(b);

    if (actual_len > 0) {
        const body_buf = global_allocator.alloc(u8, actual_len) catch {
            socket.writeResponse(conn_stream, 500, "{\"error\":\"body too large\"}");
            return;
        };
        body_alloc = body_buf;
        const already = @min(body_in_hdr.len, actual_len);
        @memcpy(body_buf[0..already], body_in_hdr[0..already]);
        var filled: usize = already;
        while (filled < actual_len) {
            const n = socket.recv(conn_stream, body_buf[filled..actual_len]) catch break;
            if (n == 0) break;
            filled += n;
        }
        body = body_buf[0..filled];
    }

    // Streaming proxy check
    const is_messages = std.mem.eql(u8, path, "/v1/messages") and std.mem.eql(u8, method, "POST");
    const is_completions = std.mem.eql(u8, path, "/v1/chat/completions") and std.mem.eql(u8, method, "POST");
    const wants_stream = (is_messages or is_completions) and
        (std.mem.indexOf(u8, body, "\"stream\":true") != null or
        std.mem.indexOf(u8, body, "\"stream\": true") != null);

    if (wants_stream) {
        const req_model = providers.extractModelFromBody(global_allocator, body) catch "unknown";
        const has_thinking = std.mem.indexOf(u8, body, "\"thinking\"") != null;
        std.debug.print("[req] {s} {s} model={s} thinking={} body={d}bytes (stream)\n", .{ method, path, req_model, has_thinking, body.len });
        stream.handleStreamProxy(conn_stream, body, is_messages, &account_mgr, global_allocator);
        return;
    }

    // Non-streaming route
    const response = route(method, path, body) catch |err| {
        std.debug.print("[zed2api] route error: {} for {s} {s}\n", .{ err, method, path });
        socket.writeResponse(conn_stream, 500, "{\"error\":\"internal error\"}");
        return;
    };
    defer if (response.allocated) global_allocator.free(response.body);
    socket.writeResponseWithType(conn_stream, response.status, response.body, response.content_type);
}

const Response = struct {
    status: u16,
    body: []const u8,
    content_type: []const u8 = "application/json",
    allocated: bool = false,
};

fn route(method: []const u8, path: []const u8, body: []const u8) !Response {
    std.debug.print("[req] {s} {s} body={d}bytes\n", .{ method, path, body.len });

    if (std.mem.eql(u8, path, "/")) return .{ .status = 200, .body = web_ui, .content_type = "text/html; charset=utf-8" };
    if (std.mem.eql(u8, path, "/v1/models") and std.mem.eql(u8, method, "GET"))
        return try handleModels();
    if (std.mem.eql(u8, path, "/api/event_logging/batch"))
        return .{ .status = 200, .body = "{\"status\":\"ok\"}" };
    if (std.mem.startsWith(u8, path, "/v1/messages/count_tokens"))
        return .{ .status = 200, .body = "{\"input_tokens\":0}" };
    if (std.mem.eql(u8, path, "/zed/accounts") and std.mem.eql(u8, method, "GET"))
        return try handleListAccounts();
    if (std.mem.eql(u8, path, "/zed/accounts/switch") and std.mem.eql(u8, method, "POST"))
        return handleSwitchAccount(body);
    if (std.mem.eql(u8, path, "/zed/usage") and std.mem.eql(u8, method, "GET"))
        return try handleUsage();
    if (std.mem.eql(u8, path, "/zed/billing") and std.mem.eql(u8, method, "GET"))
        return try handleBilling();
    if (std.mem.eql(u8, path, "/v1/chat/completions") and std.mem.eql(u8, method, "POST"))
        return try handleProxy(body, false);
    if (std.mem.eql(u8, path, "/v1/messages") and std.mem.eql(u8, method, "POST"))
        return try handleProxy(body, true);
    if (std.mem.eql(u8, path, "/zed/accounts/upload") and std.mem.eql(u8, method, "POST"))
        return try handleUploadAccounts(body);
    if (std.mem.eql(u8, path, "/zed/accounts/delete") and std.mem.eql(u8, method, "POST"))
        return handleDeleteAccount(body);
    if (std.mem.eql(u8, method, "OPTIONS"))
        return .{ .status = 200, .body = "" };
    return .{ .status = 404, .body = "{\"error\":\"not found\"}" };
}

// ── Non-streaming proxy with failover ──

fn handleProxy(body: []const u8, is_anthropic: bool) !Response {
    if (account_mgr.list.items.len == 0) return .{ .status = 400, .body = "{\"error\":\"no account configured\"}" };

    const total = account_mgr.list.items.len;
    var try_order: [64]usize = undefined;
    const count = @min(total, 64);
    try_order[0] = account_mgr.current;
    var order_idx: usize = 1;
    for (0..total) |i| {
        if (i != account_mgr.current and order_idx < count) {
            try_order[order_idx] = i;
            order_idx += 1;
        }
    }

    var last_err: anyerror = error.UpstreamError;
    for (try_order[0..count]) |acc_idx| {
        const acc = &account_mgr.list.items[acc_idx];
        const result = if (is_anthropic)
            zed.proxyMessages(global_allocator, acc, body)
        else
            zed.proxyChatCompletions(global_allocator, acc, body);

        if (result) |data| {
            if (acc_idx != account_mgr.current) {
                std.debug.print("[zed2api] failover success: switched to '{s}'\n", .{acc.name});
                account_mgr.current = acc_idx;
            }
            return .{ .status = 200, .body = data, .allocated = true };
        } else |err| {
            last_err = err;
            std.debug.print("[zed2api] account '{s}' failed: {}\n", .{ acc.name, err });
            const should_failover = (err == error.TokenRefreshFailed or err == error.TokenExpired or err == error.UpstreamError);
            if (!should_failover) break;
        }
    }

    const status: u16 = switch (last_err) {
        error.TokenRefreshFailed => 401,
        error.TokenExpired => 401,
        error.UpstreamError => 502,
        else => 500,
    };
    const msg = switch (last_err) {
        error.TokenRefreshFailed => "{\"error\":{\"message\":\"All accounts failed: token refresh failed\",\"type\":\"auth_error\"}}",
        error.TokenExpired => "{\"error\":{\"message\":\"All accounts failed: token expired\",\"type\":\"auth_error\"}}",
        error.UpstreamError => "{\"error\":{\"message\":\"All accounts failed: upstream error\",\"type\":\"upstream_error\"}}",
        else => "{\"error\":{\"message\":\"All accounts failed: internal error\",\"type\":\"server_error\"}}",
    };
    return .{ .status = status, .body = msg };
}

// ── Account handlers ──

fn handleListAccounts() !Response {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(global_allocator);
    try w.writeAll("{\"accounts\":[");
    for (account_mgr.list.items, 0..) |acc, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"name\":\"{s}\",\"user_id\":\"{s}\",\"current\":{s}}}", .{
            acc.name, acc.user_id,
            if (i == account_mgr.current) "true" else "false",
        });
    }
    try w.print("],\"current\":\"{s}\"}}", .{
        if (account_mgr.getCurrent()) |c| c.name else "",
    });
    return .{ .status = 200, .body = try buf.toOwnedSlice(global_allocator), .allocated = true };
}

fn handleSwitchAccount(body: []const u8) Response {
    const parsed = std.json.parseFromSlice(std.json.Value, global_allocator, body, .{}) catch
        return .{ .status = 400, .body = "{\"error\":\"invalid json\"}" };
    defer parsed.deinit();
    const name = switch (parsed.value.object.get("account") orelse return .{ .status = 400, .body = "{\"error\":\"missing account\"}" }) {
        .string => |s| s,
        else => return .{ .status = 400, .body = "{\"error\":\"bad type\"}" },
    };
    if (account_mgr.switchTo(name))
        return .{ .status = 200, .body = "{\"success\":true}" }
    else
        return .{ .status = 404, .body = "{\"error\":\"not found\"}" };
}

fn handleUsage() !Response {
    const acc = account_mgr.getCurrent() orelse return .{ .status = 400, .body = "{\"error\":\"no account\"}" };
    const jwt = try zed.getToken(global_allocator, acc);
    const claims = try zed.parseJwtClaims(global_allocator, jwt);
    return .{ .status = 200, .body = claims, .allocated = true };
}

fn handleBilling() !Response {
    const acc = account_mgr.getCurrent() orelse return .{ .status = 400, .body = "{\"error\":\"no account\"}" };
    const user_info = zed.fetchBillingUsage(global_allocator, acc) catch {
        return .{ .status = 502, .body = "{\"error\":\"failed to fetch user info\"}" };
    };
    return .{ .status = 200, .body = user_info, .allocated = true };
}

fn handleModels() !Response {
    const now = std.time.timestamp();
    if (cached_models_openai) |cached| {
        if (now - cached_models_time < MODELS_CACHE_TTL) {
            return .{ .status = 200, .body = cached };
        }
    }

    // Fetch from Zed
    const acc = account_mgr.getCurrent() orelse {
        // Fallback to static
        return .{ .status = 200, .body = @embedFile("models.json") };
    };

    const raw = zed.fetchModels(global_allocator, acc) catch {
        // Fallback to cache or static
        if (cached_models_openai) |cached| return .{ .status = 200, .body = cached };
        return .{ .status = 200, .body = @embedFile("models.json") };
    };
    defer global_allocator.free(raw);

    // Convert Zed format to OpenAI format
    const openai = convertZedModelsToOpenAI(global_allocator, raw) catch {
        if (cached_models_openai) |cached| return .{ .status = 200, .body = cached };
        return .{ .status = 200, .body = @embedFile("models.json") };
    };

    // Update cache
    if (cached_models_openai) |old| global_allocator.free(old);
    cached_models_openai = openai;
    cached_models_time = now;

    std.debug.print("[zed2api] models refreshed ({d} bytes)\n", .{openai.len});
    return .{ .status = 200, .body = openai };
}

fn convertZedModelsToOpenAI(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    const models = switch (parsed.value.object.get("models") orelse return error.InvalidFormat) {
        .array => |a| a,
        else => return error.InvalidFormat,
    };

    var buf: std.io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();
    const w = &buf.writer;

    try w.writeAll("{\"object\":\"list\",\"data\":[");
    var first = true;
    for (models.items) |model| {
        if (model != .object) continue;
        const id = switch (model.object.get("id") orelse continue) { .string => |s| s, else => continue };
        const provider = switch (model.object.get("provider") orelse continue) { .string => |s| s, else => continue };

        if (!first) try w.writeAll(",");
        first = false;
        try w.print("{{\"id\":\"{s}\",\"object\":\"model\",\"owned_by\":\"{s}\"}}", .{ id, provider });
    }
    try w.writeAll("]}");
    return try buf.toOwnedSlice();
}

// ── Upload accounts.json (generated by the desktop auth tool) ──

fn handleUploadAccounts(body: []const u8) !Response {
    if (body.len == 0) return .{ .status = 400, .body = "{\"error\":\"empty body\"}" };

    // The UI sends either a wrapper { "accounts_json": "<raw json string>" } or the
    // raw accounts.json content directly. Both must contain an "accounts" object.
    // multipart/form-data is intentionally unsupported to keep parsing dependency-free.
    var raw_accounts_json: []const u8 = "";
    {
        const wrapper = std.json.parseFromSlice(std.json.Value, global_allocator, body, .{}) catch null;
        if (wrapper) |w| {
            defer w.deinit();
            if (w.value == .object) {
                if (w.value.object.get("accounts_json")) |v| {
                    if (v == .string and v.string.len > 0) raw_accounts_json = v.string;
                }
            }
        }
    }
    if (raw_accounts_json.len == 0) {
        // Fall back to treating the body itself as the accounts document.
        const probe = std.json.parseFromSlice(std.json.Value, global_allocator, body, .{}) catch
            return .{ .status = 400, .body = "{\"error\":\"invalid accounts.json\"}" };
        defer probe.deinit();
        if (probe.value != .object or probe.value.object.get("accounts") == null)
            return .{ .status = 400, .body = "{\"error\":\"missing 'accounts' field\"}" };
        raw_accounts_json = body;
    }

    // Parse once; validate shape; collect names.
    const parsed = std.json.parseFromSlice(std.json.Value, global_allocator, raw_accounts_json, .{}) catch
        return .{ .status = 400, .body = "{\"error\":\"parse error\"}" };
    defer parsed.deinit();
    const accs_val = parsed.value.object.get("accounts") orelse
        return .{ .status = 400, .body = "{\"error\":\"missing 'accounts' field\"}" };
    if (accs_val != .object or accs_val.object.count() == 0)
        return .{ .status = 400, .body = "{\"error\":\"accounts object is empty\"}" };

    // Serialize normalized and write to disk.
    const accs_str = try std.json.Stringify.valueAlloc(global_allocator, accs_val, .{});
    defer global_allocator.free(accs_str);
    {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(global_allocator);
        const w = out.writer(global_allocator);
        try w.writeAll("{\n  \"accounts\": ");
        try w.writeAll(accs_str);
        try w.writeAll("\n}\n");

        const file = std.fs.cwd().createFile("accounts.json", .{}) catch
            return .{ .status = 500, .body = "{\"error\":\"cannot write accounts.json\"}" };
        defer file.close();
        try file.writeAll(out.items);
    }

    // Reload account manager so the new accounts are live immediately.
    account_mgr.deinit();
    account_mgr = accounts.AccountManager.init(global_allocator);
    account_mgr.loadFromFile() catch {};

    // Echo the names back to the UI.
    var resp: std.ArrayListUnmanaged(u8) = .empty;
    const w = resp.writer(global_allocator);
    try w.writeAll("{\"success\":true,\"count\":");
    try w.print("{d}", .{accs_val.object.count()});
    try w.writeAll(",\"accounts\":[");
    var it = accs_val.object.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (!first) try w.writeAll(",");
        first = false;
        try w.print("\"{s}\"", .{entry.key_ptr.*});
    }
    try w.writeAll("]}");

    std.debug.print("[upload] accounts.json replaced ({d} account(s))\n", .{accs_val.object.count()});
    return .{ .status = 200, .body = try resp.toOwnedSlice(global_allocator), .allocated = true };
}

fn handleDeleteAccount(body: []const u8) Response {
    const parsed = std.json.parseFromSlice(std.json.Value, global_allocator, body, .{}) catch
        return .{ .status = 400, .body = "{\"error\":\"invalid json\"}" };
    defer parsed.deinit();
    const name = switch (parsed.value.object.get("account") orelse return .{ .status = 400, .body = "{\"error\":\"missing account\"}" }) {
        .string => |s| s,
        else => return .{ .status = 400, .body = "{\"error\":\"bad type\"}" },
    };

    // Read accounts.json, drop the named account, rewrite.
    const buf = global_allocator.alloc(u8, 4 * 1024 * 1024) catch
        return .{ .status = 500, .body = "{\"error\":\"alloc failed\"}" };
    defer global_allocator.free(buf);
    const f_in = std.fs.cwd().openFile("accounts.json", .{}) catch return .{ .status = 404, .body = "{\"error\":\"no accounts.json\"}" };
    defer f_in.close();
    const n = f_in.readAll(buf) catch return .{ .status = 500, .body = "{\"error\":\"read failed\"}" };
    const parsed_existing = std.json.parseFromSlice(std.json.Value, global_allocator, buf[0..n], .{}) catch
        return .{ .status = 500, .body = "{\"error\":\"parse failed\"}" };
    defer parsed_existing.deinit();
    const accs = parsed_existing.value.object.get("accounts") orelse
        return .{ .status = 500, .body = "{\"error\":\"malformed\"}" };
    if (accs != .object) return .{ .status = 500, .body = "{\"error\":\"malformed\"}" };
    if (accs.object.get(name) == null) return .{ .status = 404, .body = "{\"error\":\"not found\"}" };

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(global_allocator);
    const w = out.writer(global_allocator);
    w.writeAll("{\n  \"accounts\": {\n") catch return .{ .status = 500, .body = "{\"error\":\"write failed\"}" };
    var it = accs.object.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, name)) continue;
        if (!first) w.writeAll(",\n") catch return .{ .status = 500, .body = "{\"error\":\"write failed\"}" };
        first = false;
        const val_str = std.json.Stringify.valueAlloc(global_allocator, entry.value_ptr.*, .{}) catch
            return .{ .status = 500, .body = "{\"error\":\"write failed\"}" };
        defer global_allocator.free(val_str);
        w.print("    \"{s}\": {s}", .{ entry.key_ptr.*, val_str }) catch
            return .{ .status = 500, .body = "{\"error\":\"write failed\"}" };
    }
    w.writeAll("\n  }\n}\n") catch return .{ .status = 500, .body = "{\"error\":\"write failed\"}" };

    const f_out = std.fs.cwd().createFile("accounts.json", .{}) catch return .{ .status = 500, .body = "{\"error\":\"write failed\"}" };
    defer f_out.close();
    f_out.writeAll(out.items) catch return .{ .status = 500, .body = "{\"error\":\"write failed\"}" };

    // Reload.
    account_mgr.deinit();
    account_mgr = accounts.AccountManager.init(global_allocator);
    account_mgr.loadFromFile() catch {};

    std.debug.print("[delete] account '{s}' removed\n", .{name});
    return .{ .status = 200, .body = "{\"success\":true}" };
}

