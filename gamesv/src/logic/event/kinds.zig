pub const Login = struct {};

pub const CharBagTeamModified = struct {
    team_index: usize,
    modification: enum {
        set_leader,
        set_char_team,
    },
};

pub const SyncSelfScene = struct {
    reason: enum {
        entrance,
        team_modified,
    },
};
