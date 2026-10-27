//! Where a thread holding a processor is: in the runtime, or lending the
//! processor while its task runs its own code or sits in a blocking call.

pub const Stage = enum(u32) {
    /// In the runtime, in a seat's first generation.
    first = 0,
    _,

    /// Where the thread is.
    pub const Mode = enum(u2) {
        /// In the runtime: its processor is its own to touch.
        inside,
        /// Its task runs its own code: the processor is lent.
        user,
        /// Its task sits in a blocking call: the processor is lent, and
        /// watched from the start of the call.
        blocked,
    };

    /// The mode in the low bits, and above it a generation every move
    /// advances, so a stage read before a move never equals one after.
    const Word = packed struct(u32) { mode: Mode, generation: u30 };

    pub fn mode(s: Stage) Mode {
        const word: Word = @bitCast(@backingInt(s));
        return word.mode;
    }

    /// `s` moved to `to`, in its next generation.
    pub fn moved(s: Stage, to: Mode) Stage {
        var word: Word = @bitCast(@backingInt(s));
        word.mode = to;
        word.generation +%= 1;
        return @fromBackingInt(@as(u32, @bitCast(word)));
    }
};
