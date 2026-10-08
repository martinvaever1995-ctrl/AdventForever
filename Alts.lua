-------------------------------------------------------------------------------
--  Alts.lua -- mains and alts.
--
--  The addon's saved data is shared by every character on a WoW account, so it
--  knows for certain which characters are one player's. Each character the addon
--  sees logging in is remembered; the first becomes the main, and the player can
--  pick another ("Make this my main" in the Me tab, or /af main).
--
--  Each character reports only itself to the officers (LINK): "I'm an alt of X"
--  or "I'm a main". Officers record it as "link:<character>#<when the main was
--  chosen>", so resends make the same event, and confirm it (LINKACK). Officers
--  can link and unlink by hand (/af link, /af unlink); their links beat reports.
-------------------------------------------------------------------------------
local _, AF = ...
local Alts = AF:NewModule("Alts")

local RESEND_INTERVAL = 300

local function Account()
    local db = AF.db
    db.characters = db.characters or {}     -- name -> { classFile, guild, seen }
    return db
end

-- The guild this character is in, or nil.
local function MyGuild()
    return IsInGuild() and GetGuildInfo("player") or nil
end

-- Characters on this account in the same guild as us, main first.
function Alts:AccountCharacters()
    local db = Account()
    local guild = MyGuild()
    local list = {}
    for name, info in pairs(db.characters) do
        if guild and info.guild == guild then table.insert(list, name) end
    end
    table.sort(list, function(a, b)
        if a == db.main then return true end
        if b == db.main then return false end
        return a < b
    end)
    return list
end

-- The main this account chose, if it's in our guild; otherwise ourselves.
function Alts:ChosenMain()
    local db = Account()
    local info = db.main and db.characters[db.main]
    if info and info.guild and info.guild == MyGuild() then return db.main end
    return AF.playerName
end

function Alts:Report()
    if not IsInGuild() or not AF.playerName then return end
    local db = Account()
    local main = self:ChosenMain()
    local chosenAt = db.mainChosenAt
    if not chosenAt then return end
    -- An officer's client records its own account's characters directly: it knows
    -- they're one player's, and nobody else is needed to confirm that.
    if AF.Ledger:CanRecord() then
        for _, char in ipairs(self:AccountCharacters()) do
            if AF.Standings:All()[char] then AF.Ledger:RecordLink(char, main, "self", chosenAt) end
        end
        return
    end
    db.linkAcked = db.linkAcked or {}
    local acked = db.linkAcked[AF.playerName]
    if acked and acked.m == main and acked.at == chosenAt then return end
    AF.Comm:Send("LINK", { n = AF.playerName, m = main, at = chosenAt }, "GUILD")
end

-- Makes this character (or the named one on this account) the account's main.
function Alts:SetMain(name)
    local db = Account()
    name = name or AF.playerName
    if not db.characters[name] then return AF:Print("That character isn't on this account.") end
    db.main = name
    db.mainChosenAt = GetServerTime()
    AF:Printf("%s is now your main. Your other characters count as its alts once they log in.", AF:ShortName(name))
    self:Report()
    AF:Fire("STANDINGS_UPDATED")
end

AF.Comm:On("LINK", function(sender, data)
    if type(data) ~= "table" or data.n ~= sender or type(data.m) ~= "string" or type(data.at) ~= "number" then return end
    if not AF.Ledger:CanRecord() or not AF.Standings:All()[sender] then return end
    -- A main outside the guild means the character counts as its own main.
    local main = AF.Standings:All()[data.m] and data.m or sender
    AF.Ledger:RecordLink(sender, main, "self", data.at)
    AF.Comm:Send("LINKACK", { m = data.m, at = data.at }, "WHISPER", sender)
end)

AF.Comm:On("LINKACK", function(sender, data)
    if type(data) ~= "table" or not AF.Config:IsOfficer(sender) then return end
    local db = Account()
    db.linkAcked = db.linkAcked or {}
    db.linkAcked[AF.playerName] = { m = data.m, at = data.at }
end)

-- Officers: link a character to a main by hand (main == alt unlinks it).
function Alts:OfficerLink(alt, main)
    if not AF.Ledger:CanRecord() then return AF:Print("Only officers can link characters.") end
    if AF.Ledger:RecordLink(alt, main, "officer") then
        if alt == main then
            AF:Printf("%s now counts as its own main.", AF:ShortName(alt))
        else
            AF:Printf("%s is now an alt of %s.", AF:ShortName(alt), AF:ShortName(main))
        end
    end
end

function Alts:Enable()
    local db = Account()
    local _, classFile = UnitClass("player")
    local entry = db.characters[AF.playerName] or {}
    entry.classFile, entry.seen = classFile, GetServerTime()
    db.characters[AF.playerName] = entry
    if not db.main then db.main = AF.playerName end
    db.mainChosenAt = db.mainChosenAt or GetServerTime()
    -- The guild name arrives with the roster; note it once it's there, then report.
    C_Timer.After(25, function()
        entry.guild = MyGuild()
        Alts:Report()
    end)
    C_Timer.NewTicker(RESEND_INTERVAL, function()
        entry.guild = MyGuild() or entry.guild
        Alts:Report()
    end)
end
