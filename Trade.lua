-------------------------------------------------------------------------------
--  Trade.lua -- items awarded by trade (no master loot), until they're handed over.
--
--  When an item is awarded "by trade" (AWARDED with trade = true), every client
--  in the raid asks: do I have it in my bags and did I loot it recently? The one
--  that does is the holder: it keeps an "owed" trade and tells the raid (HOLD),
--  so the winner and the officers know who has it. The holder's Trades window
--  shows each item owed, the time left of the 2-hour trade window, and whether
--  the winner is in range; opening a trade with the winner puts the item in.
--  When the trade completes, the holder tells the raid (TRADED) and it's done.
--
--  Our own loot is read from "You receive loot" lines (the start of the line is
--  matched, the item link pulled out); a secret line (during an encounter) isn't.
-------------------------------------------------------------------------------
local _, AF = ...
local Trade = AF:NewModule("Trade")

local TRADE_WINDOW = 2 * 3600   -- tradeable for 2 hours after looting
local LOOT_MEMORY = TRADE_WINDOW
local WARN_AT = { 1800, 600 }   -- seconds left when the holder is warned
local DONE_LINGER = 300         -- finished/expired rows stay this long

-------------------------------------------------------------------------------
--  Our own loot
-------------------------------------------------------------------------------
local function LineStart(format)
    if type(format) ~= "string" then return nil end
    local start = format:match("^(.-)%%s")
    return start ~= "" and start or nil
end
local LOOTED = LineStart(LOOT_ITEM_SELF)
local HANDED = LineStart(LOOT_ITEM_PUSHED_SELF)

local function Store()
    AF.db.trade = AF.db.trade or {}
    local mine = AF.db.trade[AF.playerName] or { looted = {}, owe = {}, get = {} }
    AF.db.trade[AF.playerName] = mine
    return mine
end

local function ItemID(link)
    return link and C_Item.GetItemInfoInstant(link)
end

AF:RegisterEvent("CHAT_MSG_LOOT", function(_, text)
    if AF:IsSecret(text) or type(text) ~= "string" or not AF.playerName then return end
    if not ((LOOTED and text:find(LOOTED, 1, true) == 1) or (HANDED and text:find(HANDED, 1, true) == 1)) then return end
    local link = text:match("(|c[^|]*|Hitem:.-|h|r)")
    local id = ItemID(link)
    if not id then return end
    local now = GetServerTime()
    local looted = Store().looted
    table.insert(looted, { id = id, t = now })
    for i = #looted, 1, -1 do
        if now - looted[i].t > LOOT_MEMORY then table.remove(looted, i) end
    end
end)

-- When we looted this item, if we did in the last 2 hours.
local function LootedAt(id)
    local best
    for _, entry in ipairs(Store().looted) do
        if entry.id == id and GetServerTime() - entry.t <= LOOT_MEMORY and (not best or entry.t > best) then best = entry.t end
    end
    return best
end

-- Bag and slot holding the item, or nil.
local function FindInBags(id)
    for bag = 0, (NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4) do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID == id and not info.isLocked then return bag, slot end
        end
    end
end

-------------------------------------------------------------------------------
--  Owed and incoming trades
-------------------------------------------------------------------------------
local function Changed() AF:Fire("TRADES_UPDATED") end

local function Announce(kind, payload)
    if IsInGroup() then AF.Comm:Send(kind, payload, "RAID") end
end

-- An item was awarded by trade.
AF.Comm:On("AWARDED", function(sender, data)
    if type(data) ~= "table" or not data.trade or type(data.sid) ~= "string" or type(data.to) ~= "string" then return end
    if type(data.l) ~= "string" then return end
    local id = ItemID(data.l)
    if not id then return end
    local mine = Store()
    if data.to == AF.playerName then
        table.insert(mine.get, { sid = data.sid, l = data.l, id = id, at = GetServerTime() })
        Changed()
        return
    end
    -- Do we hold it? In our bags, and looted recently (if we could read our loot).
    if not FindInBags(id) then return end
    local lootedAt = LootedAt(id)
    if not lootedAt and LOOTED and #mine.looted > 0 then return end   -- we read loot, and not this one
    for _, owe in ipairs(mine.owe) do
        if owe.sid == data.sid then return end
    end
    table.insert(mine.owe, { sid = data.sid, l = data.l, id = id, to = data.to, lootedAt = lootedAt,
        at = GetServerTime(), warned = {} })
    Announce("HOLD", { sid = data.sid, to = data.to })
    AF:Printf("You have %s: trade it to %s. /af trades", data.l, AF:ShortName(data.to))
    AF.UI:ShowTrades()
    Changed()
end)

-- Someone has the item: the winner learns who, the officers' loot window too.
AF.Comm:On("HOLD", function(sender, data)
    if type(data) ~= "table" or type(data.sid) ~= "string" then return end
    for _, get in ipairs(Store().get) do
        if get.sid == data.sid then get.from = sender end
    end
    AF.Loot:SetTradeState(data.sid, sender, false)
    Changed()
end)

AF.Comm:On("TRADED", function(sender, data)
    if type(data) ~= "table" or type(data.sid) ~= "string" then return end
    local mine = Store()
    local now = GetServerTime()
    for _, list in ipairs({ mine.owe, mine.get }) do
        for _, entry in ipairs(list) do
            if entry.sid == data.sid and not entry.done then entry.done = now end
        end
    end
    AF.Loot:SetTradeState(data.sid, sender, true)
    Changed()
end)

-- Rows for the Trades window: { kind = "owe"|"get", ... , left = seconds or nil }.
function Trade:Rows()
    local mine = Store()
    local now = GetServerTime()
    local rows = {}
    for _, kind in ipairs({ "owe", "get" }) do
        local list = mine[kind]
        for i = #list, 1, -1 do
            local e = list[i]
            local ended = e.done or e.expired
            if ended and now - ended > DONE_LINGER then
                table.remove(list, i)
            else
                local left = e.lootedAt and (e.lootedAt + TRADE_WINDOW - now) or (kind == "get" and (e.at + TRADE_WINDOW - now)) or nil
                table.insert(rows, { kind = kind, entry = e, left = left })
            end
        end
    end
    return rows
end

function Trade:Count()
    local n = 0
    for _, row in ipairs(self:Rows()) do
        if not row.entry.done and not row.entry.expired then n = n + 1 end
    end
    return n
end

-- Opens a trade with the other side of an entry, if they're in range.
function Trade:Open(entry, kind)
    local name = kind == "owe" and entry.to or entry.from
    local unit = name and AF:GroupUnit(name)
    if not unit then return AF:Print("They're not in your group.") end
    if not pcall(InitiateTrade, unit) then
        AF:Printf("Couldn't open the trade. Right-click %s and choose Trade.", AF:ShortName(name))
    end
end

function Trade.InRange(name)
    local unit = name and AF:GroupUnit(name)
    if not unit or type(CheckInteractDistance) ~= "function" then return false end
    local ok, near = pcall(CheckInteractDistance, unit, 2)
    return ok and near and true or false
end

-------------------------------------------------------------------------------
--  The trade window
-------------------------------------------------------------------------------
local partner
local offered = {}      -- item IDs on our side when both accepted

-- Opening a trade with someone we owe puts the item in the first free slot.
AF:RegisterEvent("TRADE_SHOW", function()
    partner = AF:UnitFullName("NPC")
    wipe(offered)
    if not partner then return end
    for _, owe in ipairs(Store().owe) do
        if owe.to == partner and not owe.done and not owe.expired then
            local bag, slot = FindInBags(owe.id)
            if bag and type(ClickTradeButton) == "function" then
                for i = 1, (MAX_TRADABLE_ITEMS or 6) do
                    if not GetTradePlayerItemLink(i) then
                        C_Container.PickupContainerItem(bag, slot)
                        ClickTradeButton(i)
                        ClearCursor()
                        AF:Printf("Put %s in the trade for %s. Check it and accept.", owe.l, AF:ShortName(partner))
                        break
                    end
                end
            end
        end
    end
end)

AF:RegisterEvent("TRADE_ACCEPT_UPDATE", function(_, playerAccepted, targetAccepted)
    if playerAccepted == 1 and targetAccepted == 1 then
        wipe(offered)
        for i = 1, (MAX_TRADABLE_ITEMS or 6) do
            local id = ItemID(GetTradePlayerItemLink(i))
            if id then offered[id] = (offered[id] or 0) + 1 end
        end
    end
end)

-- "Trade complete." Whatever we owed this partner and offered is delivered.
AF:RegisterEvent("UI_INFO_MESSAGE", function(_, _, message)
    if message ~= ERR_TRADE_COMPLETE or not partner then return end
    local now = GetServerTime()
    for _, owe in ipairs(Store().owe) do
        if owe.to == partner and not owe.done and (offered[owe.id] or 0) > 0 then
            offered[owe.id] = offered[owe.id] - 1
            owe.done = now
            Announce("TRADED", { sid = owe.sid, to = owe.to })
            AF:Printf("Delivered %s to %s.", owe.l, AF:ShortName(owe.to))
        end
    end
    wipe(offered)
    Changed()
end)

AF:RegisterEvent("TRADE_CLOSED", function() partner = nil end)

-------------------------------------------------------------------------------
--  Expiry warnings
-------------------------------------------------------------------------------
function Trade:Enable()
    C_Timer.NewTicker(15, function()
        local now = GetServerTime()
        local changed = false
        for _, owe in ipairs(Store().owe) do
            if not owe.done and not owe.expired and owe.lootedAt then
                local left = owe.lootedAt + TRADE_WINDOW - now
                if left <= 0 then
                    owe.expired = now
                    changed = true
                    AF:Printf("|cffff5555The trade window for %s has run out.|r Ask an officer what to do with it.", owe.l)
                else
                    for _, mark in ipairs(WARN_AT) do
                        if left <= mark and not owe.warned[mark] then
                            owe.warned[mark] = true
                            AF:Printf("|cffffd055%d minutes left to trade %s to %s.|r", math.ceil(left / 60), owe.l, AF:ShortName(owe.to))
                        end
                    end
                end
            end
        end
        if changed then Changed() end
    end)
    if self:Count() > 0 then C_Timer.After(10, function() AF.UI:ShowTrades() end) end
end
