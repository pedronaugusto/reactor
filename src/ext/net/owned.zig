//! The handles reactor's own calls hand back, each with its one owner,
//! which closes it once: `deinit(io)`, or `take` it out to keep it.
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;

/// A file handle with its one owner: a named pipe's end.
pub const File = aegis.own.OwnedIo(Io.File, closeFile);
/// A connected socket with its one owner, as `File`.
pub const Stream = aegis.own.OwnedIo(Io.net.Stream, closeStream);
/// A listening socket with its one owner, as `File`.
pub const Server = aegis.own.OwnedIo(Io.net.Server, closeServer);

fn closeFile(file: *Io.File, io: Io) void {
    file.close(io);
}

fn closeStream(stream: *Io.net.Stream, io: Io) void {
    stream.close(io);
}

fn closeServer(server: *Io.net.Server, io: Io) void {
    server.deinit(io);
}
