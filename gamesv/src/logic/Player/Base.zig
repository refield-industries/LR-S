const Base = @This();
const common = @import("common");
const mem = common.mem;

pub const max_role_name_length: usize = 15;

pub const init: Base = .{
    .create_ts = 0,
    .role_name = .constant("xeondev"),
    .role_id = 1,
    .level = .first,
    .exp = 0,
    .create_ts_display = 0,
    .gender = .default,
};

pub const Gender = enum(u8) {
    pub const default: Gender = .male;

    invalid = 0,
    male = 1,
    female = 2,
};

pub const Level = enum(u8) {
    first = 1,
    last = 60,
    _,
};

create_ts: i64,
role_name: mem.LimitedString(max_role_name_length),
role_id: u64,
level: Level,
exp: u32,
create_ts_display: i64,
gender: Gender,
