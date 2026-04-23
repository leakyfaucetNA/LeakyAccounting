local _, ns = ...

-- Passive gold tracking — the chart's authoritative source.
--
-- PLAYER_MONEY fires on every coin change. We record a sparse snapshot of
-- the new balance to goldLog (throttled to one snapshot per minute when the
-- value doesn't change). Income/spend totals in the UI are computed from
-- consecutive goldLog deltas, which means they always match what the wallet
-- actually did — no double-counting, no missed events.

local function onMoney()
    local gold = GetMoney()
    ns.RecordGoldSnapshot(gold)
end

function ns.MoneyOnLoad()
    ns.RecordGoldSnapshot(GetMoney())

    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_MONEY")
    f:SetScript("OnEvent", onMoney)

    ns.lpmsg("Money tracking armed.", "DEBUG")
end
