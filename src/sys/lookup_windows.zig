//! Winsock's cancellable extended resolver. An OVERLAPPED event belongs
//! to one lookup; its owner waits for the event before releasing storage.
const std = @import("std");
const Io = std.Io;
const windows = std.os.windows;
const win32 = @import("win32.zig");

pub const Overlapped = extern struct {
    internal: usize = 0,
    internal_high: usize = 0,
    offset: u64 = 0,
    event: ?windows.HANDLE = null,
};

const Info = extern struct {
    flags: c_int = 0,
    family: c_int = 0,
    socktype: c_int = 1,
    protocol: c_int = 6,
    addrlen: usize = 0,
    canonname: ?[*:0]u16 = null,
    address: ?*Io.Threaded.PosixAddress = null,
    blob: ?*anyopaque = null,
    bloblen: usize = 0,
    provider: ?*anyopaque = null,
    next: ?*Info = null,
};

extern "ws2_32" fn WSAStartup(version: u16, data: *anyopaque) callconv(.winapi) c_int;
extern "ws2_32" fn WSACleanup() callconv(.winapi) c_int;
extern "ws2_32" fn GetAddrInfoExW(name: [*:0]const u16, service: [*:0]const u16, namespace: u32, provider: ?*anyopaque, hints: *const Info, result: *?*Info, timeout: ?*anyopaque, overlapped: *Overlapped, completion: ?*anyopaque, cancel_handle: *?windows.HANDLE) callconv(.winapi) c_int;
extern "ws2_32" fn GetAddrInfoExCancel(handle: *?windows.HANDLE) callconv(.winapi) c_int;
extern "ws2_32" fn GetAddrInfoExOverlappedResult(overlapped: *Overlapped) callconv(.winapi) c_int;
extern "ws2_32" fn FreeAddrInfoExW(info: *Info) callconv(.winapi) void;

pub const Error = error{ NameNotResolved, SystemResources, Unexpected };
pub const Result = struct { count: usize, canonical: ?Io.net.HostName = null };

pub const Request = struct {
    overlapped: Overlapped = .{},
    handle: ?windows.HANDLE = null,
    result: ?*Info = null,
    name: [255:0]u16 = undefined,
    service: [8:0]u16 = undefined,
    pending: bool = false,
    initialized: bool = false,

    /// The request must stay pinned through finish and deinit.
    pub fn start(r: *Request, name: []const u8, port: u16, family: ?Io.net.IpAddress.Family) Error!void {
        var data: [512]u8 align(8) = undefined;
        if (WSAStartup(0x202, &data) != 0) return error.SystemResources;
        r.initialized = true;
        r.overlapped.event = win32.CreateEventW(null, .TRUE, .FALSE, null) orelse return error.SystemResources;
        const count = std.unicode.utf8ToUtf16Le(&r.name, name) catch return error.NameNotResolved;
        r.name[count] = 0;
        var text: [8]u8 = undefined;
        const digits = std.mem.print(&text, "{d}", .{port}) catch unreachable; // unreachable: eight bytes hold a u16
        for (digits, 0..) |digit, i| r.service[i] = digit;
        r.service[digits.len] = 0;
        const hints: Info = .{ .flags = 2, .family = if (family) |f| switch (f) {
            .ip4 => 2,
            .ip6 => 23,
        } else 0 };
        switch (GetAddrInfoExW(&r.name, &r.service, 0, null, &hints, &r.result, null, &r.overlapped, null, &r.handle)) {
            0 => {},
            997 => r.pending = true,
            else => return error.NameNotResolved,
        }
    }

    pub fn cancel(r: *Request) void {
        if (r.pending) _ = GetAddrInfoExCancel(&r.handle);
    }

    pub fn finish(r: *Request, out: []Io.net.IpAddress, canonical_buffer: ?*[254]u8) Error!Result {
        const pending = r.pending;
        r.pending = false;
        if (pending and GetAddrInfoExOverlappedResult(&r.overlapped) != 0) return error.NameNotResolved;
        var item = r.result;
        var n: usize = 0;
        var canonical: ?Io.net.HostName = null;
        while (item) |info| : (item = info.next) {
            if (canonical_buffer) |buffer| if (info.canonname) |text| if (canonical == null) {
                const len = std.unicode.utf16LeToUtf8(buffer, std.mem.sliceTo(text, 0)) catch 0;
                if (len != 0) canonical = Io.net.HostName.init(buffer[0..len]) catch null;
            };
            if (n == out.len) break;
            if (info.family != 2 and info.family != 23) continue;
            const address = info.address orelse continue;
            out[n] = Io.Threaded.addressFromPosix(address);
            n += 1;
        }
        if (n == 0) return error.NameNotResolved;
        return .{ .count = n, .canonical = canonical };
    }

    /// Even on cancellation, wait for Winsock to release the request.
    pub fn deinit(r: *Request) void {
        if (r.pending) {
            r.cancel();
            _ = win32.WaitForSingleObject(r.overlapped.event.?, win32.infinite);
        }
        if (r.result) |info| FreeAddrInfoExW(info);
        if (r.overlapped.event) |event| windows.CloseHandle(event);
        if (r.initialized) _ = WSACleanup();
        r.* = undefined;
    }
};
