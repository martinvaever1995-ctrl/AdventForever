-------------------------------------------------------------------------------
--  Config.lua -- shared rules (category caps and so on), edited by officers in
--  the options window (/af options). Every change bumps the version and is
--  broadcast to the guild. Clients accept config only from officers: guild
--  members at rank officerRank or higher (rank 0 = GM). Only the GM's officerRank
--  is ever accepted, so officers can't widen their own circle.
-------------------------------------------------------------------------------
local _, AF = ...
local Config = AF:NewModule("Config")

local DEFAULTS = {
    version = 0,
    officerRank = 1,        -- ranks 0..officerRank count as officers (0 = GM)
    raidMax = 50,           -- weekly category caps; together they are the weekly max
    bankMax = 30,
    honorMax = 20,
    dungeonMax = 20,
    dungeonPerRun = 2.5,    -- points per dungeon run with guildies
    dungeonGuildMin = 3,    -- guild members in the group (you included) for a run to count
    finals = {},            -- extra final bosses officers marked: encounterID -> true
    goldPerPoint = 50,      -- guild bank: gold (or wanted-item gold value) per point
    wanted = {},            -- guild bank wanted list: itemID -> gold value per unit
    goals = {},             -- goals for wanted items: itemID -> { n = target count, since = server time }
    guildKillShare = 75,    -- % of the raid that must be guild members for a guild kill
    honorTarget = 5000,     -- weekly honor that gives the full honor score
    responseTimeout = 60,   -- seconds the loot popup stays up
    attunes = {},           -- attunements officers added: key -> { n = name, s = short label, q = { questIDs }, i = itemID }
    attunesOff = {},        -- built-in attunements officers hid: key -> true
}

-- What the options tab edits, in order (the wanted list has its own tab).
Config.FIELDS = {
    { key = "raidMax", label = "Raid points cap", min = 0, max = 100 },
    { key = "bankMax", label = "Guild bank points cap", min = 0, max = 100 },
    { key = "honorMax", label = "Honor points cap", min = 0, max = 100 },
    { key = "dungeonMax", label = "Dungeon points cap", min = 0, max = 100 },
    { key = "dungeonPerRun", label = "Points per dungeon run", min = 0.5, max = 100, decimals = true },
    { key = "dungeonGuildMin", label = "Guild members needed for a dungeon run", min = 2, max = 5 },
    { key = "goldPerPoint", label = "Gold per guild bank point", min = 1, max = 100000 },
    { key = "guildKillShare", label = "Guild members needed for a guild kill (%)", min = 1, max = 100 },
    { key = "honorTarget", label = "Weekly honor for the full honor score", min = 1, max = 10000000 },
    { key = "responseTimeout", label = "Loot popup timeout (seconds)", min = 10, max = 600 },
    { key = "officerRank", label = "Officer ranks: 0 to", min = 0, max = 9, gmOnly = true },
}

local cfg

-- Fills anything missing (older saved config, or a newer default) and drops
-- keys that no longer exist (v1's EP/GP settings) and malformed wanted entries.
local function Normalize(t)
    for k in pairs(t) do
        if DEFAULTS[k] == nil then t[k] = nil end
    end
    for k, v in pairs(DEFAULTS) do
        if type(t[k]) ~= type(v) then t[k] = type(v) == "table" and {} or v end
    end
    for id, value in pairs(t.wanted) do
        if type(id) ~= "number" or type(value) ~= "number" or value <= 0 then t.wanted[id] = nil end
    end
    for id, goal in pairs(t.goals) do
        local ok = t.wanted[id] and type(goal) == "table" and type(goal.n) == "number" and goal.n > 0
            and type(goal.since) == "number"
        if not ok then t.goals[id] = nil end
    end
    for id, on in pairs(t.finals) do
        if type(id) ~= "number" or on ~= true then t.finals[id] = nil end
    end
    for key, a in pairs(t.attunes) do
        local ok = type(key) == "string" and type(a) == "table" and type(a.n) == "string" and type(a.s) == "string"
            and (type(a.q) == "table" or type(a.i) == "number")
        if ok then
            a.q = type(a.q) == "table" and a.q or {}
            for i = #a.q, 1, -1 do
                if type(a.q[i]) ~= "number" then table.remove(a.q, i) end
            end
            if type(a.i) ~= "number" then a.i = nil end
            ok = #a.q > 0 or a.i ~= nil
        end
        if not ok then t.attunes[key] = nil end
    end
    for key, off in pairs(t.attunesOff) do
        if type(key) ~= "string" or off ~= true then t.attunesOff[key] = nil end
    end
    return t
end

function Config:Init()
    AF.db.config = Normalize(AF.db.config or {})
    cfg = AF.db.config
end

function Config:Get(key) return cfg[key] end

-------------------------------------------------------------------------------
--  Who counts as an officer
-------------------------------------------------------------------------------
function Config:IsOfficer(name)
    if name == AF.playerName then
        -- Our own rank straight from the game, so a name mismatch can't hide it.
        if not IsInGuild() then return false end
        if IsGuildLeader() then return true end
        local _, _, rankIndex = GetGuildInfo("player")
        return rankIndex ~= nil and rankIndex <= cfg.officerRank
    end
    local member = AF.Standings:All()[name]
    return member ~= nil and member.rankIndex <= cfg.officerRank
end

function Config:CanEdit()
    return AF:IsGM() or self:IsOfficer(AF.playerName)
end

-------------------------------------------------------------------------------
--  Sync
-------------------------------------------------------------------------------
local pendingReply      -- timer: answering a CFGQ unless someone beats us to it

local function Push()
    AF.Comm:Send("CFG", cfg, "GUILD")
end

AF.Comm:On("CFG", function(sender, incoming)
    if type(incoming) ~= "table" or type(incoming.version) ~= "number" then return end
    if sender == AF.playerName then return end
    if incoming.version >= cfg.version and pendingReply then
        pendingReply:Cancel()   -- another officer answered already
        pendingReply = nil
    end
    if incoming.version <= cfg.version or not Config:IsOfficer(sender) then return end
    local fromGM = AF.Standings:All()[sender].rankIndex == 0
    local officerRank = cfg.officerRank
    AF.db.config = Normalize(incoming)
    cfg = AF.db.config
    if not fromGM then cfg.officerRank = officerRank end
    AF:Printf("Effort rules updated to v%d by %s.", cfg.version, AF:ShortName(sender))
    AF:Fire("CONFIG_UPDATED")
end)

-- Someone asks for config newer than theirs. One officer answers on GUILD: each
-- waits a random moment and stays quiet if another answer arrives first.
AF.Comm:On("CFGQ", function(sender, theirVersion)
    if type(theirVersion) ~= "number" or not Config:CanEdit() then return end
    if theirVersion < cfg.version then
        if pendingReply then return end
        pendingReply = C_Timer.NewTimer(1 + math.random() * 4, function()
            pendingReply = nil
            Push()
        end)
    elseif theirVersion > cfg.version then
        -- Our saved config is older than the guild's (reinstall, new PC). Jump past it.
        cfg.version = theirVersion
        AF:Printf("Guild members have config v%d, newer than yours. Check /af options; your next save replaces it.", theirVersion)
    end
end)

function Config:Enable()
    -- Ask once the roster has loaded, so we can tell officers apart when answers come.
    C_Timer.After(15, function() AF.Comm:Send("CFGQ", cfg.version, "GUILD") end)
end

-- Validates and saves values from the options window, then broadcasts.
-- Returns nil, error on bad input.
function Config:Save(values)
    if not self:CanEdit() then return nil, "Only officers can change the effort rules." end
    for _, field in ipairs(self.FIELDS) do
        local v = values[field.key]
        if field.gmOnly and not AF:IsGM() then
            v = cfg[field.key]
        elseif type(v) ~= "number" or v < field.min or v > field.max then
            return nil, ("%s must be a number from %d to %d."):format(field.label, field.min, field.max)
        end
        values[field.key] = field.decimals and math.floor(v * 10 + 0.5) / 10 or math.floor(v)
    end
    if values.raidMax + values.bankMax + values.honorMax + values.dungeonMax > 200 then
        return nil, "The four caps can add up to at most 200 a week."
    end
    for _, field in ipairs(self.FIELDS) do cfg[field.key] = values[field.key] end
    self:Publish()
    return true
end

-- Bumps the version, sends the config to the guild and updates everyone's scores.
function Config:Publish()
    cfg.version = cfg.version + 1
    Push()
    AF:Printf("Effort rules v%d saved and sent to the guild.", cfg.version)
    AF:Fire("CONFIG_UPDATED")
    AF.Standings:QueueSnapshot()   -- rules changed, so scores may have too
end

-- Adds or changes (value) or removes (nil) an item on the guild bank wanted list.
-- goal: a target count (keeps counting from when the goal was first set), 0 to
-- remove the goal, nil to leave it as it is.
-- Marks (true) or unmarks (nil) an encounter as a dungeon's final boss.
function Config:SetFinal(encounterID, on)
    if not self:CanEdit() then return nil, "Only officers can change final bosses." end
    cfg.finals[encounterID] = on and true or nil
    self:Publish()
    return true
end

-- Adds an attunement (def = { n, s, q, i }) under a new key, or removes one
-- (def = nil): an added one is deleted, a built-in one hidden. restore = true
-- brings back every hidden built-in one.
function Config:SetAttune(key, def, restore)
    if not self:CanEdit() then return nil, "Only officers can change the attunements." end
    if restore then
        wipe(cfg.attunesOff)
    elseif def then
        cfg.attunes[key] = def
    elseif cfg.attunes[key] then
        cfg.attunes[key] = nil
    else
        cfg.attunesOff[key] = true
    end
    self:Publish()
    return true
end

function Config:SetWanted(itemID, value, goal)
    if not self:CanEdit() then return nil, "Only officers can change the wanted list." end
    if type(itemID) ~= "number" then return nil, "Shift-click an item, or type its item ID." end
    if value ~= nil and (type(value) ~= "number" or value <= 0) then return nil, "The value must be more than 0 gold." end
    if goal ~= nil and (type(goal) ~= "number" or goal < 0) then return nil, "The goal must be a number (0 removes it)." end
    cfg.wanted[itemID] = value
    if value == nil or goal == 0 then
        cfg.goals[itemID] = nil
    elseif goal then
        local existing = cfg.goals[itemID]
        cfg.goals[itemID] = { n = math.floor(goal), since = existing and existing.since or GetServerTime() }
    end
    self:Publish()
    return true
end

function Config:PrintConfig()
    local wanted = 0
    for _ in pairs(cfg.wanted) do wanted = wanted + 1 end
    AF:Printf("Effort rules v%d: raid cap %d, bank cap %d, honor cap %d, %d gold per bank point, %d wanted items, popup %ds, officers = ranks 0-%d",
        cfg.version, cfg.raidMax, cfg.bankMax, cfg.honorMax, cfg.goldPerPoint, wanted, cfg.responseTimeout, cfg.officerRank)
end
