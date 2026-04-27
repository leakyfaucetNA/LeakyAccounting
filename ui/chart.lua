local _, ns = ...

-- Net-gold-over-time line chart. Axes + labels + a polyline built from
-- 1px WHITE8x8 textures (no external graph lib). Below the chart sits a
-- totals strip: Earned / Spent / Net in the selected scope.

local T  -- ns.theme, bound lazily so it's always the current copy

-- Session-scope state for the chart. windowDays drives the middle totals
-- row ("Last N days"). Not tied to any saved setting — typing in the edit
-- box live-updates the row; resets to 7 on /reload.
local chartSession = { windowDays = 7 }

-- -------------------------------------------------- --
--  Plot-area helpers                                 --
-- -------------------------------------------------- --

local function ensurePlotArea(parent)
    if parent._plot then return parent._plot end

    T = ns.theme

    local STRIP_H    = 92  -- three rows: session, last-N-days, total
    local TOPBAR_H   = 26  -- "Current Gold" label strip

    -- Top bar: shows current gold. Hover opens a tooltip listing per-char
    -- gold in account scope. Uses a Button frame so we get mouse events.
    local topBar = CreateFrame("Button", nil, parent, "BackdropTemplate")
    ns.SetBD(topBar, T.C_PANEL, T.C_BDR)
    topBar:SetPoint("TOPLEFT",  T.PAD, -T.PAD)
    topBar:SetPoint("TOPRIGHT", -T.PAD, -T.PAD)
    topBar:SetHeight(TOPBAR_H)
    topBar:EnableMouse(true)

    local topLbl = ns.MakeLabel(topBar, "Current Gold:", 12, T.C_DIM)
    topLbl:SetPoint("LEFT", 12, 0)
    local topVal = ns.MakeLabel(topBar, "", 12, T.C_TEXT)
    topVal:SetPoint("LEFT", topLbl, "RIGHT", 6, 0)

    parent._topBar    = topBar
    parent._topLabel  = topLbl
    parent._topGold   = topVal

    -- Tooltip: only fires in account scope. RenderChart keeps _scope fresh.
    topBar:SetScript("OnEnter", function(self)
        if self._scope ~= "account" then return end
        local entries = {}
        for key, bucket in ns.IterCharacters() do
            local gold
            if key == ns.GetCharKey() then
                gold = GetMoney()
            else
                local log = bucket.goldLog
                gold = (log and #log > 0) and log[#log].gold or 0
            end
            entries[#entries + 1] = {
                name  = bucket.name  or "?",
                realm = bucket.realm or "?",
                class = bucket.class,
                gold  = gold,
            }
        end
        if #entries == 0 then return end
        table.sort(entries, function(a, b) return a.gold > b.gold end)

        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Account Gold", 1, 1, 1)
        for _, e in ipairs(entries) do
            local c = e.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[e.class]
            local hex = c and string.format("ff%02x%02x%02x",
                math.floor(c.r * 255 + 0.5),
                math.floor(c.g * 255 + 0.5),
                math.floor(c.b * 255 + 0.5)) or "ffffffff"
            local left = string.format("|c%s%s|r  |cff888888%s|r", hex, e.name, e.realm)
            GameTooltip:AddDoubleLine(left, ns.FormatMoney(e.gold))
        end
        GameTooltip:Show()
    end)
    topBar:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local plot = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    ns.SetBD(plot, T.C_BG, T.C_BDR)
    plot:SetPoint("TOPLEFT",     T.PAD, -(T.PAD + TOPBAR_H + 4))
    plot:SetPoint("BOTTOMRIGHT", -T.PAD, T.PAD + STRIP_H + 4)

    plot._lines    = {}  -- pool of Line objects for polyline + gridlines
    plot._marks    = {}  -- axis tick + label pools

    parent._plot = plot

    -- Two-row totals strip: Session on top, all-time Total below.
    local strip = ns.MakePanel(parent, T.C_PANEL, T.C_BDR)
    strip:SetPoint("BOTTOMLEFT",  T.PAD, T.PAD)
    strip:SetPoint("BOTTOMRIGHT", -T.PAD, T.PAD)
    strip:SetHeight(STRIP_H)

    -- Fixed horizontal slot reserved for the title area so the Earned: /
    -- Spent: / Net: columns align across rows even when the title is a
    -- composite widget (e.g. the window row's "Last [#] days").
    local TITLE_AREA_W = 110

    local function buildValueCells(yOff)
        local earnedLbl = ns.MakeLabel(strip, "Earned:", 12, T.C_DIM)
        earnedLbl:SetPoint("TOPLEFT", 12 + TITLE_AREA_W, yOff)
        local earnedVal = ns.MakeLabel(strip, "", 12, T.C_GOOD)
        earnedVal:SetPoint("LEFT", earnedLbl, "RIGHT", 6, 0)

        local spendLbl = ns.MakeLabel(strip, "Spent:", 12, T.C_DIM)
        spendLbl:SetPoint("LEFT", earnedVal, "RIGHT", 20, 0)
        local spendVal = ns.MakeLabel(strip, "", 12, T.C_BAD)
        spendVal:SetPoint("LEFT", spendLbl, "RIGHT", 6, 0)

        local netLbl = ns.MakeLabel(strip, "Net:", 12, T.C_DIM)
        netLbl:SetPoint("LEFT", spendVal, "RIGHT", 20, 0)
        local netVal = ns.MakeLabel(strip, "", 12, T.C_TEXT)
        netVal:SetPoint("LEFT", netLbl, "RIGHT", 6, 0)

        return { earned = earnedVal, spend = spendVal, net = netVal }
    end

    local function buildRow(title, yOff)
        local head = ns.MakeLabel(strip, title, 12, T.C_ACCENT)
        head:SetPoint("TOPLEFT", 12, yOff)
        head:SetWidth(TITLE_AREA_W)
        head:SetJustifyH("LEFT")
        local cells = buildValueCells(yOff)
        cells.title = head
        return cells
    end

    -- The middle row is special — its title is "Last [#] days" with an
    -- inline edit box. Typing live-updates via chartSession.windowDays.
    local function buildWindowRow(yOff)
        local lastLbl = ns.MakeLabel(strip, "Last", 12, T.C_ACCENT)
        lastLbl:SetPoint("TOPLEFT", 12, yOff)

        local holder = CreateFrame("Frame", nil, strip, "BackdropTemplate")
        ns.SetBD(holder, T.C_ELEM, T.C_BDR)
        holder:SetSize(40, 18)
        holder:SetPoint("LEFT", lastLbl, "RIGHT", 4, 0)

        local eb = CreateFrame("EditBox", nil, holder)
        eb:SetPoint("TOPLEFT", 4, -1)
        eb:SetPoint("BOTTOMRIGHT", -4, 1)
        eb:SetAutoFocus(false)
        eb:SetFontObject("GameFontNormalSmall")
        eb:SetTextColor(unpack(T.C_TEXT))
        eb:SetNumeric(true)
        eb:SetMaxLetters(4)
        eb:SetText(tostring(chartSession.windowDays or 7))
        eb:SetScript("OnEscapePressed", eb.ClearFocus)

        local daysLbl = ns.MakeLabel(strip, "days", 12, T.C_DIM)
        daysLbl:SetPoint("LEFT", holder, "RIGHT", 4, 0)

        local function commit(userInput)
            local n = tonumber(eb:GetText() or "")
            if not n or n < 0 then n = 0 end
            if n > 36500 then n = 36500 end
            chartSession.windowDays = n
            if userInput and ns.OnDataChanged then ns.OnDataChanged() end
        end
        eb:SetScript("OnEnterPressed", function(self) commit(true); self:ClearFocus() end)
        eb:SetScript("OnEditFocusLost", function() commit(true) end)
        eb:SetScript("OnTextChanged", function(_, userInput)
            if userInput then commit(true) end
        end)

        local cells = buildValueCells(yOff)
        cells.edit = eb
        return cells
    end

    parent._totals = {
        session = buildRow("Session",  -6),
        window  = buildWindowRow(-34),
        total   = buildRow("Total",    -62),
    }

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

-- Y-axis labels: compact, units-stripped. Big numbers truncate (1.5M,
-- 988.7k); small numbers stay numeric. The full comma-separated gold
-- value is reserved for the totals row and itemized table where space
-- is available.
local function formatGoldShort(copper)
    copper = copper or 0
    local neg = copper < 0
    local g = math.abs(copper) / 10000  -- gold as a float
    local s
    if     g >= 1000000 then s = string.format("%.1fM", g / 1000000)
    elseif g >= 1000    then s = string.format("%.1fk", g / 1000)
    elseif g >= 1       then s = string.format("%d",    math.floor(g))
    else                     s = string.format("%.1f",  g)
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

    -- Current-gold strip at the top. Character scope: GetMoney() for the
    -- logged-in character. Account scope: GetMoney() for self + last-known
    -- goldLog for each other character, summed. Tooltip handler reads
    -- `_scope` off the bar and skips tooltip rendering in char scope.
    do
        local label, total
        if scope == "account" then
            label = "Current Gold (Account):"
            total = 0
            for key, bucket in ns.IterCharacters() do
                if key == ns.GetCharKey() then
                    total = total + GetMoney()
                else
                    local log = bucket.goldLog
                    if log and #log > 0 then total = total + log[#log].gold end
                end
            end
        else
            label = "Current Gold:"
            total = GetMoney()
        end
        parent._topBar._scope = scope
        parent._topLabel:SetText(label)
        parent._topGold:SetText(ns.FormatMoney(total))
    end

    local log = ns.CollectGoldLog(scope)
    local income,  spend,  net  = ns.CollectTotals(scope)
    local sIncome, sSpend, sNet = ns.CollectTotalsSince(scope, ns.sessionStart)

    -- "Last N days" window comes from the chart's own session state,
    -- driven by the inline edit box in the middle totals row. 0 = all.
    local windowDays = chartSession.windowDays or 7
    local wIncome, wSpend, wNet
    if windowDays > 0 then
        local windowSince = time() - windowDays * 86400
        wIncome, wSpend, wNet = ns.CollectTotalsSince(scope, windowSince)
    else
        wIncome, wSpend, wNet = income, spend, net
    end

    local function fillRow(row, earned, spent, netv)
        row.earned:SetText(ns.FormatMoney(earned))
        row.spend:SetText(ns.FormatMoney(spent))
        row.net:SetText(ns.FormatMoney(netv))
        row.net:SetTextColor(unpack(netv >= 0 and T.C_GOOD or T.C_BAD))
    end
    fillRow(totals.session, sIncome, sSpend, sNet)
    fillRow(totals.window,  wIncome, wSpend, wNet)
    fillRow(totals.total,   income,  spend,  net)

    -- Keep the edit box synced with state when the user isn't typing.
    if totals.window.edit and not totals.window.edit:HasFocus() then
        totals.window.edit:SetText(tostring(windowDays))
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
