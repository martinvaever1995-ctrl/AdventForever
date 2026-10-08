-------------------------------------------------------------------------------
--  Recruit.lua -- guildless players who run the addon, so the guild can invite them.
--
--  A hidden realm chat channel connects them:
--    - guildless players join it and say hello (HI) every few minutes, and to
--      any group they join
--    - guild members whose rank can invite join it, ask who's there (WHO) and
--      keep a list of who answered
--  Ordinary guild members don't join, so it costs them no chat channel slot.
--  The channel is removed from every chat window and its join/leave notices are
--  filtered out. Everything here is guarded: if this client can't join custom
--  channels, the group part still works and /af debug says so.
-------------------------------------------------------------------------------
local _, AF = ...
local Recruit = AF:NewModule("Recruit")

local CHANNEL = "AdvForeverNet"
local PASSWORD = "afnet"
local HELLO_INTERVAL = 600      -- seconds between a guildless player's hellos
local ONLINE_WINDOW = 720       -- seen this recently = online
local FORGET_AFTER = 14 * 86400 -- drop players not seen for this long

local joined = false
local channelId
local role                      -- "recruit" (guildless) or "inviter", or nil

local function List()
    AF.db.recruits = AF.db.recruits or {}
    return AF.db.recruits
end

-------------------------------------------------------------------------------
--  Who we are
-------------------------------------------------------------------------------
local function CanInvite()
    if C_GuildInfo and C_GuildInfo.CanGuildInvite then return C_GuildInfo.CanGuildInvite() and true or false end
    return CanGuildInvite and CanGuildInvite() and true or false
end

local function WantedRole()
    if not IsInGuild() then return "recruit" end
    if CanInvite() then return "inviter" end
    return nil
end

local function Hello()
    local _, classFile = UnitClass("player")
    return { lvl = UnitLevel("player"), c = classFile }
end

-------------------------------------------------------------------------------
--  The hidden channel
-------------------------------------------------------------------------------
local function HideChannel()
    if type(ChatFrame_RemoveChannel) ~= "function" then return end
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local frame = _G["ChatFrame" .. i]
        if frame then pcall(ChatFrame_RemoveChannel, frame, CHANNEL) end
    end
end

-- "Joined Channel: AdvForeverNet" and friends stay out of chat.
local function NoticeFilter(_, _, _, _, _, _, _, _, _, _, channelName)
    if type(channelName) == "string" and channelName:lower() == CHANNEL:lower() then return true end
    return false
end

local function ChannelId()
    local id = GetChannelName(CHANNEL)
    return (type(id) == "number" and id > 0) and id or nil
end

local function Send(kind, payload)
    channelId = ChannelId()
    if channelId then AF.Comm:Send(kind, payload, "CHANNEL", channelId) end
end

local function Join()
    if joined or type(JoinTemporaryChannel) ~= "function" then return end
    joined = true
    pcall(JoinTemporaryChannel, CHANNEL, PASSWORD)
    -- The channel id appears a moment later.
    C_Timer.After(3, function()
        HideChannel()
        channelId = ChannelId()
        if not channelId then return end
        if role == "inviter" then Send("WHO", true) else Send("HI", Hello()) end
    end)
end

local function Leave()
    if not joined then return end
    joined, channelId = false, nil
    if type(LeaveChannelByName) == "function" then pcall(LeaveChannelByName, CHANNEL) end
end

-- Joins or leaves as our situation changes (joined a guild, got invite rights).
function Recruit:Update()
    role = WantedRole()
    if role then Join() else Leave() end
end

-------------------------------------------------------------------------------
--  Messages
-------------------------------------------------------------------------------
local function Note(sender, data, source)
    if role ~= "inviter" or type(data) ~= "table" then return end
    if sender == AF.playerName or AF.Standings:All()[sender] then return end
    local list = List()
    local known = list[sender]
    local fresh = not known or GetServerTime() - known.seen > 86400
    list[sender] = { lvl = tonumber(data.lvl) or 0, c = type(data.c) == "string" and data.c or nil,
        seen = GetServerTime(), src = source }
    if fresh then
        local className = data.c and LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[data.c] or ""
        AF:Printf("Recruit: %s (level %d %s) has AdventForever and no guild. /af recruit to invite.",
            AF:ShortName(sender), list[sender].lvl, className)
    end
    AF:Fire("RECRUITS_UPDATED")
end

AF.Comm:On("HI", function(sender, data, channel)
    Note(sender, data, channel == "CHANNEL" and "realm" or "group")
end)

-- An inviter asked who's out there: guildless players answer by whisper.
AF.Comm:On("WHO", function(sender)
    if role == "recruit" then AF.Comm:Send("HI", Hello(), "WHISPER", sender) end
end)

-------------------------------------------------------------------------------
--  Inviting
-------------------------------------------------------------------------------
function Recruit:Invite(name)
    if not CanInvite() then return AF:Print("Your guild rank can't invite.") end
    local invite = (C_GuildInfo and C_GuildInfo.Invite) or GuildInvite
    if type(invite) ~= "function" then return AF:Print("This client has no guild invite function.") end
    invite(name)
    AF:Printf("Guild invite sent to %s.", AF:ShortName(name))
end

function Recruit:Forget(name)
    List()[name] = nil
    AF:Fire("RECRUITS_UPDATED")
end

-- The list for the Recruit tab, online first, then most recently seen.
function Recruit:Entries()
    local now = GetServerTime()
    local out = {}
    for name, r in pairs(List()) do
        table.insert(out, { name = name, lvl = r.lvl, c = r.c, seen = r.seen, src = r.src,
            online = now - r.seen <= ONLINE_WINDOW })
    end
    table.sort(out, function(a, b)
        if a.online ~= b.online then return a.online end
        return a.seen > b.seen
    end)
    return out
end

function Recruit:CanInvite() return CanInvite() end

-- For /af debug.
function Recruit.Status()
    return role or "none", joined and (channelId and ("joined, id " .. channelId) or "joining") or "not joined",
        type(JoinTemporaryChannel) == "function",
        type((C_GuildInfo and C_GuildInfo.Invite) or GuildInvite) == "function"
end

-------------------------------------------------------------------------------
--  Events
-------------------------------------------------------------------------------
-- Players who joined the guild leave the list.
AF:On("STANDINGS_UPDATED", function()
    local list, changed = List(), false
    for name in pairs(list) do
        if AF.Standings:All()[name] then list[name] = nil; changed = true end
    end
    if changed then AF:Fire("RECRUITS_UPDATED") end
end)

-- Guildless players say hello to groups they join, too.
local wasGrouped = false
AF:RegisterEvent("GROUP_ROSTER_UPDATE", function()
    local grouped = IsInGroup()
    if grouped and not wasGrouped and role == "recruit" then
        C_Timer.After(2, function() AF.Comm:Send("HI", Hello(), "RAID") end)
    end
    wasGrouped = grouped
end)

AF:RegisterEvent("PLAYER_GUILD_UPDATE", function() C_Timer.After(2, function() Recruit:Update() end) end)

function Recruit:Enable()
    if type(ChatFrame_AddMessageEventFilter) == "function" then
        ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL_NOTICE", NoticeFilter)
        ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL_NOTICE_USER", NoticeFilter)
    end
    local now, list = GetServerTime(), List()
    for name, r in pairs(list) do
        if now - (r.seen or 0) > FORGET_AFTER then list[name] = nil end
    end
    -- Wait for the guild roster (and rank permissions) before deciding.
    C_Timer.After(20, function() Recruit:Update() end)
    C_Timer.NewTicker(HELLO_INTERVAL, function()
        Recruit:Update()
        if role == "recruit" then Send("HI", Hello()) end
    end)
end
