-------------------------------------------------------------------------------
--  Dungeons.lua -- dungeon runs with guildies.
--
--  A run counts when a dungeon's final boss dies with at least dungeonGuildMin
--  guild members in the group. Each guild member's client in the group reports
--  it (RUN); officers record the reports (an officer in the group records its
--  own right away), and the ledger groups reports of the same run into one.
--  Reports wait in saved data until an officer confirms them (RUNACK).
--
--  Final bosses: the classic dungeons' are built in below (encounter IDs as the
--  game reports them; several dungeons have one per wing). New Forever dungeons
--  aren't known yet: an officer marks the final boss once with /af final after
--  killing it, which also counts that run. Officers' changes sync as config.
-------------------------------------------------------------------------------
local _, AF = ...
local Dungeons = AF:NewModule("Dungeons")

local RESEND_INTERVAL = 300
local FINAL_WINDOW = 15 * 60    -- /af final can still count a kill this recent

-- encounterID -> "Dungeon: Boss"
local FINALS = {
    [2735] = "Ragefire Chasm: Bazzalan",
    [592]  = "Wailing Caverns: Mutanus the Devourer",
    [2747] = "The Deadmines: Edwin VanCleef",
    [2755] = "Shadowfang Keep: Archmage Arugal",
    [2910] = "Blackfathom Deeps: Aku'mai", [2767] = "Blackfathom Deeps: Aku'mai",
    [2760] = "The Stockade: Bazil Thredd",
    [2772] = "Gnomeregan: Mekgineer Thermaplugg",
    [2778] = "Razorfen Kraul: Charlga Razorflank",
    [2779] = "Scarlet Monastery Graveyard: Bloodmage Thalnos",
    [447]  = "Scarlet Monastery Library: Arcanist Doan",
    [448]  = "Scarlet Monastery Armory: Herod",
    [450]  = "Scarlet Monastery Cathedral: High Inquisitor Whitemane",
    [2785] = "Razorfen Downs: Amnennar the Coldbringer",
    [554]  = "Uldaman: Archaedas",
    [600]  = "Zul'Farrak: Chief Ukorz Sandscalp",
    [429]  = "Maraudon: Princess Theradras",
    [3584] = "Sunken Temple: Shade of Eranikus", [493] = "Sunken Temple: Shade of Eranikus",
    [2790] = "Blackrock Depths: Emperor Dagran Thaurissan",
    [275]  = "Lower Blackrock Spire: Overlord Wyrmthalak",
    [3069] = "Upper Blackrock Spire: General Drakkisath",
    [346]  = "Dire Maul East: Alzzin the Wildshaper",
    [361]  = "Dire Maul West: Prince Tortheldrin",
    [368]  = "Dire Maul North: King Gordok",
    [2801] = "Scholomance: Darkmaster Gandling",
    [478]  = "Stratholme Live: Balnazzar",
    [484]  = "Stratholme Undead: Baron Rivendare",
}

local lastKill      -- the most recent boss kill in a dungeon: { enc, en, map, mn, t, p }

function Dungeons.IsFinal(encounterID)
    return FINALS[encounterID] ~= nil or AF.Config:Get("finals")[encounterID] == true
end

function Dungeons.BuiltInCount()
    local n = 0
    for _ in pairs(FINALS) do n = n + 1 end
    return n
end

local function Pending()
    AF.db.pendingRuns = AF.db.pendingRuns or {}
    return AF.db.pendingRuns
end

-- Guild members in the group now.
local function GuildInGroup()
    local guild = {}
    for _, name in ipairs(AF:GroupMembers()) do
        if AF.Standings:All()[name] then table.insert(guild, name) end
    end
    table.sort(guild)
    return guild
end

function Dungeons:SendPending()
    local mine = {}
    for _, report in ipairs(Pending()) do
        if report.by == AF.playerName then table.insert(mine, report) end
    end
    if #mine > 0 then AF.Comm:Send("RUN", mine, "GUILD") end
end

-- Records (officers) or reports (everyone else) a finished run.
local function Submit(kill)
    if not IsInGuild() or not AF.Standings:All()[AF.playerName] then return end
    local needed = AF.Config:Get("dungeonGuildMin")
    if #kill.p < needed then
        return AF:Printf("%s done, but only %d guild member%s in the group (%d needed for a guild run).",
            kill.mn, #kill.p, #kill.p == 1 and "" or "s", needed)
    end
    if AF.Ledger:CanRecord() then
        if AF.Ledger:RecordRun(kill, AF.playerName) then
            AF:Printf("Guild dungeon run recorded: %s (%d guild members).", kill.mn, #kill.p)
        end
    else
        local report = { enc = kill.enc, en = kill.en, map = kill.map, mn = kill.mn, p = kill.p, t = kill.t,
            by = AF.playerName }
        table.insert(Pending(), report)
        Dungeons:SendPending()
        AF:Printf("Guild dungeon run sent to the officers: %s.", kill.mn)
    end
end

-- ENCOUNTER_END in a 5-player dungeon. Values can be secret during the encounter
-- lockdown; then the kill can't be read (an officer can still use /af final).
AF:RegisterEvent("ENCOUNTER_END", function(_, encounterID, encounterName, _, _, success)
    local _, instanceType = IsInInstance()
    if instanceType ~= "party" then return end
    if AF:IsSecret(encounterID) or AF:IsSecret(success) or (success ~= 1 and success ~= true) then return end
    if AF:IsSecret(encounterName) then encounterName = "Boss " .. encounterID end
    AF:WhenUnrestricted(function()
        local mapName, _, _, _, _, _, _, mapID = GetInstanceInfo()
        lastKill = { enc = encounterID, en = encounterName, map = tonumber(mapID) or 0,
            mn = (not AF:IsSecret(mapName) and mapName) or "Dungeon", t = GetServerTime(), p = GuildInGroup() }
        if Dungeons.IsFinal(encounterID) then Submit(lastKill) end
    end)
end)

-- /af final: an officer marks (or unmarks) the boss just killed as its dungeon's
-- final boss. Marking also counts the run that was just finished.
function Dungeons:ToggleFinal()
    if not AF.Ledger:CanRecord() then return AF:Print("Only officers can mark final bosses.") end
    if not lastKill then return AF:Print("Kill the dungeon's last boss first, then type /af final.") end
    local enc = lastKill.enc
    if FINALS[enc] then return AF:Printf("%s is already a built-in final boss.", lastKill.en) end
    local marking = not AF.Config:Get("finals")[enc]
    local ok, err = AF.Config:SetFinal(enc, marking)
    if not ok then return AF:Print(err) end
    if marking then
        AF:Printf("%s (%s) is now a final boss. Runs that end with it count.", lastKill.en, lastKill.mn)
        if GetServerTime() - lastKill.t <= FINAL_WINDOW then Submit(lastKill) end
    else
        AF:Printf("%s is no longer a final boss.", lastKill.en)
    end
end

-------------------------------------------------------------------------------
--  Officers: reports from the group
-------------------------------------------------------------------------------
local function ValidReport(r, sender)
    if type(r) ~= "table" or r.by ~= sender or type(r.t) ~= "number" or type(r.enc) ~= "number"
        or type(r.map) ~= "number" or type(r.en) ~= "string" or type(r.mn) ~= "string" or type(r.p) ~= "table" then
        return false
    end
    local inRun = false
    for _, name in ipairs(r.p) do
        if type(name) ~= "string" then return false end
        if name == sender then inRun = true end
    end
    return inRun and #r.p >= AF.Config:Get("dungeonGuildMin")
end

AF.Comm:On("RUN", function(sender, list)
    if type(list) ~= "table" or not AF.Ledger:CanRecord() then return end
    local acks = {}
    for _, report in ipairs(list) do
        if ValidReport(report, sender) then
            AF.Ledger:RecordRun(report, sender)
            table.insert(acks, report.t)
        end
    end
    if #acks > 0 then AF.Comm:Send("RUNACK", acks, "WHISPER", sender) end
end)

AF.Comm:On("RUNACK", function(sender, acks)
    if type(acks) ~= "table" or not AF.Config:IsOfficer(sender) then return end
    local done = {}
    for _, t in ipairs(acks) do done[t] = true end
    local pending = Pending()
    for i = #pending, 1, -1 do
        if pending[i].by == AF.playerName and done[pending[i].t] then table.remove(pending, i) end
    end
end)

function Dungeons:Enable()
    C_Timer.After(40, function() Dungeons:SendPending() end)
    C_Timer.NewTicker(RESEND_INTERVAL, function() Dungeons:SendPending() end)
end
