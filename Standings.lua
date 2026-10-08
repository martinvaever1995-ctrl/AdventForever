-------------------------------------------------------------------------------
--  Standings.lua -- the guild roster and everyone's effort.
--
--  Effort = the last 4 weekly scores (0-100 each, newest first), max 400.
--  Officers work it out from their ledger (Ledger.lua), the real record.
--  Everyone else sees the latest snapshot an officer sent: { t, w, s = { name =
--  "w1,w2,w3,w4" } }, where w is the raid week w1 belongs to. Readers shift a
--  snapshot by the resets since w, so it rolls over at reset like the ledger.
--
--  Officers send a snapshot to the guild after recording something, after their
--  login sync, and when a raider logs in and asks (one officer answers).
-------------------------------------------------------------------------------
local _, AF = ...
local Standings = AF:NewModule("Standings")

local WEEKS = 4
local WEEK_SECONDS = 604800
local SNAPSHOT_DEBOUNCE = 10    -- seconds: several changes in a row = one snapshot
local LOGIN_SNAPSHOT = 45       -- seconds after login an officer sends one (after the ledger sync)
local ANSWER_GAP = 60           -- an officer answers snapshot requests at most this often

Standings.WEEKS = WEEKS
Standings.CATEGORIES = { "raid", "bank", "honor", "dungeon" }
Standings.CATEGORY_TEXT = { raid = "Raids", bank = "Guild bank", honor = "Honor", dungeon = "Dungeons" }

-- The most a week can score: the category caps added up.
function Standings.WeekMax()
    local total = 0
    for _, category in ipairs(Standings.CATEGORIES) do total = total + AF.Config:Get(category .. "Max") end
    return math.max(1, total)
end

local members = {}              -- full name -> { name, classFile, rankIndex, online }

-------------------------------------------------------------------------------
--  Weeks
-------------------------------------------------------------------------------
-- The raid week, numbered by the weekly reset that ends it. Resets happen at a
-- fixed time of the week, so every client gets the same number.
function Standings.CurrentWeek()
    local untilReset = C_DateAndTime.GetSecondsUntilWeeklyReset()
    return math.floor((GetServerTime() + untilReset) / WEEK_SECONDS)
end

-- The raid week a server time falls in.
function Standings.WeekOf(t)
    local now = GetServerTime()
    local nextReset = now + C_DateAndTime.GetSecondsUntilWeeklyReset()
    local weeksBack = math.max(0, math.ceil((nextReset - t) / WEEK_SECONDS) - 1)
    return Standings.CurrentWeek() - weeksBack
end

local function LedgerWeeks(name)
    local current = Standings.CurrentWeek()
    local weeks = {}
    for i = 1, WEEKS do weeks[i] = AF.Ledger:WeekScore(current - i + 1, name) end
    return weeks
end

local function SnapshotWeeks(name)
    local weeks = { 0, 0, 0, 0 }
    local snap = AF.db.snapshot
    local values = snap and snap.s[name]
    if not values then return weeks end
    local stored = { values:match("^(%d+),(%d+),(%d+),(%d+)$") }
    local shift = math.max(0, Standings.CurrentWeek() - snap.w)
    for i = 1, WEEKS do weeks[i] = tonumber(stored[i - shift]) or 0 end
    return weeks
end

-------------------------------------------------------------------------------
--  Detail: the category split per week and this week's raw numbers
--    { split = { [week index] = { raid, bank, honor, dungeon } },
--      now = { here, total, gold, honor, runs } }   (here/total = guild kills)
-------------------------------------------------------------------------------
local function EmptySplit() return { raid = 0, bank = 0, honor = 0, dungeon = 0 } end

local function LedgerDetail(name)
    local current = Standings.CurrentWeek()
    local d = { split = {} }
    for i = 1, WEEKS do
        local b = AF.Ledger:Breakdown(current - i + 1, name) or {}
        d.split[i] = { raid = b.raid or 0, bank = b.bank or 0, honor = b.honor or 0, dungeon = b.dungeon or 0 }
    end
    local here, total = AF.Ledger:RaidAttendance(current, name)
    d.now = { here = here, total = total, gold = AF.Ledger:DepositGold(current, name) or 0,
        honor = AF.Ledger:WeekHonor(current, name) or 0, runs = AF.Ledger:DungeonRuns(current, name) }
    return d
end

-- Snapshot form: "r,b,h,d,... (4 weeks, newest first)|here,total,gold,honor,runs".
-- Snapshots from before dungeons have 3 numbers per week and no runs.
local function EncodeDetail(d)
    local parts = {}
    for i = 1, WEEKS do
        local s = d.split[i]
        table.insert(parts, ("%d,%d,%d,%d"):format(s.raid, s.bank, s.honor, s.dungeon))
    end
    local n = d.now
    return table.concat(parts, ",") .. ("|%d,%d,%d,%d,%d"):format(n.here, n.total, math.floor(n.gold), n.honor, n.runs)
end

local function SnapshotDetail(name)
    local d = { split = {}, now = { here = 0, total = 0, gold = 0, honor = 0, runs = 0 } }
    for i = 1, WEEKS do d.split[i] = EmptySplit() end
    local snap = AF.db.snapshot
    local text = snap and snap.sd and snap.sd[name]
    if not text then return d end
    local splitText, nowText = text:match("^([%d,]+)|([%d,]+)$")
    if not splitText then return d end
    local numbers = {}
    for v in splitText:gmatch("%d+") do table.insert(numbers, tonumber(v)) end
    local per = #numbers >= WEEKS * 4 and 4 or 3
    local shift = math.max(0, Standings.CurrentWeek() - snap.w)
    for i = 1, WEEKS do
        local from = i - shift
        local base = (from - 1) * per
        if from >= 1 and numbers[base + per] then
            d.split[i] = { raid = numbers[base + 1], bank = numbers[base + 2], honor = numbers[base + 3],
                dungeon = per == 4 and numbers[base + 4] or 0 }
        end
    end
    if shift == 0 then   -- this week's raw numbers only mean something in the same week
        local now = {}
        for v in nowText:gmatch("%d+") do table.insert(now, tonumber(v)) end
        if #now >= 4 then
            d.now = { here = now[1], total = now[2], gold = now[3], honor = now[4], runs = now[5] or 0 }
        end
    end
    return d
end

-- A player's split and this week's numbers: from the ledger for officers,
-- from the latest snapshot for everyone else. An alt gives its main's numbers.
function Standings:Detail(name)
    if AF.Ledger:CanRecord() then return LedgerDetail(name) end
    return SnapshotDetail(self:MainOf(name))
end

-- The main a character belongs to (itself if it is one): from the ledger for
-- officers, from the latest snapshot for everyone else.
function Standings:MainOf(name)
    if AF.Ledger:CanRecord() then return AF.Ledger:MainOf(name) end
    local map = AF.db.snapshot and AF.db.snapshot.m
    return map and map[name] or name
end

-- A main's alts, sorted.
function Standings:AltsOf(name)
    local main = self:MainOf(name)
    local alts = {}
    if AF.Ledger:CanRecord() then
        local chars = AF.Ledger:Characters(main)
        for i = 2, #chars do table.insert(alts, chars[i]) end
        return alts, main
    end
    for alt, m in pairs(AF.db.snapshot and AF.db.snapshot.m or {}) do
        if m == main then table.insert(alts, alt) end
    end
    table.sort(alts)
    return alts, main
end

-------------------------------------------------------------------------------
--  Reading
-------------------------------------------------------------------------------
function Standings:Refresh()
    wipe(members)
    for i = 1, GetNumGuildMembers() do
        local name, _, rankIndex, _, _, _, _, _, online, _, classFile = GetGuildRosterInfo(i)
        name = AF:FullName(name)
        if name then
            members[name] = { name = name, classFile = classFile, rankIndex = rankIndex, online = online }
        end
    end
    AF:Fire("STANDINGS_UPDATED")
end

-- Member record with current weeks and effort, or nil if not in the guild.
function Standings:Get(name)
    local m = members[name]
    if not m then return nil end
    m.weeks = AF.Ledger:CanRecord() and LedgerWeeks(name) or SnapshotWeeks(self:MainOf(name))
    m.main = self:MainOf(name)
    m.effort = 0
    for i = 1, WEEKS do m.effort = m.effort + m.weeks[i] end
    return m
end

-- Raw roster (iterate it, then call Get for the numbers).
function Standings:All() return members end

-- Where a raider's numbers come from: officer name and server time, or nil.
function Standings:SnapshotInfo()
    local snap = AF.db.snapshot
    if snap then return snap.by, snap.t end
end

-- How many of an item the guild has deposited toward its goal (nil: no goal).
function Standings:GoalProgress(itemID)
    local goal = AF.Config:Get("goals")[itemID]
    if not goal then return nil end
    if AF.Ledger:CanRecord() then return AF.Ledger:DepositedSince(itemID, goal.since), goal.n end
    local g = AF.db.snapshot and AF.db.snapshot.g
    return g and tonumber(g[itemID]) or 0, goal.n
end

-------------------------------------------------------------------------------
--  Snapshots
-------------------------------------------------------------------------------
local snapshotTimer, answerTimer
local lastSent = 0

-- s = weekly totals per main (every version reads these), sd = the detail and
-- m = { alt = main } (newer versions). Older versions see alts as 0.
local function BuildSnapshot()
    local s, sd = {}, {}
    for _, name in ipairs(AF.Ledger:Players(WEEKS)) do
        if AF.Ledger:MainOf(name) == name then
            local weeks = LedgerWeeks(name)
            local d = LedgerDetail(name)
            if weeks[1] + weeks[2] + weeks[3] + weeks[4] > 0 or d.now.total > 0 or d.now.gold > 0
                or d.now.honor > 0 or d.now.runs > 0 then
                s[name] = table.concat(weeks, ",")
                sd[name] = EncodeDetail(d)
            end
        end
    end
    local g = {}
    for itemID, goal in pairs(AF.Config:Get("goals")) do g[itemID] = AF.Ledger:DepositedSince(itemID, goal.since) end
    return { t = GetServerTime(), w = Standings.CurrentWeek(), s = s, sd = sd, m = AF.Ledger:AltMap(), g = g }
end

local function SendSnapshot()
    snapshotTimer = nil
    if not AF.Ledger:CanRecord() then return end
    if answerTimer then answerTimer:Cancel(); answerTimer = nil end
    lastSent = GetTime()
    AF.Comm:Send("SNAP", BuildSnapshot(), "GUILD")
end

-- Officers call this after changing the ledger; sends once things settle.
function Standings:QueueSnapshot()
    if not AF.Ledger:CanRecord() then return end
    if snapshotTimer then snapshotTimer:Cancel() end
    snapshotTimer = C_Timer.NewTimer(SNAPSHOT_DEBOUNCE, SendSnapshot)
end

local function ValidSnapshot(data)
    if type(data) ~= "table" or type(data.t) ~= "number" or type(data.w) ~= "number" or type(data.s) ~= "table" then
        return false
    end
    for name, values in pairs(data.s) do
        if type(name) ~= "string" or type(values) ~= "string" or not values:match("^%d+,%d+,%d+,%d+$") then return false end
    end
    if data.sd ~= nil then
        if type(data.sd) ~= "table" then return false end
        for name, text in pairs(data.sd) do
            if type(name) ~= "string" or type(text) ~= "string" or not text:match("^[%d,]+|[%d,]+$") then return false end
        end
    end
    if data.m ~= nil then
        if type(data.m) ~= "table" then return false end
        for alt, main in pairs(data.m) do
            if type(alt) ~= "string" or type(main) ~= "string" then return false end
        end
    end
    return true
end

AF.Comm:On("SNAP", function(sender, data)
    if not AF.Config:IsOfficer(sender) or not ValidSnapshot(data) then return end
    if answerTimer and sender ~= AF.playerName then answerTimer:Cancel(); answerTimer = nil end   -- answered
    local current = AF.db.snapshot
    if current and current.t >= data.t then return end
    AF.db.snapshot = { by = sender, t = data.t, w = data.w, s = data.s, sd = data.sd, m = data.m,
        g = type(data.g) == "table" and data.g or nil }
    AF:Fire("STANDINGS_UPDATED")
end)

-- A raider logged in and wants the latest numbers. One officer answers on GUILD
-- (a random wait, cancelled if another answer arrives), which updates everyone.
AF.Comm:On("SNAPQ", function()
    if not AF.Ledger:CanRecord() or GetTime() < AF.Ledger.readyAt then return end
    if answerTimer or snapshotTimer or GetTime() - lastSent < ANSWER_GAP then return end
    answerTimer = C_Timer.NewTimer(1 + math.random() * 5, function()
        answerTimer = nil
        SendSnapshot()
    end)
end)

-------------------------------------------------------------------------------
--  Roster events
-------------------------------------------------------------------------------
AF:RegisterEvent("GUILD_ROSTER_UPDATE", function() Standings:Refresh() end)
AF:RegisterEvent("PLAYER_GUILD_UPDATE", function() AF:RequestRoster() end)

function Standings:Enable()
    AF:RequestRoster()
    -- The roster only refreshes when asked; keep it fresh (this also rolls the window at reset).
    C_Timer.NewTicker(60, function() if IsInGuild() then AF:RequestRoster() end end)
    C_Timer.After(20, function()
        if not AF.Ledger:CanRecord() then AF.Comm:Send("SNAPQ", true, "GUILD") end
    end)
    C_Timer.After(LOGIN_SNAPSHOT, function() Standings:QueueSnapshot() end)
end
