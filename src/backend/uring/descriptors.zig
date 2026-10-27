//! A descriptor as a table shared between rings keeps it: found by probing
//! from its number, where `empty` ends a probe and `tombstone`, a removed
//! entry, is passed over so that one placed after it stays reachable.
const std = @import("std");
const aegis = @import("aegis");
const linux = std.os.linux;

pub const Descriptor = enum(linux.fd_t) {
    empty = -1,
    tombstone = -2,
    _,

    pub fn of(fd: linux.fd_t) Descriptor {
        return @fromBackingInt(fd);
    }

    /// Whether it names a descriptor, rather than no entry or a removed one.
    pub fn named(d: Descriptor) bool {
        return @backingInt(d) >= 0;
    }
};

/// One entry of such a table, read and written by any ring.
pub const Cell = aegis.Atomic(Descriptor);
