local _, ns = ...

-- Mail-based tracking. Modeled after TSM's Core/Service/Accounting/Mail.lua.
--
-- Key insights taken from TSM:
--   * Mail is classified by GetInboxInvoiceInfo()'s FIRST return
--     ("seller" / "buyer" / "seller_temp_invoice"), not by subject matching.
--     Subject patterns are only used for non-invoice mails (expired, removed,
--     outbid) which carry no invoice at all.
--   * Invoice data isn't populated on the first frame after the server sends
--     the mail list. A "Take" click may fire with the invoice still empty,
--     so we retry up to 5 times with a 0.2s delay before giving up.
--   * We pre-hook TakeInboxMoney / TakeInboxItem / AutoLootMailItem and
--     DEFER the call to the original function until our record succeeds or
--     all retries are exhausted — otherwise the mail slot can rotate away
--     while we're still waiting for the server.

local MAX_RETRIES  = 5
local RETRY_DELAY  = 0.2

-- -------------------------------------------------- --
--  Subject patterns (lazy-init — globals set on load)--
-- -------------------------------------------------- --

local PATTERNS

local function formatToPattern(str)
    if not str then return nil end
    local s = str:gsub("(%W)", "%%%1")  -- escape magic chars
    s = s:gsub("%%%%s", "(.+)")
    s = s:gsub("%%%%d", "(%%d+)")
    return "^" .. s .. "$"
end

local function ensurePatterns()
    if PATTERNS then return end
    PATTERNS = {
        expired = formatToPattern(AUCTION_EXPIRED_MAIL_SUBJECT),
        removed = formatToPattern(AUCTION_REMOVED_MAIL_SUBJECT),
        outbid  = formatToPattern(AUCTION_OUTBID_MAIL_SUBJECT),
    }
end

-- -------------------------------------------------- --
--  Per-session dedup                                 --
-- -------------------------------------------------- --

local taken = {}

local function mailId(sender, subject, money, daysLeft)
    return string.format("%s|%s|%d|%.1f",
        tostring(sender or ""), tostring(subject or ""),
        money or 0, daysLeft or 0)
end

-- -------------------------------------------------- --
--  Record                                            --
-- -------------------------------------------------- --

-- Returns (success:bool, shouldRetry:bool). success=true ends retries; false
-- with shouldRetry=true schedules another attempt.
local function recordMail(index)
    if type(index) ~= "number" or index < 1 then return true end

    local _, _, sender, subject, money, cod, daysLeft, hasItem = GetInboxHeaderInfo(index)
    if not subject then return true end
    money = money or 0
    cod   = cod   or 0

    local id = mailId(sender, subject, money, daysLeft)
    if taken[id] then return true end

    -- Classify via invoice first (TSM's approach).
    -- Returns: invoiceType, itemName, playerName, bid, buyout, deposit,
    --          consignment, moneyDelay, etaHour, etaMin, count
    local invoiceType, invItemName, invPlayer, invBid, _, _, _, _, _, _, invCount = GetInboxInvoiceInfo(index)

    if invoiceType == "seller" then
        -- AH sale — money in header already = bid - ahcut (proceeds).
        -- Retry while itemName or buyer hasn't populated.
        if not invItemName or invItemName == "" then return false, true end
        if not invPlayer   or invPlayer   == "" then return false, true end
        local qty = (invCount and invCount > 0) and invCount or 1
        ns.RecordTxn("sell", "auction", {
            itemName    = invItemName,
            qty         = qty,
            unitPrice   = math.floor(money / qty),
            otherPlayer = invPlayer,
        })
        taken[id] = true
        return true

    elseif invoiceType == "buyer" then
        -- AH purchase — bid is total paid.
        if not invItemName or invItemName == "" then return false, true end
        local itemLink = hasItem and GetInboxItemLink(index, 1) or nil
        local qty      = (invCount and invCount > 0) and invCount or 1
        local price    = (invBid and invBid > 0) and math.floor(invBid / qty) or 0
        ns.RecordTxn("buy", "auction", {
            itemLink    = itemLink,
            itemName    = (not itemLink) and invItemName or nil,
            qty         = qty,
            unitPrice   = price,
            otherPlayer = invPlayer or "Auction House",
        })
        taken[id] = true
        return true

    elseif invoiceType == "seller_temp_invoice" then
        -- Not finalized yet
        return false, true
    end

    -- No invoice — check for non-invoice AH mails (expired / removed / outbid)
    ensurePatterns()
    if PATTERNS.expired and subject:match(PATTERNS.expired)
       or PATTERNS.removed and subject:match(PATTERNS.removed)
       or PATTERNS.outbid  and subject:match(PATTERNS.outbid) then
        taken[id] = true
        return true
    end

    -- COD: we're paying cod to take an item
    if cod > 0 and hasItem then
        local itemLink = GetInboxItemLink(index, 1)
        ns.RecordTxn("buy", "trade", {
            itemLink    = itemLink,
            itemName    = (not itemLink) and "COD item" or nil,
            qty         = 1,
            unitPrice   = cod,
            otherPlayer = sender,
        })
        taken[id] = true
        return true
    end

    -- Plain money-only mail (no item, no cod, no invoice)
    if money > 0 and not hasItem then
        ns.RecordMoney(money, "mail-received", sender)
        taken[id] = true
        return true
    end

    -- Unknown / item-only mail from another player — ignore (not money-related)
    return true
end

-- -------------------------------------------------- --
--  Pre-hook dispatcher with retry                    --
-- -------------------------------------------------- --

local function attempt(origFn, index, subIndex, tries)
    local success, shouldRetry = recordMail(index)
    if not success and shouldRetry and tries < MAX_RETRIES then
        C_Timer.After(RETRY_DELAY, function()
            attempt(origFn, index, subIndex, tries + 1)
        end)
    else
        origFn(index, subIndex)
    end
end

-- -------------------------------------------------- --
--  Bootstrap                                         --
-- -------------------------------------------------- --

function ns.MailOnLoad()
    local origTakeMoney = TakeInboxMoney
    TakeInboxMoney = function(index, subIndex)
        attempt(origTakeMoney, index, subIndex, 1)
    end

    local origTakeItem = TakeInboxItem
    TakeInboxItem = function(index, subIndex)
        attempt(origTakeItem, index, subIndex, 1)
    end

    local origAutoLoot = AutoLootMailItem
    AutoLootMailItem = function(index, subIndex)
        attempt(origAutoLoot, index, subIndex, 1)
    end

    ns.lpmsg("Mail tracking armed.", "DEBUG")
end
