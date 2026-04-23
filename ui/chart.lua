local _, ns = ...

-- Net-gold-over-time line chart. Axes + labels + a polyline built from
-- 1px WHITE8x8 textures (no external graph lib). Below the chart sits a
-- totals strip: Income / Spend / Net in the selected scope.

local T  -- ns.theme, bound lazily so it's always the current copy

-- -------------------------------------------------- --
--  Plot-area helpers                                 --
-- -------------------------------------------------- --

local function ensurePlotArea(parent)
    if parent._plot then return parent._plot end

    T = ns.theme
    local plot = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    ns.SetBD(plot, T.C_BG, T.C_BDR)
    plot:SetPoint("TOPLEFT",     T.PAD, -T.PAD)
    plot:SetPoint("BOTTOMRIGHT", -T.PAD, T.PAD + 44)  -- leave room for totals strip

    plot._lines    = {}  -- pool of Line objects for polyline + gridlines
    plot._marks    = {}  -- axis tick + label pools

    parent._plot = plot

    -- Totals strip under the plot
    local strip = ns.MakePanel(parent, T.C_PANEL, T.C_BDR)
    strip:SetPoint("BOTTOMLEFT",  T.PAD, T.PAD)
    strip:SetPoint("BOTTOMRIGHT", -T.PAD, T.PAD)
    strip:SetHeight(36)

    local incomeLbl = ns.MakeLabel(strip, "Income:", 12, T.C_DIM)
    incomeLbl:SetPoint("LEFT", 12, 0)
    local incomeVal = ns.MakeLabel(strip, "", 12, T.C_GOOD)
    incomeVal:SetPoint("LEFT", incomeLbl, "RIGHT", 6, 0)

    local spendLbl = ns.MakeLabel(strip, "Spend:", 12, T.C_DIM)
    spendLbl:SetPoint("LEFT", incomeVal, "RIGHT", 20, 0)
    local spendVal = ns.MakeLabel(strip, "", 12, T.C_BAD)
    spendVal:SetPoint("LEFT", spendLbl, "RIGHT", 6, 0)

    local netLbl = ns.MakeLabel(strip, "Net:", 12, T.C_DIM)
    netLbl:SetPoint("LEFT", spendVal, "RIGHT", 20, 0)
    local netVal = ns.MakeLabel(strip, "", 12, T.C_TEXT)
    netVal:SetPoint("LEFT", netLbl, "RIGHT", 6, 0)

    parent._totals = { income = incomeVal, spend = spendVal, net = netVal }

    return plot
end

local function releaseChildren(plot)
    for _, ln in ipairs(plot._lines) do ln:Hide() end
    for _, m  in ipairs(plot._marks) do m:Hide()   end
    plot._lineSlot = 0
    plot._markSlot = 0
end

local function nextLine(plot)
    plot._lineSlot = (plot._lineSlot or 0) + 1
    local ln = plot._lines[plot._lineSlot]
    if not ln then
        ln = plot:CreateLine(nil, "ARTWORK")
        ln:SetTexture(T.TEX)
        plot._lines[plot._lineSlot] = ln
    end
    ln:Show()
    return ln
end

local function nextMark(plot)
    plot._markSlot = (plot._markSlot or 0) + 1
    local m = plot._marks[plot._markSlot]
    if not m then
        m = plot:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        plot._marks[plot._markSlot] = m
    end
    m:Show()
    return m
end

-- Draw a line between two relative points (x,y in pixels from plot TL).
-- Positive Y = down (UI convention); Line endpoint Y is inverted for WoW
-- anchoring (which uses +Y = up from TOPLEFT).
local function drawSegment(plot, x1, y1, x2, y2, thickness, color)
    local ln = nextLine(plot)
    ln:ClearAllPoints()
    ln:SetThickness(thickness or 1.5)
    ln:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
    ln:SetStartPoint("TOPLEFT", plot, x1, -y1)
    ln:SetEndPoint("TOPLEFT",   plot, x2, -y2)
end

-- -------------------------------------------------- --
--  Render                                            --
-- -------------------------------------------------- --

local function formatGoldShort(copper)
    copper = copper or 0
    local neg = copper < 0
    local c = math.abs(copper)
    local g = c / 10000
    local s
    if g >= 1000000 then s = string.format("%.1fM g", g / 1000000)
    elseif g >= 1000 then s = string.format("%.1fk g", g / 1000)
    elseif g >= 1    then s = string.format("%d g",    math.floor(g))
    else                 s = string.format("%d s",    math.floor(c / 100))
    end
    return neg and ("-" .. s) or s
end

local function formatDay(ts)
    return date("%m/%d", ts)
end

function ns.RenderChart(parent, scope)
    T = ns.theme
    local plot   = ensurePlotArea(parent)
    local totals = parent._totals
    releaseChildren(plot)

    local log = ns.CollectGoldLog(scope)
    local income, spend, net = ns.CollectTotals(scope)

    totals.income:SetText(ns.FormatMoney(income))
    totals.spend:SetText(ns.FormatMoney(spend))
    totals.net:SetText(ns.FormatMoney(net))
    if net >= 0 then
        totals.net:SetTextColor(unpack(T.C_GOOD))
    else
        totals.net:SetTextColor(unpack(T.C_BAD))
    end

    -- Empty-state
    if #log < 2 then
        local m = nextMark(plot)
        m:ClearAllPoints()
        m:SetPoint("CENTER", plot, "CENTER", 0, 0)
        m:SetText(#log == 0
            and "No gold data yet. Log in / log out to seed the first snapshot."
            or "Only one snapshot recorded — come back later to see a trend.")
        m:SetTextColor(unpack(T.C_DIM))
        return
    end

    -- Compute axis bounds
    local tMin, tMax = log[1].t, log[#log].t
    local gMin, gMax = log[1].gold, log[1].gold
    for _, p in ipairs(log) do
        if p.gold < gMin then gMin = p.gold end
        if p.gold > gMax then gMax = p.gold end
    end
    if tMax == tMin then tMax = tMin + 1 end
    if gMax == gMin then gMax = gMin + 1 end

    -- Inset plot a bit for labels
    local INSET_L, INSET_R, INSET_T, INSET_B = 60, 16, 12, 24
    local w = plot:GetWidth()  - INSET_L - INSET_R
    local h = plot:GetHeight() - INSET_T - INSET_B
    if w <= 0 or h <= 0 then return end

    local function toX(t) return INSET_L + ((t - tMin) / (tMax - tMin)) * w end
    local function toY(g) return INSET_T + (1 - (g - gMin) / (gMax - gMin)) * h end

    -- Y-axis gridlines (4 steps)
    local gridColor = {0.25, 0.25, 0.25, 0.6}
    for i = 0, 4 do
        local frac = i / 4
        local gridY = INSET_T + frac * h
        local gv = gMax - (gMax - gMin) * frac
        drawSegment(plot, INSET_L, gridY, INSET_L + w, gridY, 1, gridColor)

        local lbl = nextMark(plot)
        lbl:ClearAllPoints()
        lbl:SetPoint("RIGHT", plot, "TOPLEFT", INSET_L - 4, -gridY)
        lbl:SetText(formatGoldShort(gv))
        lbl:SetTextColor(unpack(T.C_DIM))
    end

    -- X-axis tick labels (start, middle, end)
    for _, frac in ipairs({0, 0.5, 1}) do
        local tv = tMin + (tMax - tMin) * frac
        local lbl = nextMark(plot)
        lbl:ClearAllPoints()
        lbl:SetPoint("TOP", plot, "TOPLEFT", INSET_L + frac * w, -(INSET_T + h + 4))
        lbl:SetText(formatDay(tv))
        lbl:SetTextColor(unpack(T.C_DIM))
    end

    -- Polyline
    for i = 2, #log do
        local p0, p1 = log[i - 1], log[i]
        drawSegment(plot, toX(p0.t), toY(p0.gold), toX(p1.t), toY(p1.gold), 2, T.C_ACCENT)
    end
end
