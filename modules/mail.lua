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

local MAX_RETRIES      = 5
local RETRY_DELAY      = 0.2
-- After this many attempts, stop retrying for a missing player name and
-- record with "?" as the buyer/seller. Matches TSM's `attempt <= 2` logic.
local NAME_RETRY_LIMIT = 2

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

-- FIFO-bounded set: keys live in `taken`, insertion order in `takenOrder`.
-- Capped at TAKEN_CAP so a marathon session with lots of mail activity
-- can't grow the set without bound. Oldest entries drop when we overflow.
local TAKEN_CAP = 500
local taken      = {}
local takenOrder = {}

local function mailId(sender, subject, money, daysLeft)
    return string.format("%s|%s|%d|%.1f",
        tostring(sender or ""), tostring(subject or ""),
        money or 0, daysLeft or 0)
end

local function markTaken(id)
    if taken[id] then return end
    taken[id] = true
    takenOrder[#takenOrder + 1] = id
    if #takenOrder > TAKEN_CAP then
        local old = table.remove(takenOrder, 1)
        taken[old] = nil
    end
end

-- -------------------------------------------------- --
--  Record                                            --
-- -------------------------------------------------- --

-- Returns (success:bool, shouldRetry:bool). success=true ends retries; false
-- with shouldRetry=true schedules another attempt. `tries` is 1-based.
local function recordMail(index, tries)
    if type(index) ~= "number" or index < 1 then
        ns.lpmsg("mail: recordMail bad index=" .. tostring(index), "DEBUG")
        return true
    end

    local _, _, sender, subject, money, cod, daysLeft, hasItem = GetInboxHeaderInfo(index)
    if not subject then
        ns.lpmsg("mail: recordMail try=" .. tries .. " idx=" .. index .. " no subject yet", "DEBUG")
        return false, true
    end
    money = money or 0
    cod   = cod   or 0

    local id = mailId(sender, subject, money, daysLeft)
    if taken[id] then return true end

    -- Classify via invoice first (TSM's approach).
    -- Returns: invoiceType, itemName, playerName, bid, buyout, deposit,
    --          consignment, moneyDelay, etaHour, etaMin, count
    local invoiceType, invItemName, invPlayer, invBid, _, _, invConsignment, _, _, _, invCount = GetInboxInvoiceInfo(index)

    -- AH mails arrive after the auction completed. Backdate the row to
    -- the actual sale time using mail expiry (30 days) minus daysLeft.
    -- Matches TSM's accounting; makes the "Last N days" view accurate.
    local ahTime = (daysLeft and time() + (daysLeft - 30) * 86400) or time()

    if invoiceType == "seller" then
        -- AH sale. TSM's pattern: proceeds = invoice.bid -
        -- invoice.consignment (AH cut). The header "money" field also
        -- reports proceeds but populates later than the invoice fields,
        -- which produced rows with qty>0 but unitPrice=0 when we tried
        -- to record before money had landed.
        if not invItemName or invItemName == "" then
            if tries <= NAME_RETRY_LIMIT then return false, true end
            invItemName = "Unknown auction item"
        end
        if not invPlayer or invPlayer == "" then
            if tries <= NAME_RETRY_LIMIT then return false, true end
            invPlayer = AUCTION_HOUSE_MAIL_MULTIPLE_BUYERS or "?"
        end
        if not invBid or invBid <= 0 then
            if tries <= NAME_RETRY_LIMIT then return false, true end
        end
        local qty       = (invCount and invCount > 0) and invCount or 1
        local proceeds  = (invBid or 0) - (invConsignment or 0)
        if proceeds <= 0 then proceeds = money or 0 end  -- last-resort fallback
        ns.RecordTxn("sell", "auction", {
            itemName    = invItemName,
            qty         = qty,
            unitPrice   = math.floor(proceeds / qty),
            otherPlayer = invPlayer,
            t           = ahTime,
        })
        markTaken(id)
        return true

    elseif invoiceType == "buyer" then
        -- AH purchase — bid is total paid (could be the bid amount or a
        -- buyout). Both bid and itemName populate slightly after the
        -- mail arrives, so retry while either is missing.
        if not invItemName or invItemName == "" then
            if tries <= NAME_RETRY_LIMIT then return false, true end
            invItemName = "Unknown auction item"
        end
        if not invBid or invBid <= 0 then
            if tries <= NAME_RETRY_LIMIT then return false, true end
        end
        local itemLink = hasItem and GetInboxItemLink(index, 1) or nil
        local qty      = (invCount and invCount > 0) and invCount or 1
        local price    = (invBid and invBid > 0) and math.floor(invBid / qty) or 0
        ns.RecordTxn("buy", "auction", {
            itemLink    = itemLink,
            itemName    = (not itemLink) and invItemName or nil,
            qty         = qty,
            unitPrice   = price,
            otherPlayer = (invPlayer and invPlayer ~= "") and invPlayer
                          or AUCTION_HOUSE_MAIL_MULTIPLE_SELLERS or "Auction House",
            t           = ahTime,
        })
        markTaken(id)
        return true

    elseif invoiceType == "seller_temp_invoice" then
        -- Not finalized yet — keep retrying within budget
        if tries <= MAX_RETRIES then return false, true end
        ns.lpmsg("mail: seller_temp_invoice never finalized for idx=" .. index, "DEBUG")
        return true
    end

    -- No invoice — check for non-invoice AH mails (expired / removed / outbid)
    ensurePatterns()
    if PATTERNS.expired and subject:match(PATTERNS.expired)
       or PATTERNS.removed and subject:match(PATTERNS.removed)
       or PATTERNS.outbid  and subject:match(PATTERNS.outbid) then
        markTaken(id)
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
        markTaken(id)
        return true
    end

    -- Plain money-only mail (no item, no cod, no invoice)
    if money > 0 and not hasItem then
        ns.RecordMoney(money, "mail-received", sender)
        markTaken(id)
        return true
    end

    -- Unknown / item-only mail from another player — ignore (not money-related)
    ns.lpmsg("mail: idx=" .. index .. " no handler matched — ignoring", "DEBUG")
    return true
end

-- -------------------------------------------------- --
--  Pre-hook dispatcher with retry                    --
-- -------------------------------------------------- --

local function attempt(origFn, fnName, index, subIndex, tries)
    -- Verify the slot still has data before doing anything. If a retry
    -- fires after the user closed the inbox or a prior call already
    -- consumed this mail, the slot is stale — calling Take* on it
    -- raises the client-side "internal mail database" error. Bail
    -- silently in that case (the user already moved on). Also capture
    -- `texture` here: when the header texture is nil, the server
    -- hasn't fully loaded the mail row yet, so we should retry even
    -- when recordMail "succeeded" — invoice fields may not be ready
    -- (TSM uses the same `not texture or shouldRetry` retry guard).
    -- 2nd return is stationeryIcon — present once the mail row is fully
    -- loaded server-side. TSM uses this exact field as their texture
    -- check; packageIcon (1st) only exists for mails with attachments.
    local _, texture, _, subject = GetInboxHeaderInfo(index)
    if not subject then return end

    local success, shouldRetry = recordMail(index, tries)
    local needRetry = (not success and shouldRetry) or (not texture)
    if needRetry and tries < MAX_RETRIES then
        ns.lpmsg(string.format("mail: %s idx=%s retry #%d", fnName, tostring(index), tries), "DEBUG")
        C_Timer.After(RETRY_DELAY, function()
            attempt(origFn, fnName, index, subIndex, tries + 1)
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
        attempt(origTakeMoney, "TakeInboxMoney", index, subIndex, 1)
    end

    local origTakeItem = TakeInboxItem
    TakeInboxItem = function(index, subIndex)
        attempt(origTakeItem, "TakeInboxItem", index, subIndex, 1)
    end

    local origAutoLoot = AutoLootMailItem
    AutoLootMailItem = function(index, subIndex)
        attempt(origAutoLoot, "AutoLootMailItem", index, subIndex, 1)
    end

    ns.lpmsg("Mail tracking armed.", "DEBUG")
end
