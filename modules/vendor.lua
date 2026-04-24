local _, ns = ...

-- Vendor buy/sell tracking.
--
-- Buys:    hooksecurefunc("BuyMerchantItem", ...) — called whenever the player
--          clicks an item on the merchant frame.
-- Buyback: hooksecurefunc("BuybackItem", ...).
-- Sells:   hook C_Container.UseContainerItem while a merchant window is open.
--          The API doesn't give us the sale price directly, so we snapshot
--          bag state + gold on use, then read the delta on BAG_UPDATE_DELAYED.
--
-- Repairs: snapshot gold on MERCHANT_SHOW; on MERCHANT_CLOSED, any negative
--          unaccounted delta with a durability event in between is a repair.

local merchantOpen = false
local pendingSale  -- { bag, slot, link, preCount, preGold }
local sessionGold  -- gold at merchant-show
local sessionTxnSpend, sessionTxnIncome = 0, 0
local sawDurability
local sessionGuildRepair  -- cost captured when RepairAllItems(true) is called

-- -------------------------------------------------- --
--  Buy handlers                                      --
-- -------------------------------------------------- --

local function OnBuyMerchantItem(index, quantity)
    if not index then return end
    local info = C_MerchantFrame.GetItemInfo(index)
    if not info or not info.price or info.price == 0 then return end

    local link = GetMerchantItemLink(index)
    if not link then return end

    -- quantity (arg) is # of stacks purchased; total units = stacks * stackSize.
    local stacksBought  = quantity or 1
    local unitsPerStack = info.stackCount or 1
    local totalUnits    = stacksBought * unitsPerStack
    local unitPrice     = math.floor(info.price / unitsPerStack)

    ns.RecordTxn("buy", "vendor", {
        itemLink    = link,
        qty         = totalUnits,
        unitPrice   = unitPrice,
        otherPlayer = "Merchant",
    })
    sessionTxnSpend = sessionTxnSpend + (stacksBought * info.price)
end

local function OnBuybackItem(index)
    if not index then return end
    local name, _, price, qty = GetBuybackItemInfo(index)
    if not name or not price or price == 0 then return end
    local link = GetBuybackItemLink(index)
    if not link then return end

    ns.RecordTxn("buy", "vendor", {
        itemLink    = link,
        qty         = qty or 1,
        unitPrice   = math.floor(price / (qty or 1)),
        otherPlayer = "Merchant (buyback)",
    })
    sessionTxnSpend = sessionTxnSpend + price
end

-- -------------------------------------------------- --
--  Sell detection                                    --
-- -------------------------------------------------- --

local function OnUseContainerItem(bag, slot)
    if not merchantOpen then return end
    if not bag or not slot then return end
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if not info then return end
    pendingSale = {
        bag      = bag,
        slot     = slot,
        link     = info.hyperlink,
        preCount = info.stackCount or 1,
        preGold  = GetMoney(),
    }
end

local function ResolvePendingSale()
    if not pendingSale then return end
    local ps = pendingSale
    pendingSale = nil

    local info = C_Container.GetContainerItemInfo(ps.bag, ps.slot)
    local sold
    if not info or info.hyperlink ~= ps.link then
        sold = ps.preCount
    else
        sold = (ps.preCount or 0) - (info.stackCount or 0)
    end
    if sold <= 0 then return end

    local goldDelta = GetMoney() - ps.preGold
    if goldDelta <= 0 then return end

    local unitPrice = math.floor(goldDelta / sold)
    ns.RecordTxn("sell", "vendor", {
        itemLink    = ps.link,
        qty         = sold,
        unitPrice   = unitPrice,
        otherPlayer = "Merchant",
    })
    sessionTxnIncome = sessionTxnIncome + goldDelta
end

-- -------------------------------------------------- --
--  Session (repair detection via net gold delta)     --
-- -------------------------------------------------- --

local function OnMerchantShow()
    merchantOpen = true
    sessionGold = GetMoney()
    sessionTxnSpend, sessionTxnIncome = 0, 0
    sawDurability = false
    sessionGuildRepair = nil
end

local function OnMerchantClosed()
    if merchantOpen and sessionGold then
        local actualDelta  = GetMoney() - sessionGold
        local txnDelta     = sessionTxnIncome - sessionTxnSpend
        local unattributed = actualDelta - txnDelta
        if sawDurability and unattributed < 0 then
            ns.RecordMoney(unattributed, "repair", "Merchant")
        end
        -- Guild-funded repair: player's wallet didn't change, so the normal
        -- delta-based detector doesn't fire. Record it separately so the
        -- row shows in the log, but the itemized totals skip it (see
        -- totals computation in ui/itemized.lua).
        if sessionGuildRepair and sessionGuildRepair > 0 then
            ns.RecordMoney(-sessionGuildRepair, "guild-repair", "Guild Repair")
        end
    end
    merchantOpen      = false
    pendingSale       = nil
    sessionGold       = nil
    sawDurability     = false
    sessionGuildRepair = nil
end

local function OnDurability() sawDurability = true end

-- -------------------------------------------------- --
--  Bootstrap                                         --
-- -------------------------------------------------- --

function ns.VendorOnLoad()
    hooksecurefunc("BuyMerchantItem", OnBuyMerchantItem)
    hooksecurefunc("BuybackItem",     OnBuybackItem)
    hooksecurefunc(C_Container, "UseContainerItem", OnUseContainerItem)

    -- Pre-hook RepairAllItems. When called with true/1, the repair is
    -- paid from the guild bank — we capture the pre-repair cost since
    -- GetRepairAllCost() returns 0 after the repair completes.
    local origRepairAll = RepairAllItems
    RepairAllItems = function(useGuildFunds)
        if useGuildFunds == true or useGuildFunds == 1 then
            local cost = GetRepairAllCost() or 0
            if cost > 0 then sessionGuildRepair = cost end
        end
        return origRepairAll(useGuildFunds)
    end

    -- Pre-hook SellAllJunkItems. The "Sell All Junk" button bypasses
    -- UseContainerItem, so the individual-sale detector never fires —
    -- we have to enumerate gray items ourselves before the call. For
    -- each poor-quality item with a sell price, record a sell row
    -- using the item's known vendor price. Gold delta still rolls
    -- through via PLAYER_MONEY, and sessionTxnIncome so the merchant
    -- session's unattributed-delta math stays balanced.
    if C_MerchantFrame and C_MerchantFrame.SellAllJunkItems then
        local origSellAllJunk = C_MerchantFrame.SellAllJunkItems
        C_MerchantFrame.SellAllJunkItems = function(...)
            for bag = 0, 5 do
                local n = C_Container.GetContainerNumSlots(bag) or 0
                for slot = 1, n do
                    local info = C_Container.GetContainerItemInfo(bag, slot)
                    if info
                       and info.quality == Enum.ItemQuality.Poor
                       and not info.hasNoValue then
                        local _, _, _, _, _, _, _, _, _, _, sellPrice =
                            C_Item.GetItemInfo(info.itemID)
                        if sellPrice and sellPrice > 0 then
                            local qty = info.stackCount or 1
                            ns.RecordTxn("sell", "vendor", {
                                itemLink    = info.hyperlink,
                                qty         = qty,
                                unitPrice   = sellPrice,
                                otherPlayer = "Merchant",
                            })
                            sessionTxnIncome = sessionTxnIncome + sellPrice * qty
                        end
                    end
                end
            end
            return origSellAllJunk(...)
        end
    end

    local f = CreateFrame("Frame")
    f:RegisterEvent("MERCHANT_SHOW")
    f:RegisterEvent("MERCHANT_CLOSED")
    f:RegisterEvent("BAG_UPDATE_DELAYED")
    f:RegisterEvent("UPDATE_INVENTORY_DURABILITY")
    f:SetScript("OnEvent", function(_, event)
        if     event == "MERCHANT_SHOW"              then OnMerchantShow()
        elseif event == "MERCHANT_CLOSED"            then OnMerchantClosed()
        elseif event == "BAG_UPDATE_DELAYED"         then ResolvePendingSale()
        elseif event == "UPDATE_INVENTORY_DURABILITY" then OnDurability()
        end
    end)

    ns.lpmsg("Vendor tracking armed.", "DEBUG")
end
