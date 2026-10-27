//! A flag several threads read and write whole, kept in an aegis atomic
//! cell: set or clear, never the bool behind it.

pub const Flag = enum(u8) {
    clear,
    set,

    /// The flag a condition gives.
    pub fn of(condition: bool) Flag {
        return if (condition) .set else .clear;
    }
};
