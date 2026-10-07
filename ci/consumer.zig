//! What a project that depends on reactor and nothing else writes. Built by
//! `zig build check-consumer` with no packages to fetch, so reactor's
//! build.zig must work without any of its own CI dependencies.
const std = @import("std");
const reactor = @import("reactor");

pub fn main() void {
    _ = &reactor.Runtime.init;
    _ = &reactor.Runtime.io;
    _ = &reactor.Loop.init;
    _ = &reactor.Loop.run;
    _ = &reactor.wait;
    _ = &reactor.Wake.init;
    _ = &reactor.net.connect;
    _ = std;
}
