-------------------------------------------------------------------------------
--  Comm.lua -- addon messages: a small serializer, chunking for the 255-byte
--  limit and a throttled send queue that waits out chat lockdown. The version
--  check lives in Versions.lua.
--
--  Wire format: one header byte then data. "S" = whole message, "F"/"M"/"L" =
--  first/middle/last chunk. The data is Serialize({ kind, payload }).
-------------------------------------------------------------------------------
local _, AF = ...
local Comm = AF:NewModule("Comm")

local CHUNK = 250           -- bytes of data per message (255 minus header, with margin)
local REGEN = 1             -- the game's allowance per prefix: a burst, then 1 message a second
local GIVE_UP = 120         -- seconds a queued message may wait (lockdown) before it is dropped

-- Two lanes, each with its own prefix and allowance. Bulk data (the profession
-- directory) goes on the slow lane, and only while the main lane has nothing
-- waiting, so it never holds up loot, votes or the ledger. Clients that don't
-- know the bulk prefix never see it.
local lanes = {
    main = { prefix = AF.PREFIX, queue = {}, burst = 10 },
    bulk = { prefix = AF.PREFIX_BULK, queue = {}, burst = 3 },
}
for _, lane in pairs(lanes) do lane.tokens, lane.lastRegen = lane.burst, GetTime() end

local handlers = {}
local partial = {}
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

local function TrySend(lane, item)
    if AF:IsChatLocked() then return false end
    local ok, result = pcall(C_ChatInfo.SendAddonMessage, lane.prefix, item.msg, item.channel, item.target)
    if not ok then return false end
    return result == nil or result == true or (Result and result == Result.Success)
end

-- Drops every queued chunk of one message, so a receiver never gets half of it.
local function DropGroup(queue, group)
    for i = #queue, 1, -1 do
        if queue[i].group == group then table.remove(queue, i) end
    end
end

local function Drain(lane, now)
    local queue = lane.queue
    lane.tokens = math.min(lane.burst, lane.tokens + (now - lane.lastRegen) * REGEN)
    lane.lastRegen = now
    while queue[1] and lane.tokens >= 1 do
        local item = queue[1]
        item.queued = item.queued or now     -- bulk items start their clock at the head of the line
        if TrySend(lane, item) then
            table.remove(queue, 1)
            lane.tokens = lane.tokens - 1
        else
            if now - item.queued > GIVE_UP then DropGroup(queue, item.group) end
            break   -- throttled or locked down: try again next tick
        end
    end
end

local function Process()
    local now = GetTime()
    Drain(lanes.main, now)
    if not lanes.main.queue[1] then Drain(lanes.bulk, now) end
    if not lanes.main.queue[1] and not lanes.bulk.queue[1] and ticker then
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
-- bulk = true puts it on the slow lane (large, unhurried data).
function Comm:Send(kind, payload, channel, target, bulk)
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
    local queue = (bulk and lanes.bulk or lanes.main).queue
    local now = not bulk and GetTime() or nil
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
    if AF:IsSecret(prefix) or (prefix ~= AF.PREFIX and prefix ~= AF.PREFIX_BULK) then return end
    if AF:IsSecret(msg) or AF:IsSecret(sender) then return end
    sender = AF:FullName(sender)
    if not sender then return end
    local header, data = msg:sub(1, 1), msg:sub(2)
    local key = sender .. "\001" .. channel .. "\001" .. prefix
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
    C_ChatInfo.RegisterAddonMessagePrefix(AF.PREFIX_BULK)
end
