//! The handles reactor's own calls hand back, each with its one owner,
//! which closes it once: `deinit(io)`, or `take` it out to keep it.
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;

/// A file handle with its one owner: a named pipe's end. aegis's `own.File`, the one owner type of
/// an open file, so a handle reactor hands back passes to any package as the same type.
pub const File = aegis.own.File;
/// A connected socket with its one owner: aegis's `own.Stream`.
pub const Stream = aegis.own.Stream;
/// A listening socket with its one owner: aegis's `own.Server`.
pub const Server = aegis.own.Server;
