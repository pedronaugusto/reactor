//! How long a backend's poll may wait for a completion or a wake.
pub const Wait = union(enum) {
    /// Take what is complete and return.
    nowait,
    /// Until a completion or a wake.
    forever,
    /// At most this many nanoseconds.
    ns: u64,
};
