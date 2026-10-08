//! Shared only by the isolated suite runner and adapted test modules.
const std = @import("std");
pub const reactor = @import("reactor");
pub var io: std.Io = undefined;
