-------------------------------------------------------------------------------
--  Comm.lua -- addon messages: a small serializer, chunking for the 255-byte
--  limit, a throttled send queue that waits out chat lockdown, and the version
--  check.
--
--  Wire format: one header byte then data. "S" = whole message, "F"/"M"/"L" =
--  first/middle/last chunk. The data is Serialize({ kind, payload }).
-------------------------------------------------------------------------------
local _, AF = ...
local Comm = AF:NewModule("Comm")

local CHUNK = 250           -- bytes of data per message (255 minus header, with margin)
local BURST, REGEN = 10, 1  -- per-prefix allowance: 10 messages, 1 more per second
local GIVE_UP = 120         -- seconds a queued message may wait (lockdown) before it is dropped

local handlers = {}
local queue = {}
local partial = {}
local tokens, lastRegen = BURST, GetTime()
local nextGroup = 0
local ticker

-------------------------------------------------------------------------------
--  Serializer: strings are length-prefixed, so any byte is safe in them.
-------------------------------------------------------------------------------
local function Write(v, out)
    local t = type(v)
    if t == "string" then
        out[#out + 1] = "s" .. #v .. ":" .. v
    elseif t == "number" then
        out[#out + 1] = "n" .. tostring(v) .. ";"
    elseif t == "boolean" then
        out[#out + 1] = v and "T" or "F"
    elseif t == "table" then
        out[#out + 1] = "{"
        for k, val in pairs(v) do
            Write(k, out)
            Write(val, out)
        end
        out[#out + 1] = "}"
    else
        error("AdventForever: cannot serialize a " .. t)
    end
end

local function Read(s, i)
    local c = s:sub(i, i)
    if c == "s" then
        local colon = s:find(":", i + 1, true)
        local len = tonumber(s:sub(i + 1, colon - 1))
        return s:sub(colon + 1, colon + len), colon + len + 1
    elseif c == "n" then
        local semi = s:find(";", i + 1, true)
        return tonumber(s:sub(i + 1, semi - 1)), semi + 1
    elseif c == "T" then
        return true, i + 1
    elseif c == "F" then
        return false, i + 1
    elseif c == "{" then
        local tbl = {}
        i = i + 1
        while s:sub(i, i) ~= "}" do
            local k, v
            k, i = Read(s, i)
            v, i = Read(s, i)
            if k == nil then error("nil key") end
            tbl[k] = v
        end
        return tbl, i + 1
    end
    error("bad data")
end

function Comm.Serialize(v)
    local out = {}
    Write(v, out)
    return table.concat(out)
end

function Comm.Deserialize(s)
    local ok, v = pcall(Read, s, 1)
    if ok then return v end
end

-------------------------------------------------------------------------------
--  Sending
-------------------------------------------------------------------------------
local Result = Enum.SendAddonMessageResult

local function TrySend(item)
    if AF:IsChatLocked() then return false end
    local ok, result = pcall(C_ChatInfo.SendAddonMessage, AF.PREFIX, item.msg, item.channel, item.target)
    if not ok then return false end
    return result == nil or result == true or (Result and result == Result.Success)
end

-- Drops every queued chunk of one message, so a receiver never gets half of it.
local function DropGroup(group)
    for i = #queue, 1, -1 do
        if queue[i].group == group then table.remove(queue, i) end
    end
end

local function Process()
    local now = GetTime()
    tokens = math.min(BURST, tokens + (now - lastRegen) * REGEN)
    lastRegen = now
    while queue[1] and tokens >= 1 do
        local item = queue[1]
        if TrySend(item) then
            table.remove(queue, 1)
            tokens = tokens - 1
        else
            if now - item.queued > GIVE_UP then DropGroup(item.group) end
            break   -- throttled or locked down: try again next tick
        end
    end
    if not queue[1] and ticker then
        ticker:Cancel()
        ticker = nil
    end
end

local function Dispatch(sender, data, channel)
    local decoded = Comm.Deserialize(data)
    if type(decoded) ~= "table" or type(decoded[1]) ~= "string" then return end
    for _, fn in ipairs(handlers[decoded[1]] or {}) do
        local ok, err = pcall(fn, sender, decoded[2], channel)
        if not ok then geterrorhandler()(err) end
    end
end

-- Sends { kind, payload } on GUILD, RAID, PARTY or WHISPER (target = full name).
function Comm:Send(kind, payload, channel, target)
    if channel == "RAID" and not IsInRaid() then
        if not IsInGroup() then return end
        channel = "PARTY"
    end
    if channel == "GUILD" and not IsInGuild() then return end
    local data = Comm.Serialize({ kind, payload })
    if channel == "WHISPER" and target == AF.playerName then
        return Dispatch(target, data, channel)   -- talking to ourselves: skip the wire
    end

    nextGroup = nextGroup + 1
    local now = GetTime()
    local function Add(msg)
        table.insert(queue, { msg = msg, channel = channel, target = target, group = nextGroup, queued = now })
    end
    if #data <= CHUNK then
        Add("S" .. data)
    else
        local pos = 1
        while pos <= #data do
            local piece = data:sub(pos, pos + CHUNK - 1)
            local header = pos == 1 and "F" or (pos + CHUNK > #data and "L" or "M")
            Add(header .. piece)
            pos = pos + CHUNK
        end
    end
    if not ticker then ticker = C_Timer.NewTicker(0.1, Process) end
    Process()
end

-- fn(sender, payload, channel); sender is "Name-Realm".
function Comm:On(kind, fn)
    handlers[kind] = handlers[kind] or {}
    table.insert(handlers[kind], fn)
end

-------------------------------------------------------------------------------
--  Receiving
-------------------------------------------------------------------------------
AF:RegisterEvent("CHAT_MSG_ADDON", function(_, prefix, msg, channel, sender)
    if AF:IsSecret(prefix) or prefix ~= AF.PREFIX then return end
    if AF:IsSecret(msg) or AF:IsSecret(sender) then return end
    sender = AF:FullName(sender)
    if not sender then return end
    local header, data = msg:sub(1, 1), msg:sub(2)
    local key = sender .. "\001" .. channel
    if header == "S" then
        Dispatch(sender, data, channel)
    elseif header == "F" then
        partial[key] = { data }
    elseif header == "M" then
        if partial[key] then table.insert(partial[key], data) end
    elseif header == "L" then
        local parts = partial[key]
        partial[key] = nil
        if parts then
            table.insert(parts, data)
            Dispatch(sender, table.concat(parts), channel)
        end
    end
end)

function Comm:Init()
    C_ChatInfo.RegisterAddonMessagePrefix(AF.PREFIX)
end

-------------------------------------------------------------------------------
--  Version check
-------------------------------------------------------------------------------
local versions = {}         -- full name -> version number
local warned = false
local replied = {}
local wasInRaid = false

local function VersionString(v)
    return ("%d.%d.%d"):format(math.floor(v / 10000), math.floor(v / 100) % 100, v % 100)
end

Comm:On("VER", function(sender, version, channel)
    if type(version) ~= "number" or sender == AF.playerName then return end
    versions[sender] = version
    if version > AF.VERSION and not warned then
        warned = true
        AF:Printf("|cffff5555A newer version (%s) is out; you have %s. Please update.|r",
            VersionString(version), AF.VERSION_STRING)
    elseif version < AF.VERSION and channel ~= "WHISPER" and AF.Ledger:CanRecord() and not replied[sender] then
        -- Officers tell outdated players directly, once per session.
        replied[sender] = true
        Comm:Send("VER", AF.VERSION, "WHISPER", sender)
    end
end)

Comm:On("VERQ", function(sender)
    Comm:Send("VER", AF.VERSION, "WHISPER", sender)
end)

function Comm:QueryVersions()
    if not IsInGroup() then return AF:Print("You are not in a group.") end
    Comm:Send("VERQ", true, "RAID")
    AF:Print("Asking the group for versions...")
    C_Timer.After(4, function()
        local outdated, missing = {}, {}
        for _, name in ipairs(AF:GroupMembers()) do
            local v = name == AF.playerName and AF.VERSION or versions[name]
            if not v then
                table.insert(missing, AF:ShortName(name))
            elseif v < AF.VERSION then
                table.insert(outdated, ("%s (%s)"):format(AF:ShortName(name), VersionString(v)))
            end
        end
        AF:Printf("Outdated: %s", #outdated > 0 and table.concat(outdated, ", ") or "none")
        AF:Printf("Not installed / no answer: %s", #missing > 0 and table.concat(missing, ", ") or "none")
    end)
end

function Comm:Enable()
    C_Timer.After(10, function() Comm:Send("VER", AF.VERSION, "GUILD") end)
    wasInRaid = IsInRaid()
end

AF:RegisterEvent("GROUP_ROSTER_UPDATE", function()
    local inRaid = IsInRaid()
    if inRaid and not wasInRaid then
        C_Timer.After(3, function() Comm:Send("VER", AF.VERSION, "RAID") end)
    end
    wasInRaid = inRaid
end)
