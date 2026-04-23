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
    -- Anchor "session" to first login of this client run; stays constant
    -- across /reload within the same session because module locals reset,
    -- but if you want session=since-reload, that's what you get.
    ns.sessionStart = time()

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

-- -------------------------------------------------- --
--  Debug dump                                        --
-- -------------------------------------------------- --

local function dumpChar(key, bucket, mode)
    local txns    = bucket.transactions or {}
    local moneys  = bucket.money        or {}
    local gold    = bucket.goldLog      or {}
    print(string.format("|cff00fbff[LA]|r %s — %d txn, %d money, %d gold snapshots",
        key, #txns, #moneys, #gold))

    -- Breakdown by source + kind for quick sanity check
    local counts = {}
    for _, t in ipairs(txns) do
        local k = (t.source or "?") .. "/" .. (t.kind or "?")
        counts[k] = (counts[k] or 0) + 1
    end
    local parts = {}
    for k, n in pairs(counts) do parts[#parts + 1] = k .. "=" .. n end
    if #parts > 0 then
        table.sort(parts)
        print("  txn by source/kind: " .. table.concat(parts, ", "))
    end

    if mode == "txns" or mode == "all" then
        for i, t in ipairs(txns) do
            print(string.format("  [%d] %s %s/%s %s x%d @%s other=%s",
                i, date("%m/%d %H:%M", t.t),
                tostring(t.source), tostring(t.kind),
                tostring(t.itemLink or t.itemName or "?"),
                t.qty or 1, tostring(t.unitPrice or 0),
                tostring(t.otherPlayer or "?")))
        end
    end

    if mode == "money" or mode == "all" then
        for i, m in ipairs(moneys) do
            print(string.format("  {%d} %s %s %+d other=%s",
                i, date("%m/%d %H:%M", m.t),
                tostring(m.reason), m.delta or 0,
                tostring(m.otherPlayer or "?")))
        end
    end

    if mode == "auction" then
        for i, t in ipairs(txns) do
            if t.source == "auction" then
                print(string.format("  [%d] %s %s %s x%d @%s other=%s",
                    i, date("%m/%d %H:%M", t.t),
                    tostring(t.kind),
                    tostring(t.itemLink or t.itemName or "?"),
                    t.qty or 1, tostring(t.unitPrice or 0),
                    tostring(t.otherPlayer or "?")))
            end
        end
    end
end

function LA:SlashCommand(input)
    local arg = (input or ""):lower():match("^%s*(.-)%s*$")
    local cmd, rest = arg:match("^(%S+)%s*(.-)$")
    cmd = cmd or ""

    if arg == "" or arg == "show" or arg == "toggle" then
        if ns.ToggleUI then ns.ToggleUI() end
    elseif arg == "reset" then
        local k = ns.GetCharKey()
        self.db.global.characters[k] = nil
        ns.EnsureCharacter()
        ns.lpmsg("Reset: cleared transactions/money/goldLog for " .. k)
    elseif cmd == "dump" then
        -- /la dump              → summary for this character
        -- /la dump txns         → list all transactions this character
        -- /la dump money        → list all money entries this character
        -- /la dump auction      → only auction-source transactions this character
        -- /la dump all          → txns + money this character
        -- /la dump account      → summary for every character
        local mode = (rest ~= "" and rest) or "summary"
        if mode == "account" then
            for k, bucket in pairs(self.db.global.characters) do
                dumpChar(k, bucket, "summary")
            end
        else
            local k = ns.GetCharKey()
            local bucket = self.db.global.characters[k]
            if not bucket then
                ns.lpmsg("No data for " .. k)
            else
                dumpChar(k, bucket, mode)
            end
        end
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
        ns.lpmsg("Commands: (no arg) toggle UI | reset | debug [on|off] | dump [txns|money|auction|all|account]")
    end
end
