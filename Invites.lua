-------------------------------------------------------------------------------
--  Invites.lua -- raid invites: everyone online at the chosen guild ranks (and
--  minimum effort) with one click, and guild members who whisper a keyword.
--
--  A party holds 5, so from solo we invite 4, turn the party into a raid as soon
--  as someone joins, then invite the rest. Settings are per character
--  (AF.db.prefs.invite); whisper invites stay off until switched on each session.
-------------------------------------------------------------------------------
local _, AF = ...
local Invites = AF:NewModule("Invites")

local QUEUE_LIFETIME = 90       -- seconds queued invites wait for the raid to form
local queue, queuedAt = {}, 0
local listening = false

function Invites:Prefs()
    AF.db.prefs = AF.db.prefs or {}
    local p = AF.db.prefs.invite
    if type(p) ~= "table" then
        p = {}
        AF.db.prefs.invite = p
    end
    if type(p.ranks) ~= "table" then p.ranks = {} end
    if type(p.minEffort) ~= "number" then p.minEffort = 0 end
    if type(p.keyword) ~= "string" or p.keyword == "" then p.keyword = "inv" end
    return p
end

-- Guild ranks: { { index (0 = GM), name }, ... }.
function Invites:Ranks()
    local out = {}
    for i = 1, (GuildControlGetNumRanks and GuildControlGetNumRanks()) or 0 do
        table.insert(out, { index = i - 1, name = GuildControlGetRankName(i) or ("Rank " .. i) })
    end
    return out
end

local function InGroup(name)
    return AF:GroupUnit(name) ~= nil
end

-- Online guild members who match the settings and aren't in our group, by name.
-- No rank ticked means every rank.
function Invites:Matching()
    local p = self:Prefs()
    local anyRank = next(p.ranks) == nil
    local out = {}
    for name, m in pairs(AF.Standings:All()) do
        if m.online and name ~= AF.playerName and (anyRank or p.ranks[m.rankIndex]) and not InGroup(name) then
            local member = p.minEffort > 0 and AF.Standings:Get(name)
            if p.minEffort <= 0 or (member and member.effort >= p.minEffort) then table.insert(out, name) end
        end
    end
    table.sort(out)
    return out
end

-------------------------------------------------------------------------------
--  Sending invites
-------------------------------------------------------------------------------
local function CanInvite()
    return not IsInGroup() or UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")
end

local function Invite(name)
    local fn = (C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
    return fn and pcall(fn, name)
end

local function ConvertToRaidNow()
    local fn = (C_PartyInfo and C_PartyInfo.ConvertToRaid) or ConvertToRaid
    if fn then pcall(fn) end
end

-- Sends what the group has room for; the rest waits for the raid.
local function Process()
    if not queue[1] then return end
    if GetTime() - queuedAt > QUEUE_LIFETIME then
        AF:Printf("%d invites dropped: the raid didn't form in time.", #queue)
        return wipe(queue)
    end
    if IsInRaid() then
        for _, name in ipairs(queue) do
            if not InGroup(name) then Invite(name) end
        end
        return wipe(queue)
    end
    if IsInGroup() then
        if UnitIsGroupLeader("player") then ConvertToRaidNow() end   -- the roster update brings us back here
        return
    end
    -- Solo: a party has room for 4. The first to join lets us make it a raid.
    for _ = 1, math.min(4, #queue) do Invite(table.remove(queue, 1)) end
end

AF:RegisterEvent("GROUP_ROSTER_UPDATE", function() C_Timer.After(0.5, Process) end)

-- Invites everyone matching the settings. Returns how many.
function Invites:InviteMatching()
    if not CanInvite() then
        AF:Print("Only the group leader or an assistant can invite.")
        return 0
    end
    local names = self:Matching()
    if #names == 0 then
        AF:Print("Nobody online matches.")
        return 0
    end
    wipe(queue)
    for _, name in ipairs(names) do table.insert(queue, name) end
    queuedAt = GetTime()
    AF:Printf("Inviting %d guild members...", #names)
    Process()
    return #names
end

-------------------------------------------------------------------------------
--  Whisper invites
-------------------------------------------------------------------------------
function Invites:Listening() return listening end

function Invites:SetListening(on)
    listening = on and true or false
    if listening then
        AF:Printf("Guild members who whisper you \"%s\" get a raid invite (until you turn it off or log out).",
            self:Prefs().keyword)
    end
end

AF:RegisterEvent("CHAT_MSG_WHISPER", function(_, text, sender)
    if not listening or AF:IsSecret(text) or AF:IsSecret(sender) or type(text) ~= "string" then return end
    if text:lower():match("^%s*(.-)%s*$") ~= Invites:Prefs().keyword:lower() then return end
    local name = AF:FullName(sender)
    if not name or not AF.Standings:All()[name] or InGroup(name) then return end
    if not CanInvite() then return end
    if IsInRaid() or not IsInGroup() or GetNumSubgroupMembers() < 4 then
        Invite(name)
    else
        table.insert(queue, name)       -- party full: after the raid forms
        queuedAt = GetTime()
        Process()
    end
end)
