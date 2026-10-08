-------------------------------------------------------------------------------
--  Attendance.lua -- guild boss kills and who was there.
--
--  A boss kill in a raid is a guild kill when at least guildKillShare % of the
--  raid are guild members. Every officer in the raid records it, and so does an
--  officer receiving the report a non-officer raid leader sends. All of them
--  derive the same id ("kill:<boss>:<difficulty>:<leader>#<week>"), so the kill
--  counts once. Reports wait in saved data until an officer confirms them.
--
--  Each officer who records a kill also gives credit to the players on their
--  bench list (/af bench), as if they had been there.
--
--  Raid score = raidMax x (guild kills present for / guild kills that week).
-------------------------------------------------------------------------------
local _, AF = ...
local Attendance = AF:NewModule("Attendance")

local RESEND_INTERVAL = 300

local function Pending()
    AF.db.pendingKills = AF.db.pendingKills or {}
    return AF.db.pendingKills
end

local function GroupLeader()
    if not IsInGroup() then return AF.playerName end
    if UnitIsGroupLeader("player") then return AF.playerName end
    local prefix, count = "party", GetNumSubgroupMembers()
    if IsInRaid() then prefix, count = "raid", GetNumGroupMembers() end
    for i = 1, count do
        if UnitIsGroupLeader(prefix .. i) then return AF:UnitFullName(prefix .. i) end
    end
    return AF.playerName
end

-- The kill as everyone in the group would report it, or nil plus why it isn't a guild kill.
local function BuildReport(encounterID, bossName, difficulty)
    local members = AF:GroupMembers()
    local guild = {}
    for _, name in ipairs(members) do
        if AF.Standings:All()[name] then table.insert(guild, name) end
    end
    table.sort(guild)
    local share = #members > 0 and (#guild / #members * 100) or 0
    if share < AF.Config:Get("guildKillShare") then
        return nil, ("%s isn't a guild kill: %d of %d in the raid are guild members (%d%% needed)."):format(
            bossName, #guild, #members, AF.Config:Get("guildKillShare"))
    end
    local t = GetServerTime()
    local boss = encounterID ~= 0 and tostring(encounterID) or bossName
    return {
        enc = encounterID, en = bossName, d = difficulty or 0, p = guild, size = #members, t = t,
        o = ("kill:%s:%d:%s"):format(boss, difficulty or 0, GroupLeader()),
        s = AF.Standings.WeekOf(t),
    }
end

-- Officers: records a kill and bench credit from our bench list.
function Attendance:Record(report)
    local kill = AF.Ledger:RecordKill(report)
    local killId = report.o .. "#" .. report.s
    local benched = {}
    for name in pairs(AF.db.bench) do
        if AF.Ledger:RecordBench(killId, name, report.s) then table.insert(benched, AF:ShortName(name)) end
    end
    if kill then
        AF:Printf("Guild kill recorded: %s (%d guild members of %d).", report.en, #report.p, report.size)
    end
    if #benched > 0 then
        AF:Printf("Bench credit for %s: %s", report.en, table.concat(benched, ", "))
    end
end

function Attendance:SendPending()
    if #Pending() > 0 then AF.Comm:Send("KILL", Pending(), "GUILD") end
end

function Attendance:Submit(report)
    if AF.Ledger:CanRecord() then
        self:Record(report)
    else
        table.insert(Pending(), report)
        self:SendPending()
        AF:Printf("Guild kill sent to the officers: %s.", report.en)
    end
end

-- A boss died: officers record it, a raid leader who isn't an officer reports it.
local function OnKill(encounterID, bossName, difficulty)
    if not IsInRaid() then return end
    local officer = AF.Ledger:CanRecord()
    if not officer and not UnitIsGroupLeader("player") then return end
    local report, why = BuildReport(encounterID, bossName, difficulty)
    if not report then return AF:Print(why) end
    Attendance:Submit(report)
end

-- ENCOUNTER_END: encounterID, encounterName, difficultyID, groupSize, success.
-- On Forever these can be secret during the encounter lockdown; if so we can't
-- tell a kill from a wipe, and an officer records it with /af kill.
AF:RegisterEvent("ENCOUNTER_END", function(_, encounterID, encounterName, difficultyID, _, success)
    if AF:IsSecret(encounterID) or AF:IsSecret(success) or AF:IsSecret(difficultyID) then
        if IsInRaid() and (AF.Ledger:CanRecord() or UnitIsGroupLeader("player")) then
            AF:Print("Couldn't read the encounter result (game restriction). If it was a kill: /af kill <boss name>")
        end
        return
    end
    if success ~= 1 and success ~= true then return end
    if AF:IsSecret(encounterName) then encounterName = "Boss " .. encounterID end
    -- Raid roster names can be hidden until the lockdown lifts.
    AF:WhenUnrestricted(function() OnKill(encounterID, encounterName, difficultyID) end)
end)

-- /af kill <boss>: an officer records a kill for the current group by hand.
function Attendance:Manual(bossName)
    if not AF.Ledger:CanRecord() then return AF:Print("Only officers can record kills by hand.") end
    if bossName == "" then return AF:Print("Usage: /af kill <boss name>") end
    local report, why = BuildReport(0, bossName, 0)
    if not report then return AF:Print(why) end
    self:Record(report)
end

-------------------------------------------------------------------------------
--  Officers: reports from raid leaders
-------------------------------------------------------------------------------
local function ValidReport(r)
    if type(r) ~= "table" or type(r.o) ~= "string" or not r.o:find("^kill:") or type(r.s) ~= "number" then return false end
    if type(r.enc) ~= "number" or type(r.en) ~= "string" or type(r.t) ~= "number" or type(r.size) ~= "number" then return false end
    if type(r.p) ~= "table" then return false end
    for _, name in ipairs(r.p) do
        if type(name) ~= "string" then return false end
    end
    return true
end

AF.Comm:On("KILL", function(sender, list)
    if type(list) ~= "table" or not AF.Ledger:CanRecord() or not AF.Standings:All()[sender] then return end
    local acks = {}
    for _, report in ipairs(list) do
        if ValidReport(report) then
            Attendance:Record(report)
            table.insert(acks, report.o .. "#" .. report.s)
        end
    end
    if #acks > 0 then AF.Comm:Send("KILLACK", acks, "WHISPER", sender) end
end)

AF.Comm:On("KILLACK", function(sender, acks)
    if type(acks) ~= "table" or not AF.Config:IsOfficer(sender) then return end
    local done = {}
    for _, id in ipairs(acks) do done[id] = true end
    local pending = Pending()
    for i = #pending, 1, -1 do
        if done[pending[i].o .. "#" .. pending[i].s] then table.remove(pending, i) end
    end
end)

function Attendance:Enable()
    C_Timer.After(35, function() Attendance:SendPending() end)
    C_Timer.NewTicker(RESEND_INTERVAL, function() Attendance:SendPending() end)
end
