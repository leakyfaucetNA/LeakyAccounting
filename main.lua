local _, ns = ...

LeakyAccounting = LibStub("AceAddon-3.0"):NewAddon(
    "LeakyAccounting",
    "AceEvent-3.0",
    "AceHook-3.0",
    "AceConsole-3.0",
    "AceTimer-3.0"
)

local LA  = LeakyAccounting
local ADB = LibStub("AceDB-3.0")

ns.addon = LA

-- -------------------------------------------------- --
--  Logging                                           --
-- -------------------------------------------------- --

function ns.lpmsg(msg, category)
    local isDebug = (category == "DEBUG")
    local debugOn = LA.db and LA.db.profile.debug

    if isDebug then
        if debugOn then
            print("|cffff9900[LA-dbg]|r " .. tostring(msg))
        end
    else
        print("|cff00fbffLeakyAccounting:|r " .. tostring(msg))
    end
end

-- -------------------------------------------------- --
--  DB Defaults                                       --
-- -------------------------------------------------- --

local defaults = {
    global = {
        schemaVersion = 1,
        characters    = {},
    },
    profile = {
        debug = false,
    },
}

-- -------------------------------------------------- --
--  Lifecycle                                         --
-- -------------------------------------------------- --

function LA:OnInitialize()
    self.db = ADB:New("LeakyAccountingDB", defaults, true)
    ns.EnsureCharacter()

    self:RegisterEvent("PLAYER_LOGIN")
end

function LA:OnEnable()
    self:RegisterChatCommand("la",   "SlashCommand")
    self:RegisterChatCommand("lacc", "SlashCommand")
    ns.lpmsg("Loaded — type /la or /lacc to open the overview.")
end

function LA:PLAYER_LOGIN()
    -- Modules register their own hooks lazily in their *_OnLoad functions,
    -- which are invoked here now that the player character is known.
    if ns.VendorOnLoad then ns.VendorOnLoad() end
    if ns.MailOnLoad   then ns.MailOnLoad()   end
    if ns.TradeOnLoad  then ns.TradeOnLoad()  end
    if ns.MoneyOnLoad  then ns.MoneyOnLoad()  end
end

-- -------------------------------------------------- --
--  Slash Commands                                    --
-- -------------------------------------------------- --

function LA:SlashCommand(input)
    local arg = (input or ""):lower():match("^%s*(.-)%s*$")

    if arg == "" or arg == "show" or arg == "toggle" then
        if ns.ToggleUI then ns.ToggleUI() end
    elseif arg == "reset" then
        local k = ns.GetCharKey()
        self.db.global.characters[k] = nil
        ns.EnsureCharacter()
        ns.lpmsg("Reset: cleared transactions/money/goldLog for " .. k)
    elseif arg == "debug on" then
        self.db.profile.debug = true
        ns.lpmsg("Debug: |cff00ff00ON|r")
    elseif arg == "debug off" then
        self.db.profile.debug = false
        ns.lpmsg("Debug: |cffff0000OFF|r")
    elseif arg == "debug" then
        self.db.profile.debug = not self.db.profile.debug
        ns.lpmsg("Debug: " .. (self.db.profile.debug and "|cff00ff00ON|r" or "|cffff0000OFF|r"))
    else
        ns.lpmsg("Commands: (no arg) toggle UI | reset | debug [on|off]")
    end
end
