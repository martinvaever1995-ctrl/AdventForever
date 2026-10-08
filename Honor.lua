-------------------------------------------------------------------------------
--  Honor.lua -- this week's honor, reported by the player's own client.
--
--  Your client works out this week's honor from whatever the game offers, and
--  takes the highest:
--    - the weekly honor stats (GetPVPThisWeekStats, Classic-style)
--    - honor gains it saw itself (the honor currency going up while you play),
--      kept per character and week in saved data
--    - the honor currency's own "earned this week", if the client fills it in
--  It reports the number to the guild (HON) when it changes, at most every few
--  minutes. Officers record it as "honor:<player>:<week>#<honor>", so every
--  officer makes the same event; the highest report per player and week counts.
--  A report waits until an officer confirms it (HONACK).
--
--  Honor score = honorMax x min(1, honor / honorTarget).
--
--  Verifying other players' honor by inspecting them needs an inspect-honor API;
--  /af debug says whether this client has one.
-------------------------------------------------------------------------------
local _, AF = ...
local Honor = AF:NewModule("Honor")

local SEND_GAP = 300            -- seconds between reports while honor keeps changing
local consts = Constants and Constants.CurrencyConsts
local HONOR_CURRENCY = consts and (consts.CLASSIC_HONOR_CURRENCY_ID or consts.HONOR_CURRENCY_ID)

local lastSent = 0
local sendTimer

local function Mine()
    AF.db.honor = AF.db.honor or {}
    local byChar = AF.db.honor[AF.playerName] or {}
    AF.db.honor[AF.playerName] = byChar
    return byChar
end

-- This week's record for us: { gained = tracked gains, acked = highest confirmed report }.
local function ThisWeek()
    local byChar = Mine()
    local week = AF.Standings.CurrentWeek()
    for w in pairs(byChar) do
        if w < week - 2 then byChar[w] = nil end
    end
    byChar[week] = byChar[week] or { gained = 0, acked = 0 }
    return byChar[week], week
end

-- This week's honor and where it came from.
function Honor.Current()
    local record = ThisWeek()
    local best, source = record.gained, "tracked"
    if type(GetPVPThisWeekStats) == "function" then
        local _, weekly = GetPVPThisWeekStats()
        if type(weekly) == "number" and weekly > best then best, source = weekly, "weekly stats" end
    end
    if HONOR_CURRENCY and C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then
        local info = C_CurrencyInfo.GetCurrencyInfo(HONOR_CURRENCY)
        local earned = info and info.quantityEarnedThisWeek
        if type(earned) == "number" and earned > best then best, source = earned, "earned this week" end
    end
    return math.floor(best), source
end

-------------------------------------------------------------------------------
--  Reporting
-------------------------------------------------------------------------------
function Honor:Send()
    sendTimer = nil
    if not IsInGuild() or not AF.playerName then return end
    local honor = Honor.Current()
    local record, week = ThisWeek()
    if honor <= record.acked then return end
    lastSent = GetTime()
    AF.Comm:Send("HON", { w = week, h = honor }, "GUILD")
end

-- Honor changed: report soon, but not more often than SEND_GAP.
local function Changed()
    if sendTimer or not AF.playerName then return end
    local wait = math.max(5, SEND_GAP - (GetTime() - lastSent))
    sendTimer = C_Timer.NewTimer(wait, function() Honor:Send() end)
end

local function OnCurrency(_, currencyType, _, change)
    if not HONOR_CURRENCY or currencyType ~= HONOR_CURRENCY or not AF.playerName then return end
    if type(change) == "number" and change > 0 and not AF:IsSecret(change) then
        local record = ThisWeek()
        record.gained = record.gained + change
    end
    Changed()
end

AF:RegisterEvent("CURRENCY_DISPLAY_UPDATE", OnCurrency)
AF:RegisterEvent("HONOR_CURRENCY_UPDATE", Changed)
AF:RegisterEvent("PLAYER_PVP_KILLS_CHANGED", Changed)

AF.Comm:On("HON", function(sender, data)
    if type(data) ~= "table" or type(data.w) ~= "number" or type(data.h) ~= "number" then return end
    if not AF.Ledger:CanRecord() or not AF.Standings:All()[sender] then return end
    local honor = math.floor(data.h)
    if honor <= 0 then return end
    AF.Ledger:RecordHonor(sender, data.w, honor)
    AF.Comm:Send("HONACK", { w = data.w, h = honor }, "WHISPER", sender)
end)

AF.Comm:On("HONACK", function(sender, data)
    if type(data) ~= "table" or type(data.w) ~= "number" or type(data.h) ~= "number" then return end
    if not AF.Config:IsOfficer(sender) then return end
    local record = Mine()[data.w]
    if record and data.h > record.acked then record.acked = data.h end
end)

function Honor:Enable()
    C_Timer.After(40, function() Honor:Send() end)
    C_Timer.NewTicker(SEND_GAP, function() Honor:Send() end)
end

-- What this client offers (for /af debug).
function Honor.ApiReport()
    local function Has(name) return type(_G[name]) == "function" end
    local function Event(name)
        if C_EventUtils and C_EventUtils.IsEventValid then return C_EventUtils.IsEventValid(name) end
        return nil
    end
    local honor, source = Honor.Current()
    return {
        weeklyStats = Has("GetPVPThisWeekStats"),
        currency = HONOR_CURRENCY,
        inspect = Has("RequestInspectHonorData") and Has("GetInspectHonorData"),
        inspectEvent = Event("INSPECT_HONOR_UPDATE"),
        honor = honor,
        source = source,
    }
end
