local _, ns = ...

-- -------------------------------------------------- --
--  Character bookkeeping                             --
-- -------------------------------------------------- --

function ns.GetCharKey()
    local name  = UnitName("player") or "Unknown"
    local realm = GetRealmName() or "UnknownRealm"
    return realm .. "-" .. name
end

function ns.GetCharBucket(key)
    key = key or ns.GetCharKey()
    local chars = ns.addon.db.global.characters
    return chars[key]
end

function ns.EnsureCharacter()
    local key = ns.GetCharKey()
    local chars = ns.addon.db.global.characters
    if not chars[key] then
        local _, class = UnitClass("player")
        chars[key] = {
            class        = class,
            realm        = GetRealmName(),
            name         = UnitName("player"),
            transactions = {},
            money        = {},
            goldLog      = {},
        }
    end
    return chars[key]
end

function ns.IterCharacters()
    return pairs(ns.addon.db.global.characters)
end

-- -------------------------------------------------- --
--  Item helpers                                      --
-- -------------------------------------------------- --

function ns.ItemIDFromLink(link)
    if not link then return nil end
    local id = link:match("item:(%d+)")
    return id and tonumber(id) or nil
end

-- -------------------------------------------------- --
--  Recording                                         --
-- -------------------------------------------------- --

-- kind   : "buy" | "sell"
-- source : "vendor" | "auction" | "trade"
-- info   : { itemLink, itemName, qty, unitPrice, otherPlayer }
--          At least one of itemLink or itemName must be present.
function ns.RecordTxn(kind, source, info)
    if not info or not info.qty or not info.unitPrice
       or (not info.itemLink and not info.itemName) then
        ns.lpmsg("RecordTxn: bad args " .. tostring(kind) .. "/" .. tostring(source), "DEBUG")
        return
    end

    local bucket = ns.EnsureCharacter()
    local entry = {
        t           = time(),
        kind        = kind,
        source      = source,
        itemID      = ns.ItemIDFromLink(info.itemLink),
        itemLink    = info.itemLink,
        itemName    = info.itemName,
        qty         = info.qty,
        unitPrice   = info.unitPrice,
        otherPlayer = info.otherPlayer,
    }
    bucket.transactions[#bucket.transactions + 1] = entry

    ns.lpmsg(string.format("Txn: %s %s x%d @ %d (%s)",
        kind, info.itemLink or info.itemName or "?",
        info.qty, info.unitPrice, source), "DEBUG")

    if ns.OnDataChanged then ns.OnDataChanged() end
end

-- reason : "repair" | "mail-postage" | "quest" | "unknown" | etc
-- delta  : positive = gained, negative = spent (copper)
function ns.RecordMoney(delta, reason, otherPlayer)
    if not delta or delta == 0 then return end

    local bucket = ns.EnsureCharacter()
    bucket.money[#bucket.money + 1] = {
        t           = time(),
        delta       = delta,
        reason      = reason or "unknown",
        otherPlayer = otherPlayer,
    }

    ns.lpmsg(string.format("Money: %+d (%s)", delta, reason or "unknown"), "DEBUG")

    if ns.OnDataChanged then ns.OnDataChanged() end
end

-- Store a sparse snapshot of GetMoney(). Called by money.lua on PLAYER_MONEY.
function ns.RecordGoldSnapshot(gold)
    local bucket = ns.EnsureCharacter()
    local log = bucket.goldLog
    local n = #log
    if n > 0 then
        local last = log[n]
        -- skip duplicate values within 60s
        if last.gold == gold and (time() - last.t) < 60 then return end
    end
    log[n + 1] = { t = time(), gold = gold }
end

-- -------------------------------------------------- --
--  Aggregation (for UI)                              --
-- -------------------------------------------------- --

-- scope: "char" | "account"
-- Returns a flat array of lightweight view-rows (not the stored records)
-- sorted by time desc. Each row has the same fields as the transaction plus
-- a `_char` hint used by the itemized tab's account view. Not writing to
-- the stored record keeps `_char` out of saved variables.
function ns.CollectTxns(scope)
    local out = {}
    local function push(txn, charName)
        out[#out + 1] = {
            t           = txn.t,
            kind        = txn.kind,
            source      = txn.source,
            itemID      = txn.itemID,
            itemLink    = txn.itemLink,
            itemName    = txn.itemName,
            qty         = txn.qty,
            unitPrice   = txn.unitPrice,
            otherPlayer = txn.otherPlayer,
            _char       = charName,
        }
    end
    if scope == "account" then
        for _, bucket in ns.IterCharacters() do
            for _, t in ipairs(bucket.transactions) do push(t, bucket.name) end
        end
    else
        local bucket = ns.GetCharBucket()
        if bucket then
            for _, t in ipairs(bucket.transactions) do push(t, bucket.name) end
        end
    end
    table.sort(out, function(a, b) return a.t > b.t end)
    return out
end

-- Returns (income, spend, net) in copper across scope.
-- Derived from consecutive goldLog deltas so totals always match the wallet.
function ns.CollectTotals(scope)
    local income, spend = 0, 0
    local function fold(bucket)
        local log = bucket.goldLog
        for i = 2, #log do
            local d = log[i].gold - log[i - 1].gold
            if d > 0 then income = income + d
            elseif d < 0 then spend = spend - d end
        end
    end
    if scope == "account" then
        for _, b in ns.IterCharacters() do fold(b) end
    else
        local b = ns.GetCharBucket()
        if b then fold(b) end
    end
    return income, spend, income - spend
end

-- Collect gold snapshots across scope, sorted ascending by time.
-- In account scope, snapshots are unioned per-character — each character line
-- is independent; the chart sums concurrent balances by computing the
-- per-character "most recent snapshot <= t" and adding.
function ns.CollectGoldLog(scope)
    if scope == "account" then
        -- Merge: for each distinct timestamp, sum most-recent-snapshot-per-char.
        local charLogs = {}
        for _, bucket in ns.IterCharacters() do
            if #bucket.goldLog > 0 then
                charLogs[#charLogs + 1] = bucket.goldLog
            end
        end
        if #charLogs == 0 then return {} end

        local times = {}
        for _, log in ipairs(charLogs) do
            for _, p in ipairs(log) do times[#times + 1] = p.t end
        end
        table.sort(times)

        local merged = {}
        local prev
        for _, t in ipairs(times) do
            if t ~= prev then
                local sum = 0
                for _, log in ipairs(charLogs) do
                    local last
                    for _, p in ipairs(log) do
                        if p.t <= t then last = p else break end
                    end
                    if last then sum = sum + last.gold end
                end
                merged[#merged + 1] = { t = t, gold = sum }
                prev = t
            end
        end
        return merged
    else
        local bucket = ns.GetCharBucket()
        if not bucket then return {} end
        local copy = {}
        for i, p in ipairs(bucket.goldLog) do copy[i] = p end
        return copy
    end
end

-- -------------------------------------------------- --
--  Money formatting                                  --
-- -------------------------------------------------- --

function ns.FormatMoney(copper)
    copper = copper or 0
    local neg = copper < 0
    copper = math.abs(copper)
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    local str
    if g > 0 then
        str = string.format("|cffffd100%d|rg |cffc7c7cf%d|rs |cffeda55f%d|rc", g, s, c)
    elseif s > 0 then
        str = string.format("|cffc7c7cf%d|rs |cffeda55f%d|rc", s, c)
    else
        str = string.format("|cffeda55f%d|rc", c)
    end
    if neg then str = "-" .. str end
    return str
end
