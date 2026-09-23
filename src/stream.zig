const std = @import("std");
const accounts = @import("accounts.zig");
const zed = @import("zed.zig");
const proxy = @import("proxy.zig");
const providers = @import("providers.zig");
const socket = @import("socket.zig");

const sse_header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: *\r\n\r\n";

/// Handle streaming proxy with account failover. Failover is permitted only before
/// any response bytes have been sent to the client.
pub fn handleStreamProxy(client_stream: std.net.Stream, body: []const u8, is_anthropic: bool, account_mgr: *accounts.AccountManager, allocator: std.mem.Allocator) void {
    if (account_mgr.list.items.len == 0) {
        socket.writeResponse(client_stream, 400, "{\"error\":\"no account configured\"}");
        return;
    }
    const total = account_mgr.list.items.len;
    var try_order: [64]usize = undefined;
    const count = @min(total, 64);
    try_order[0] = account_mgr.current;
    var idx: usize = 1;
    for (0..total) |i| {
        if (i != account_mgr.current and idx < count) {
            try_order[idx] = i;
            idx += 1;
        }
    }
    for (try_order[0..count]) |acc_idx| {
        const acc = &account_mgr.list.items[acc_idx];
        const result = doStreamProxy(client_stream, acc, body, is_anthropic, allocator);
        if (result != .retry) {
            if (result == .success and acc_idx != account_mgr.current) account_mgr.current = acc_idx;
            return;
        }
        std.debug.print("[zed2api] stream: account '{s}' failed, trying next...\n", .{acc.name});
    }
    socket.writeResponse(client_stream, 502, "{\"error\":{\"message\":\"All accounts failed\",\"type\":\"upstream_error\"}}");
}

const Attempt = enum { retry, success, sent_failure };

fn doStreamProxy(client_stream: std.net.Stream, acc: *accounts.Account, body: []const u8, is_anthropic: bool, allocator: std.mem.Allocator) Attempt {
    const payload = providers.buildZedPayload(allocator, body, is_anthropic) catch return .retry;
    defer allocator.free(payload);
    const jwt = zed.getTokenCopy(allocator, acc) catch return .retry;
    defer allocator.free(jwt);
    const bearer = std.fmt.allocPrint(allocator, "authorization: Bearer {s}", .{jwt}) catch return .retry;
    defer allocator.free(bearer);
    proxy.init(allocator);

    var tmp_name_buf: [64]u8 = undefined;
    var tmp_path: []const u8 = undefined;
    while (true) {
        tmp_path = std.fmt.bufPrint(&tmp_name_buf, "zed2api_stream_{x}.json", .{std.crypto.random.int(u128)}) catch return .retry;
        const file = std.fs.cwd().createFile(tmp_path, .{ .exclusive = true }) catch |err| {
            if (err == error.PathAlreadyExists) continue;
            return .retry;
        };
        file.writeAll(payload) catch {
            file.close();
            std.fs.cwd().deleteFile(tmp_path) catch {};
            return .retry;
        };
        file.close();
        break;
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};
    const at_path = std.fmt.allocPrint(allocator, "@{s}", .{tmp_path}) catch return .retry;
    defer allocator.free(at_path);
    const proxy_url = if (proxy.getHost()) |host|
        (std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ host, proxy.getPort() }) catch return .retry)
    else
        null;
    defer if (proxy_url) |p| allocator.free(p);

    var argv_buf: [28][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = "curl"; argc += 1;
    argv_buf[argc] = "-siN"; argc += 1;
    argv_buf[argc] = "--suppress-connect-headers"; argc += 1;
    argv_buf[argc] = "--connect-timeout"; argc += 1;
    argv_buf[argc] = "10"; argc += 1;
    if (proxy_url) |p| {
        argv_buf[argc] = "-x"; argc += 1;
        argv_buf[argc] = p; argc += 1;
        argv_buf[argc] = "--noproxy"; argc += 1;
        argv_buf[argc] = ""; argc += 1;
    } else {
        argv_buf[argc] = "--proxy"; argc += 1;
        argv_buf[argc] = ""; argc += 1;
    }
    argv_buf[argc] = "-X"; argc += 1;
    argv_buf[argc] = "POST"; argc += 1;
    argv_buf[argc] = "https://cloud.zed.dev/completions"; argc += 1;
    argv_buf[argc] = "-H"; argc += 1;
    argv_buf[argc] = bearer; argc += 1;
    argv_buf[argc] = "-H"; argc += 1;
    argv_buf[argc] = "content-type: application/json"; argc += 1;
    argv_buf[argc] = "-H"; argc += 1;
    argv_buf[argc] = "x-zed-version: 0.222.4+stable.147.b385025df963c9e8c3f74cc4dadb1c4b29b3c6f0"; argc += 1;
    argv_buf[argc] = "--data-binary"; argc += 1;
    argv_buf[argc] = at_path; argc += 1;
    argv_buf[argc] = "--max-time"; argc += 1;
    argv_buf[argc] = "300"; argc += 1;

    var child = std.process.Child.init(argv_buf[0..argc], allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return .retry;
    const stdout = child.stdout orelse {
        _ = child.wait() catch {};
        return .retry;
    };
    const request = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch null;
    defer if (request) |r| r.deinit();
    const model = if (request) |r| (if (r.value == .object) providers.extractModel(r.value) else "claude-sonnet-4-5") else "claude-sonnet-4-5";
    var state = StreamState{ .anthropic = is_anthropic, .model = model };
    var headers_sent = false;
    var http_status: u16 = 0;
    var in_headers = true;
    var line_buf: [65536]u8 = undefined;
    var line_len: usize = 0;
    var read_failed = false;
    var overflow = false;
    var completed = false;

    while (true) {
        var one: [1]u8 = undefined;
        const n = stdout.read(&one) catch { read_failed = true; break; };
        if (n == 0) break;
        if (one[0] != '\n') {
            if (line_len < line_buf.len) {
                line_buf[line_len] = one[0];
                line_len += 1;
            } else overflow = true;
            continue;
        }
        const raw = line_buf[0..line_len];
        const line = std.mem.trimEnd(u8, raw, "\r");
        line_len = 0;
        if (overflow) { overflow = false; read_failed = true; break; }
        if (in_headers) {
            if (std.mem.startsWith(u8, line, "HTTP/")) {
                var parts = std.mem.tokenizeScalar(u8, line, ' ');
                _ = parts.next();
                http_status = if (parts.next()) |code| std.fmt.parseInt(u16, code, 10) catch 0 else 0;
            } else if (line.len == 0) {
                // curl may include 100 Continue or proxy CONNECT headers before the final response.
                if (http_status >= 200 or http_status == 0) in_headers = false;
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "HTTP/")) {
            in_headers = true;
            var parts = std.mem.tokenizeScalar(u8, line, ' ');
            _ = parts.next();
            http_status = if (parts.next()) |code| std.fmt.parseInt(u16, code, 10) catch 0 else 0;
            continue;
        }
        if (http_status != 200 or line.len == 0) continue;
        const data_line = if (std.mem.startsWith(u8, line, "data: ")) line[6..] else line;
        if (std.mem.eql(u8, data_line, "[DONE]")) { completed = true; continue; }
        if (isTerminalEvent(data_line, allocator)) completed = true;
        var out: std.io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        convertLine(&out.writer, &state, data_line, allocator) catch { read_failed = true; break; };
        if (out.written().len == 0) continue;
        if (!headers_sent) {
            socket.send(client_stream, sse_header) catch { read_failed = true; break; };
            headers_sent = true;
        }
        socket.send(client_stream, out.written()) catch { read_failed = true; break; };
    }
    // A final JSON line need not be newline-terminated.
    if (overflow) read_failed = true;
    if (!read_failed and line_len > 0 and !in_headers and http_status == 200) {
        var out: std.io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const raw_last = std.mem.trimEnd(u8, line_buf[0..line_len], "\r");
        const last = if (std.mem.startsWith(u8, raw_last, "data: ")) raw_last[6..] else raw_last;
        if (std.mem.eql(u8, last, "[DONE]")) completed = true;
        if (isTerminalEvent(last, allocator)) completed = true;
        if (!std.mem.eql(u8, last, "[DONE]")) convertLine(&out.writer, &state, last, allocator) catch { read_failed = true; };
        if (!read_failed and out.written().len > 0) {
            if (!headers_sent) {
                if (socket.send(client_stream, sse_header)) |_| { headers_sent = true; } else |_| { read_failed = true; }
            }
            if (!read_failed) socket.send(client_stream, out.written()) catch { read_failed = true; };
        }
    }
    const term = child.wait() catch blk: { read_failed = true; break :blk null; };
    const exit_ok = if (term) |t| switch (t) { .Exited => |code| code == 0, else => false } else false;
    if (http_status != 200 or !exit_ok or read_failed or state.failed or !state.started or !completed) {
        std.debug.print("[stream] failed: http={d}, curl_ok={}, read_failed={}, completed={}\n", .{ http_status, exit_ok, read_failed, completed });
        if (!headers_sent) return .retry;
        if (!state.failed and !read_failed) {
            var out: std.io.Writer.Allocating = .init(allocator);
            defer out.deinit();
            emitError(&out.writer, &state, "Upstream stream interrupted") catch {};
            socket.send(client_stream, out.written()) catch {};
        }
        if (!state.anthropic) socket.send(client_stream, "data: [DONE]\n\n") catch {};
        return .sent_failure;
    }
    var end: std.io.Writer.Allocating = .init(allocator);
    defer end.deinit();
    finish(&end.writer, &state) catch return .sent_failure;
    socket.send(client_stream, end.written()) catch return .sent_failure;
    return .success;
}

const StreamState = struct {
    anthropic: bool,
    model: []const u8,
    started: bool = false,
    failed: bool = false,
    tool_seen: bool = false,
    tool_index: usize = 0,
    block_index: usize = 0,
    block_open: bool = false,
    text_open: bool = false,
    finish_reason: ?[]const u8 = null,
};

fn start(w: *std.io.Writer, state: *StreamState) !void {
    if (state.started) return;
    state.started = true;
    if (state.anthropic) {
        try w.writeAll("event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_zed\",\"type\":\"message\",\"role\":\"assistant\",\"model\":");
        try std.json.Stringify.encodeJsonString(state.model, .{}, w);
        try w.writeAll(",\"content\":[],\"stop_reason\":null,\"usage\":{\"input_tokens\":0,\"output_tokens\":0}}}\n\n");
    } else {
        try chunkPrefix(w, state);
        try w.writeAll("{\"role\":\"assistant\"}");
        try chunkEnd(w, null);
    }
}

fn chunkPrefix(w: *std.io.Writer, state: *const StreamState) !void {
    try w.writeAll("data: {\"id\":\"chatcmpl-zed\",\"object\":\"chat.completion.chunk\",\"created\":0,\"model\":");
    try std.json.Stringify.encodeJsonString(state.model, .{}, w);
    try w.writeAll(",\"choices\":[{\"index\":0,\"delta\":");
}
fn chunkEnd(w: *std.io.Writer, reason: ?[]const u8) !void {
    try w.writeAll(",\"finish_reason\":");
    if (reason) |r| try std.json.Stringify.encodeJsonString(r, .{}, w) else try w.writeAll("null");
    try w.writeAll("}]}\n\n");
}
fn text(w: *std.io.Writer, state: *StreamState, content: []const u8) !void {
    if (content.len == 0) return;
    try start(w, state);
    if (state.anthropic) {
        if (!state.text_open) {
            try w.print("event: content_block_start\ndata: {{\"type\":\"content_block_start\",\"index\":{d},\"content_block\":{{\"type\":\"text\",\"text\":\"\"}}}}\n\n", .{state.block_index});
            state.text_open = true;
            state.block_open = true;
        }
        try w.print("event: content_block_delta\ndata: {{\"type\":\"content_block_delta\",\"index\":{d},\"delta\":{{\"type\":\"text_delta\",\"text\":", .{state.block_index});
        try std.json.Stringify.encodeJsonString(content, .{}, w);
        try w.writeAll("}}\n\n");
    } else {
        try chunkPrefix(w, state);
        try w.writeAll("{\"content\":");
        try std.json.Stringify.encodeJsonString(content, .{}, w);
        try w.writeAll("}");
        try chunkEnd(w, null);
    }
}
fn stopBlock(w: *std.io.Writer, state: *StreamState) !void {
    if (!state.anthropic or !state.block_open) return;
    try w.print("event: content_block_stop\ndata: {{\"type\":\"content_block_stop\",\"index\":{d}}}\n\n", .{state.block_index});
    state.block_index += 1;
    state.block_open = false;
    state.text_open = false;
}
fn toolStart(w: *std.io.Writer, state: *StreamState, id: std.json.Value, name: std.json.Value) !void {
    if (id != .string or name != .string) return;
    try start(w, state);
    state.tool_seen = true;
    if (state.anthropic) {
        try stopBlock(w, state);
        try w.print("event: content_block_start\ndata: {{\"type\":\"content_block_start\",\"index\":{d},\"content_block\":{{\"type\":\"tool_use\",\"id\":", .{state.block_index});
        try std.json.Stringify.value(id, .{}, w);
        try w.writeAll(",\"name\":");
        try std.json.Stringify.value(name, .{}, w);
        try w.writeAll(",\"input\":{}}}\n\n");
        state.block_open = true;
    } else {
        try chunkPrefix(w, state);
        try w.print("{{\"tool_calls\":[{{\"index\":{d},\"id\":", .{state.tool_index});
        try std.json.Stringify.value(id, .{}, w);
        try w.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
        try std.json.Stringify.value(name, .{}, w);
        try w.writeAll(",\"arguments\":\"\"}}]}");
        try chunkEnd(w, null);
        state.tool_index += 1;
    }
}
fn toolArguments(w: *std.io.Writer, state: *StreamState, arguments: []const u8) !void {
    if (arguments.len == 0) return;
    try start(w, state);
    if (state.anthropic) {
        try w.print("event: content_block_delta\ndata: {{\"type\":\"content_block_delta\",\"index\":{d},\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":", .{state.block_index});
        try std.json.Stringify.encodeJsonString(arguments, .{}, w);
        try w.writeAll("}}\n\n");
    } else {
        try chunkPrefix(w, state);
        try w.print("{{\"tool_calls\":[{{\"index\":{d},\"function\":{{\"arguments\":", .{if (state.tool_index > 0) state.tool_index - 1 else 0});
        try std.json.Stringify.encodeJsonString(arguments, .{}, w);
        try w.writeAll("}}]}");
        try chunkEnd(w, null);
    }
}
fn emitError(w: *std.io.Writer, state: *StreamState, message: []const u8) !void {
    state.failed = true;
    if (state.anthropic) try w.writeAll("event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"api_error\",\"message\":") else try w.writeAll("data: {\"error\":{\"type\":\"upstream_error\",\"message\":");
    try std.json.Stringify.encodeJsonString(message, .{}, w);
    try w.writeAll("}}\n\n");
}
fn finish(w: *std.io.Writer, state: *StreamState) !void {
    if (state.anthropic) {
        try stopBlock(w, state);
        try w.writeAll("event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":");
        const reason = state.finish_reason orelse if (state.tool_seen) "tool_use" else "end_turn";
        try std.json.Stringify.encodeJsonString(reason, .{}, w);
        try w.writeAll("},\"usage\":{\"output_tokens\":0}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n");
    } else {
        try chunkPrefix(w, state);
        try w.writeAll("{}");
        try chunkEnd(w, state.finish_reason orelse if (state.tool_seen) "tool_calls" else "stop");
        try w.writeAll("data: [DONE]\n\n");
    }
}

fn isTerminalEvent(line: []const u8, allocator: std.mem.Allocator) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const obj = if (parsed.value.object.get("event")) |event| (if (event == .object) event else parsed.value) else parsed.value;
    const kind = obj.object.get("type") orelse return false;
    if (kind != .string) return false;
    return std.mem.eql(u8, kind.string, "response.completed") or std.mem.eql(u8, kind.string, "message_stop");
}

/// Convert one JSON line from Zed. All output goes through a writer so this
/// conversion can be tested independently of sockets and curl.
fn convertLine(w: *std.io.Writer, state: *StreamState, line: []const u8, allocator: std.mem.Allocator) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const obj = if (parsed.value.object.get("event")) |event| (if (event == .object) event else parsed.value) else parsed.value;
    const kind = if (obj.object.get("type")) |v| (if (v == .string) v.string else "") else "";
    if (std.mem.eql(u8, kind, "error") or std.mem.eql(u8, kind, "response.failed")) {
        var message: []const u8 = "Upstream error";
        if (obj.object.get("error")) |err| {
            if (err == .object) {
                if (err.object.get("message")) |m| { if (m == .string) message = m.string; }
            } else if (err == .string) message = err.string;
        }
        if (state.started) try emitError(w, state, message) else state.failed = true;
        return;
    }
    if (state.failed) return;
    if (std.mem.eql(u8, kind, "message_start") or std.mem.eql(u8, kind, "response.created")) { try start(w, state); return; }
    if (std.mem.eql(u8, kind, "response.completed") or std.mem.eql(u8, kind, "message_stop")) return;
    if (std.mem.eql(u8, kind, "message_delta")) {
        if (obj.object.get("delta")) |d| {
            if (d == .object) {
                if (d.object.get("stop_reason")) |r| {
                    if (r == .string) {
                        if (std.mem.eql(u8, r.string, "tool_use")) state.finish_reason = if (state.anthropic) "tool_use" else "tool_calls"
                        else if (std.mem.eql(u8, r.string, "max_tokens")) state.finish_reason = if (state.anthropic) "max_tokens" else "length"
                        else state.finish_reason = if (state.anthropic) "end_turn" else "stop";
                    }
                }
            }
        }
        return;
    }
    if (std.mem.eql(u8, kind, "content_block_start")) {
        const cb = obj.object.get("content_block") orelse return;
        if (cb != .object) return;
        const t = cb.object.get("type") orelse return;
        if (t != .string) return;
        if (std.mem.eql(u8, t.string, "tool_use")) {
            try toolStart(w, state, cb.object.get("id") orelse return, cb.object.get("name") orelse return);
        } else if (state.anthropic) {
            try start(w, state);
            try stopBlock(w, state);
            try w.print("event: content_block_start\ndata: {{\"type\":\"content_block_start\",\"index\":{d},\"content_block\":{{\"type\":", .{state.block_index});
            try std.json.Stringify.value(t, .{}, w);
            if (std.mem.eql(u8, t.string, "thinking")) try w.writeAll(",\"thinking\":\"\"}}\n\n") else try w.writeAll(",\"text\":\"\"}}\n\n");
            state.block_open = true;
            state.text_open = std.mem.eql(u8, t.string, "text");
        }
        return;
    }
    if (std.mem.eql(u8, kind, "content_block_stop")) { try stopBlock(w, state); return; }
    if (std.mem.eql(u8, kind, "content_block_delta")) {
        const d = obj.object.get("delta") orelse return;
        if (d != .object) return;
        const dt = d.object.get("type") orelse return;
        if (dt != .string) return;
        if (std.mem.eql(u8, dt.string, "text_delta")) {
            if (d.object.get("text")) |v| { if (v == .string) try text(w, state, v.string); }
        } else if (std.mem.eql(u8, dt.string, "input_json_delta")) {
            if (d.object.get("partial_json")) |v| { if (v == .string) try toolArguments(w, state, v.string); }
        } else if (state.anthropic and std.mem.eql(u8, dt.string, "thinking_delta")) {
            try start(w, state);
            try w.print("event: content_block_delta\ndata: {{\"type\":\"content_block_delta\",\"index\":{d},\"delta\":", .{state.block_index});
            try std.json.Stringify.value(d, .{}, w);
            try w.writeAll("}\n\n");
        }
        return;
    }
    if (std.mem.eql(u8, kind, "response.output_text.delta")) {
        if (obj.object.get("delta")) |v| { if (v == .string) try text(w, state, v.string); }
        return;
    }
    if (obj.object.get("choices")) |choices| {
        if (choices != .array or choices.array.items.len == 0) return;
        const choice = choices.array.items[0];
        if (choice != .object) return;
        if (choice.object.get("finish_reason")) |reason| {
            if (reason == .string) {
                if (std.mem.eql(u8, reason.string, "tool_calls")) state.finish_reason = if (state.anthropic) "tool_use" else "tool_calls"
                else if (std.mem.eql(u8, reason.string, "length")) state.finish_reason = if (state.anthropic) "max_tokens" else "length"
                else state.finish_reason = if (state.anthropic) "end_turn" else "stop";
            }
        }
        const d = choice.object.get("delta") orelse return;
        if (d != .object) return;
        if (d.object.get("content")) |v| { if (v == .string) try text(w, state, v.string); }
        if (d.object.get("tool_calls")) |calls| {
            if (calls == .array) for (calls.array.items) |call| {
                if (call != .object) continue;
                const func = call.object.get("function") orelse continue;
                if (func != .object) continue;
                if (call.object.get("id")) |id| {
                    if (func.object.get("name")) |name| try toolStart(w, state, id, name);
                }
                if (func.object.get("arguments")) |args| {
                    if (args == .string) try toolArguments(w, state, args.string);
                }
            };
        }
        return;
    }
    if (obj.object.get("candidates")) |candidates| {
        if (candidates != .array or candidates.array.items.len == 0) return;
        const cand = candidates.array.items[0];
        if (cand != .object) return;
        const content = cand.object.get("content") orelse return;
        if (content != .object) return;
        const parts = content.object.get("parts") orelse return;
        if (parts != .array) return;
        for (parts.array.items) |part| {
            if (part != .object) continue;
            if (part.object.get("text")) |v| { if (v == .string) try text(w, state, v.string); }
        }
    }
}

test "terminal event detection ignores text containing terminal names" {
    const a = std.testing.allocator;
    try std.testing.expect(isTerminalEvent("{\"event\":{\"type\":\"response.completed\"}}", a));
    try std.testing.expect(isTerminalEvent("{\"type\":\"message_stop\"}", a));
    try std.testing.expect(!isTerminalEvent("{\"type\":\"content_block_delta\",\"text\":\"response.completed\"}", a));
    try std.testing.expect(!isTerminalEvent("not json", a));
}

test "OpenAI stream emits role, escaped text, tool chunks, terminal chunk and DONE" {
    const a = std.testing.allocator;
    var out: std.io.Writer.Allocating = .init(a);
    defer out.deinit();
    var state = StreamState{ .anthropic = false, .model = "claude-test" };
    try convertLine(&out.writer, &state, "{\"event\":{\"type\":\"message_start\"}}", a);
    try convertLine(&out.writer, &state, "{\"event\":{\"type\":\"content_block_start\",\"content_block\":{\"type\":\"text\"}}}", a);
    try convertLine(&out.writer, &state, "{\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"hi \\\"there\\\"\"}}}", a);
    try convertLine(&out.writer, &state, "{\"event\":{\"type\":\"content_block_start\",\"content_block\":{\"type\":\"tool_use\",\"id\":\"tool_1\",\"name\":\"search\"}}}", a);
    try convertLine(&out.writer, &state, "{\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"q\\\":1}\"}}}", a);
    try finish(&out.writer, &state);
    const result = out.written();
    try std.testing.expect(std.mem.indexOf(u8, result, "\"role\":\"assistant\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"content\":\"hi \\\"there\\\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"id\":\"tool_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"arguments\":\"{\\\"q\\\":1}\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"finish_reason\":\"tool_calls\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, result, "data: [DONE]\n\n"));
    var lines = std.mem.splitSequence(u8, result, "\n\n");
    while (lines.next()) |event| {
        if (!std.mem.startsWith(u8, event, "data: {") ) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, a, event[6..], .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("chat.completion.chunk", parsed.value.object.get("object").?.string);
    }
}

test "Anthropic stream retains block framing" {
    const a = std.testing.allocator;
    var out: std.io.Writer.Allocating = .init(a);
    defer out.deinit();
    var state = StreamState{ .anthropic = true, .model = "claude-test" };
    try convertLine(&out.writer, &state, "{\"type\":\"content_block_start\",\"content_block\":{\"type\":\"tool_use\",\"id\":\"t\",\"name\":\"run\"}}", a);
    try convertLine(&out.writer, &state, "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}", a);
    try convertLine(&out.writer, &state, "{\"type\":\"content_block_stop\"}", a);
    try finish(&out.writer, &state);
    var events = std.mem.splitSequence(u8, out.written(), "\n\n");
    while (events.next()) |event| {
        const data_start = std.mem.indexOf(u8, event, "data: ") orelse continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, a, event[data_start + 6 ..], .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
    }
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "event: content_block_stop\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"stop_reason\":\"tool_use\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, out.written(), "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"));
}
