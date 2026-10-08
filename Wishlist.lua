-------------------------------------------------------------------------------
--  Wishlist.lua -- each character ranks up to 10 items it wants. Officers see the
--  lists (in the Wishlist tab, item tooltips and the loot window); nobody else does.
--
--  Lists live in AF.db.wishes = { [character] = { t = server time, i = { itemID, ... } } }.
--  On a raider's client that's the characters of this account; on an officer's
--  client it's everyone's, as last heard. A list is replaced as a whole by a
--  newer one (by t).
--
--  WISH { [character] = list } whispers lists to an officer: after you change
--  yours (to every officer online), after login, and in answer to WISHQ, which
--  an officer sends to the guild after logging in. Officers answer WISHQ from
--  another officer with everything they have, which keeps officers in step.
--  Loot responses carry your rank for the item too (Loot.lua), so the loot
--  window has it even when the lists haven't arrived.
-------------------------------------------------------------------------------
local _, AF = ...
local Wishlist = AF:NewModule("Wishlist")

Wishlist.MAX = 10
local SEND_DELAY = 3            -- seconds of quiet after an edit before sending
local LOGIN_DELAY = 25          -- after login: send ours / ask for everyone's

local sendTimer
local index                     -- itemID -> { { name, rank }, ... } (rebuilt on change)

local function Store()
    AF.db.wishes = AF.db.wishes or {}
    return AF.db.wishes
end

function Wishlist.ItemID(linkOrID)
    if type(linkOrID) == "number" then return linkOrID end
    if type(linkOrID) ~= "string" then return nil end
    local id = linkOrID:find("item:", 1, true) and C_Item.GetItemInfoInstant(linkOrID)
    return id or tonumber(linkOrID)
end

local function Changed()
    index = nil
    AF:Fire("WISHLIST_UPDATED")
end

-------------------------------------------------------------------------------
--  Our own list
-------------------------------------------------------------------------------
-- Item IDs on this character's list, most wanted first.
function Wishlist:Mine()
    local list = AF.playerName and Store()[AF.playerName]
    return list and list.i or {}
end

-- Rank of an item on this character's list (nil if not on it).
function Wishlist:MyRank(linkOrID)
    local id = Wishlist.ItemID(linkOrID)
    for rank, wanted in ipairs(self:Mine()) do
        if wanted == id then return rank end
    end
end

local function Officers()
    local out = {}
    for name, m in pairs(AF.Standings:All()) do
        if m.online and name ~= AF.playerName and AF.Config:IsOfficer(name) then table.insert(out, name) end
    end
    return out
end

-- Whispers this account's lists to every officer online.
local function SendMine()
    sendTimer = nil
    local mine = {}
    for name, list in pairs(Store()) do
        if name == AF.playerName or not AF.Ledger:CanRecord() then mine[name] = list end
    end
    if not next(mine) then return end
    for _, officer in ipairs(Officers()) do AF.Comm:Send("WISH", mine, "WHISPER", officer) end
end

local function Save(items)
    Store()[AF.playerName] = { t = GetServerTime(), i = items }
    Changed()
    if sendTimer then sendTimer:Cancel() end
    sendTimer = C_Timer.NewTimer(SEND_DELAY, SendMine)
end

function Wishlist:Add(linkOrID)
    local id = Wishlist.ItemID(linkOrID)
    if not id then return nil, "Shift-click an item into the box (or type its item ID)." end
    local items = { unpack(self:Mine()) }
    for _, wanted in ipairs(items) do
        if wanted == id then return nil, "That item is already on your wishlist." end
    end
    if #items >= Wishlist.MAX then
        return nil, ("Your wishlist is full (%d items). Remove one first."):format(Wishlist.MAX)
    end
    table.insert(items, id)
    Save(items)
    return #items
end

function Wishlist:Remove(id)
    local items = {}
    for _, wanted in ipairs(self:Mine()) do
        if wanted ~= id then table.insert(items, wanted) end
    end
    Save(items)
end

-- Moves an item up (-1) or down (+1) one place.
function Wishlist:Move(id, step)
    local items = { unpack(self:Mine()) }
    for rank, wanted in ipairs(items) do
        if wanted == id then
            local other = rank + step
            if other < 1 or other > #items then return end
            items[rank], items[other] = items[other], items[rank]
            return Save(items)
        end
    end
end

-------------------------------------------------------------------------------
--  Everyone's lists (officers)
-------------------------------------------------------------------------------
local function BuildIndex()
    index = {}
    for name, list in pairs(Store()) do
        for rank, id in ipairs(list.i or {}) do
            index[id] = index[id] or {}
            table.insert(index[id], { name = name, rank = rank })
        end
    end
    for _, wishers in pairs(index) do
        table.sort(wishers, function(a, b)
            if a.rank ~= b.rank then return a.rank < b.rank end
            return a.name < b.name
        end)
    end
end

-- Who has this item on their list: { { name, rank }, ... }, best rank first.
-- Officers see everyone they've heard from; others only this account's characters.
function Wishlist:Wishers(linkOrID)
    local id = Wishlist.ItemID(linkOrID)
    if not id then return {} end
    if not index then BuildIndex() end
    return index[id] or {}
end

-- A player's rank for an item (nil if it isn't on their list).
function Wishlist:RankOf(name, linkOrID)
    for _, w in ipairs(self:Wishers(linkOrID)) do
        if w.name == name then return w.rank end
    end
end

-- Every wished-for item: { { id, wishers = { { name, rank }, ... } }, ... }, most wishers first.
function Wishlist:ByItem()
    if not index then BuildIndex() end
    local out = {}
    for id, wishers in pairs(index) do table.insert(out, { id = id, wishers = wishers }) end
    table.sort(out, function(a, b)
        if #a.wishers ~= #b.wishers then return #a.wishers > #b.wishers end
        if a.wishers[1].rank ~= b.wishers[1].rank then return a.wishers[1].rank < b.wishers[1].rank end
        return a.id < b.id
    end)
    return out
end

-- How many players' lists we have (officers).
function Wishlist:ListCount()
    local n = 0
    for _, list in pairs(Store()) do
        if #(list.i or {}) > 0 then n = n + 1 end
    end
    return n
end

-------------------------------------------------------------------------------
--  Messages
-------------------------------------------------------------------------------
local function CleanList(list)
    if type(list) ~= "table" or type(list.t) ~= "number" or type(list.i) ~= "table" then return nil end
    local items, seen = {}, {}
    for _, id in ipairs(list.i) do
        if type(id) == "number" and id > 0 and not seen[id] and #items < Wishlist.MAX then
            seen[id] = true
            table.insert(items, math.floor(id))
        end
    end
    return { t = list.t, i = items }
end

AF.Comm:On("WISH", function(sender, lists)
    if type(lists) ~= "table" or not AF.Ledger:CanRecord() then return end
    local store, changed = Store(), false
    for name, list in pairs(lists) do
        list = type(name) == "string" and CleanList(list)
        -- Our own characters' lists are ours to change, nobody else's.
        if list and name ~= AF.playerName and (not store[name] or store[name].t < list.t) then
            store[name] = list
            changed = true
        end
    end
    if changed then Changed() end
end)

AF.Comm:On("WISHQ", function(sender)
    if sender == AF.playerName or not AF.Config:IsOfficer(sender) then return end
    -- Spread the answers out: the whole guild hears this.
    C_Timer.After(1 + math.random() * 8, function()
        local lists = Store()
        if next(lists) then AF.Comm:Send("WISH", lists, "WHISPER", sender) end
    end)
end)

function Wishlist:Enable()
    C_Timer.After(LOGIN_DELAY, function()
        if not IsInGuild() then return end
        if AF.Ledger:CanRecord() then
            AF.Comm:Send("WISHQ", true, "GUILD")
        else
            SendMine()
        end
    end)
end

-------------------------------------------------------------------------------
--  Item tooltips: your rank; for officers, everyone who wants it
-------------------------------------------------------------------------------
local function AddTooltipLines(tooltip, link)
    if not link or AF:IsSecret(link) or not AF.playerName then return end
    local id = Wishlist.ItemID(link)
    if not id then return end
    if AF.Ledger:CanRecord() then
        local wishers = Wishlist:Wishers(id)
        if #wishers == 0 then return end
        local names = {}
        for _, w in ipairs(wishers) do table.insert(names, ("%s (#%d)"):format(AF:ShortName(w.name), w.rank)) end
        tooltip:AddLine("Wishlist: " .. table.concat(names, ", "), 1, 0.82, 0.33, true)
    else
        local rank = Wishlist:MyRank(id)
        if rank then tooltip:AddLine(("On your wishlist (#%d)"):format(rank), 1, 0.82, 0.33) end
    end
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip)
        if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
        local ok, _, link = pcall(tooltip.GetItem, tooltip)
        if ok then AddTooltipLines(tooltip, link) end
    end)
else
    for _, tooltip in ipairs({ GameTooltip, ItemRefTooltip }) do
        tooltip:HookScript("OnTooltipSetItem", function(self)
            local _, link = self:GetItem()
            AddTooltipLines(self, link)
        end)
    end
end
