const GameVars = @This();
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const default_server_vars: []const ServerVar = &.{
    .{ .key = .already_set_gender, .value = 1 },
    .{ .key = .dash_energy_limit, .value = 100 },
    .{ .key = .already_set_name, .value = 1 },
};

pub const default_client_vars: []const ClientVar = &.{
    .{ .key = 43, .value = 1 },
    .{ .key = 78, .value = 1 },
    .{ .key = 82, .value = 1 },
    .{ .key = 125, .value = 1 },
    .{ .key = 126, .value = 1 },
};

pub const ClientVar = packed struct {
    key: i32,
    value: i64,
};

pub const ServerVar = packed struct {
    key: ServerVarType,
    value: i64,
};

client_vars: []ClientVar,
server_vars: []ServerVar,

pub fn deinit(gv: *GameVars, gpa: Allocator) void {
    gpa.free(gv.client_vars);
    gpa.free(gv.server_vars);
}

pub const ServerVarType = enum(i32) {
    const common_begin: i32 = 100000;
    const common_end: i32 = 109999;
    const daily_refresh_begin: i32 = 110000;
    const daily_refresh_end: i32 = 119999;

    pub const Kind = enum(i32) {
        common = 10,
        daily_refresh = 11,
        weekly_refresh = 12,
        monthly_refresh = 13,
    };

    server_test_1 = 100001,
    server_test_2 = 100002,
    already_set_gender = 100003,
    enhance_bean = 100004,
    enhance_bean_last_replenish_time = 100005,
    dash_energy_limit = 100006,
    already_set_name = 100007,
    social_share_control = 100008,
    db_config_version = 100009,
    client_debug_mode_end_time = 100010,
    recover_ap_by_money_count = 110001,
    poop_cow_interact_count = 110002,
    stamina_reduce_used_count = 110003,
    space_ship_daily_credit_reward = 110004,
    daily_enemy_drop_mod_reward_count = 110005,
    daily_enemy_exp_count = 110006,

    pub inline fn kind(vt: ServerVarType) Kind {
        return @enumFromInt(@intFromEnum(vt) / 10_000);
    }
};
