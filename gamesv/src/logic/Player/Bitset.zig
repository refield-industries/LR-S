const Bitset = @This();
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const max_value = 512;
const Set = std.bit_set.ArrayBitSet(u64, max_value);

pub const init: Bitset = .{};

sets: [Type.count]Set = @splat(.initEmpty()),

pub fn set(b: *Bitset, t: Type, value: u64) error{ValueOutOfRange}!void {
    if (value > max_value) return error.ValueOutOfRange;

    b.sets[@intFromEnum(t) - 1].set(@intCast(value));
}

pub const Type = enum(u32) {
    pub const count: usize = blk: {
        const values = std.enums.values(Type);
        break :blk @as(usize, @intFromEnum(values[values.len - 1])) + 1;
    };

    found_item = 1,
    wiki = 2,
    unread_wiki = 3,
    monster_drop = 4,
    got_item = 5,
    area_first_view = 6,
    unread_got_item = 7,
    prts = 8,
    unread_prts = 9,
    prts_first_lv = 10,
    prts_terminal_content = 11,
    level_have_been = 12,
    level_map_first_view = 13,
    unread_formula = 14,
    new_char = 15,
    elog_channel = 16,
    fmv_watched = 17,
    time_line_watched = 18,
    map_filter = 19,
    friend_has_request = 20,
    equip_tech_formula = 21,
    radio_trigger = 22,
    remote_communication_finish = 23,
    unlock_server_dungeon_series = 24,
    chapter_first_view = 25,
    adventure_level_reward_done = 26,
    dungeon_entrance_touched = 27,
    equip_tech_tier = 28,
    char_doc = 30,
    char_voice = 31,
    reading_pop = 32,
    reward_id_done = 33,
    prts_investigate = 34,
    racing_received_bp_node = 35,
    racing_complete_achievement = 36,
    racing_received_achievement = 37,
    interactive_active = 39,
    mine_point_first_time_collect = 40,
    unread_char_doc = 41,
    unread_char_voice = 42,
    area_toast_once = 44,
    unread_equip_tech_formula = 45,
    prts_investigate_unread_note = 46,
    prts_investigate_note = 47,
    game_mechanic_read = 48,
    read_active_blackbox = 49,
    read_level = 50,
    factroy_placed_building = 51,
    interactive_two_state = 52,
    unread_unlock_spaceship_room_type = 53,
    unlock_spaceship_room_type = 54,
    unlock_user_avatar = 55,
    unlock_user_avatar_frame = 56,
    unlock_business_card_topic = 57,
    special_game_event = 58,
    radio_id = 59,
    got_weapon = 60,
    read_new_version_equip_tech_formula = 61,
    mist_map_unlocked = 62,
    read_achive = 63,
    camera_volume = 64,
    read_fac_tech_tree_unhidden_tech = 65,
    read_fac_tech_tree_unhidden_category = 66,
    mist_map_mv_watched = 67,
    remote_communication_wait_for_play = 68,
    mission_completed_once = 69,
    psn_cup_unlocked = 70,
    unread_week_raid_mission = 71,
    unlock_game_entrance_activity_series = 72,
    unlock_domain_depot = 73,
    unlock_recycle_bin = 74,
    manual_crafted_item = 75,
    un_read_new_activity_notify = 76,
    read_picture_ids = 77,
    read_shop_id = 78,
    read_shop_goods_id = 79,
    read_bp_season_id = 80,
    read_bp_task_id = 81,
    read_cash_shop_goods_id = 82,
    new_avatar_unlock = 83,
    new_avatar_frame_unlock = 84,
    new_theme_unlock = 85,
    read_char_potential_pic_ids = 86,
    read_high_difficulty_dungeon_series = 87,
    reported_client_log_types = 88,
    activated_factory_inst = 89,
    read_max_world_level = 90,
    got_formula_unlock_item = 91,
};
