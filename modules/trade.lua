local _, ns = ...

-- Trade window tracking.
--
-- TRADE_ACCEPT_UPDATE fires with (playerAccepted, targetAccepted). We snapshot
-- the full trade payload on every update. When UI_INFO_MESSAGE arrives with
-- ERR_TRADE_COMPLETE, we commit whichever snapshot reflects "both accepted".
--
-- Trade slots are scanned via GetTradePlayerItemInfo / GetTargetTradeItemInfo
-- and GetPlayerTradeMoney / GetTargetTradeMoney.

local TRADE_SLOTS = 7  -- 6 normal + 1 "will not be traded" slot
local snapshot     -- most recent snapshot of both sides
local partnerName

local function snapshotSide(getItemInfo, getItemLink)
    local items = {}
    for i = 1, TRADE_SLOTS do
        local name, _, qty = getItemInfo(i)
        if name then
            items[#items + 1] = {
                link = getItemLink(i),
                qty  = qty or 1,
            }
        end
    end
    return items
end

local function takeSnapshot()
    snapshot = {
        player = {
            items = snapshotSide(GetTradePlayerItemInfo, GetTradePlayerItemLink),
            money = GetPlayerTradeMoney(),
        },
        target = {
            items = snapshotSide(GetTargetTradeItemInfo, GetTargetTradeItemLink),
            money = GetTargetTradeMoney(),
        },
    }
end

local function commitSnapshot()
    if not snapshot then return end
    local p, t = snapshot.player, snapshot.target
    local other = partnerName or "?"

    -- If player gave money and received items -> buy. If player gave items
    -- and received money -> sell. If both sides had items, each counts as
    -- one sell and one buy at 0 unit price (record for visibility).
    if p.money > 0 and #t.items > 0 then
        -- bought from partner — divide money across items by qty-weighted guess
        local totalQty = 0
        for _, it in ipairs(t.items) do totalQty = totalQty + it.qty end
        totalQty = math.max(totalQty, 1)
        local perUnit = math.floor(p.money / totalQty)
        for _, it in ipairs(t.items) do
            ns.RecordTxn("buy", "trade", {
                itemLink    = it.link,
                qty         = it.qty,
                unitPrice   = perUnit,
                otherPlayer = other,
            })
        end
        if p.money > 0 then ns.RecordMoney(-p.money, "trade-pay", other) end
    end

    if t.money > 0 and #p.items > 0 then
        local totalQty = 0
        for _, it in ipairs(p.items) do totalQty = totalQty + it.qty end
        totalQty = math.max(totalQty, 1)
        local perUnit = math.floor(t.money / totalQty)
        for _, it in ipairs(p.items) do
            ns.RecordTxn("sell", "trade", {
                itemLink    = it.link,
                qty         = it.qty,
                unitPrice   = perUnit,
                otherPlayer = other,
            })
        end
        if t.money > 0 then ns.RecordMoney(t.money, "trade-receive", other) end
    end

    if #p.items > 0 and #t.items > 0 and p.money == 0 and t.money == 0 then
        -- item-for-item swap — record each side at unit 0 so they show up
        for _, it in ipairs(p.items) do
            ns.RecordTxn("sell", "trade", { itemLink = it.link, qty = it.qty, unitPrice = 0, otherPlayer = other })
        end
        for _, it in ipairs(t.items) do
            ns.RecordTxn("buy",  "trade", { itemLink = it.link, qty = it.qty, unitPrice = 0, otherPlayer = other })
        end
    end
end

-- -------------------------------------------------- --
--  Bootstrap                                         --
-- -------------------------------------------------- --

function ns.TradeOnLoad()
    local f = CreateFrame("Frame")
    f:RegisterEvent("TRADE_SHOW")
    f:RegisterEvent("TRADE_CLOSED")
    f:RegisterEvent("TRADE_ACCEPT_UPDATE")
    f:RegisterEvent("TRADE_PLAYER_ITEM_CHANGED")
    f:RegisterEvent("TRADE_TARGET_ITEM_CHANGED")
    f:RegisterEvent("TRADE_MONEY_CHANGED")
    f:RegisterEvent("UI_INFO_MESSAGE")
    f:SetScript("OnEvent", function(_, event, arg1)
        if event == "TRADE_SHOW" then
            partnerName = UnitName("NPC") or "?"
            snapshot = nil
        elseif event == "TRADE_CLOSED" then
            snapshot = nil
            partnerName = nil
        elseif event == "TRADE_ACCEPT_UPDATE"
            or event == "TRADE_PLAYER_ITEM_CHANGED"
            or event == "TRADE_TARGET_ITEM_CHANGED"
            or event == "TRADE_MONEY_CHANGED" then
            takeSnapshot()
        elseif event == "UI_INFO_MESSAGE" then
            -- arg1 = game-error ID, arg2 = localized message text
            if arg1 == LE_GAME_ERR_TRADE_COMPLETE then commitSnapshot() end
        end
    end)

    ns.lpmsg("Trade tracking armed.", "DEBUG")
end
