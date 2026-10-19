module 'aux.tabs.stats'

-- Local addition: the Ledger tab. Daily bars of your auction house trading, recorded by the
-- AuxStats addon (AuxStatsDB.events: "time;kind;count;copper;item name").

local aux = require 'aux'
local gui = require 'aux.gui'
local money = require 'aux.util.money'

local tab = aux.tab 'Ledger'

-- kind: b bought, d deposit, r deposit returned, s sold, e expired, c cancelled, l deposit lost
-- field: g gold, n item count, c number of auctions
M.SERIES = {
	{key = 'spent',    kind = 'b', field = 'g', label = 'Spent buying',      gold = true,  color = {.95, .35, .35}, on = true},
	-- deposits on auctions that came back unsold: the deposit cost that is actually spent
	{key = 'lost',     kind = 'l', field = 'g', label = 'Deposits lost',     gold = true,  color = {.95, .62, .2},  on = true},
	{key = 'earned',   kind = 's', field = 'g', label = 'Gold from sales',   gold = true,  color = {.35, .85, .4},  on = true},
	{key = 'bought',   kind = 'b', field = 'n', label = 'Items bought',      color = {.45, .62, 1}},
	{key = 'sold',     kind = 's', field = 'c', label = 'Auctions sold',     color = {.3, .85, .85}},
	{key = 'expired',  kind = 'e', field = 'c', label = 'Auctions expired',  color = {.65, .65, .65}},
}
M.RANGES = {7, 14, 30, 90}

function M.db()
	_G.AuxStatsDB = _G.AuxStatsDB or {}
	local db = _G.AuxStatsDB
	db.events = db.events or {}
	db.show = db.show or {}
	db.selected = db.selected or {}
	return db
end

-- parsed events, oldest first: {t=, k=, n=, g=, name=}
do
	local parsed, parsed_n = {}, -1
	function M.events()
		local list = db().events
		if parsed_n ~= getn(list) then
			parsed = {}
			for i = 1, getn(list) do
				local _, _, t, k, n, g, name = strfind(list[i], '^(%d+);(%a);(%-?%d+);(%-?%d+);(.*)$')
				if t then
					tinsert(parsed, {t = tonumber(t), k = k, n = tonumber(n), g = tonumber(g), name = name})
				end
			end
			parsed_n = getn(list)
		end
		return parsed
	end
end

function M.day_start(t)
	local d = date('*t', t)
	d.hour, d.min, d.sec = 0, 0, 0
	return time(d)
end

-- day starts for the last n days, oldest first, today last; and day start -> position
function M.days(n)
	local list, index = {}, {}
	local noon = day_start(time()) + 12 * 3600
	for i = n - 1, 0, -1 do
		local d = day_start(noon - i * 86400)
		tinsert(list, d)
		index[d] = getn(list)
	end
	return list, index
end

function M.short_money(copper)
	if not copper or copper == 0 then return '0' end
	if copper >= 10000 then return floor(copper / 10000 + .5) .. 'g' end
	if copper >= 100 then return floor(copper / 100 + .5) .. 's' end
	return copper .. 'c'
end

-- a pool of textures and font strings on a frame, reused on every redraw
function M.canvas(parent)
	local c = {parent = parent, tex = {}, text = {}, nt = 0, nf = 0}
	function c:reset()
		for i = 1, getn(self.tex) do self.tex[i]:Hide() end
		for i = 1, getn(self.text) do self.text[i]:Hide() end
		self.nt, self.nf = 0, 0
	end
	function c:rect(x, y, w, h, r, g, b, a)
		self.nt = self.nt + 1
		local t = self.tex[self.nt]
		if not t then
			t = self.parent:CreateTexture(nil, 'ARTWORK')
			self.tex[self.nt] = t
		end
		t:SetTexture(r, g, b, a or 1)
		t:ClearAllPoints()
		t:SetPoint('BOTTOMLEFT', self.parent, 'BOTTOMLEFT', x, y)
		t:SetWidth(math.max(1, w))
		t:SetHeight(math.max(1, h))
		t:Show()
		return t
	end
	function c:label(x, y, s, justify, r, g, b)
		self.nf = self.nf + 1
		local f = self.text[self.nf]
		if not f then
			f = self.parent:CreateFontString(nil, 'OVERLAY')
			f:SetFont(gui.font, 11)
			self.text[self.nf] = f
		end
		f:SetText(s)
		f:SetTextColor(r or .7, g or .7, b or .7)
		f:ClearAllPoints()
		local point = justify == 'RIGHT' and 'BOTTOMRIGHT' or justify == 'CENTER' and 'BOTTOM' or 'BOTTOMLEFT'
		f:SetPoint(point, self.parent, 'BOTTOMLEFT', x, y)
		f:Show()
		return f
	end
	-- a line of small squares from (x0, y0) to (x1, y1)
	function c:line(x0, y0, x1, y1, size, r, g, b)
		local steps = math.max(1, math.ceil(math.max(math.abs(x1 - x0), math.abs(y1 - y0)) / 2))
		for k = 0, steps do
			local f = k / steps
			self:rect(x0 + (x1 - x0) * f - size / 2, y0 + (y1 - y0) * f - size / 2, size, size, r, g, b)
		end
	end
	return c
end

-- range buttons along the top of a tab; on_change(days)
function M.range_buttons(parent, anchor_x, get, set)
	local buttons = {}
	for i, n in ipairs(RANGES) do
		local btn = gui.checkbutton(parent, gui.font_size.small)
		gui.set_size(btn, 58, 20)
		btn:SetPoint('TOPLEFT', aux.frame.content, 'TOPLEFT', anchor_x + (i - 1) * 62, -6)
		btn:SetText(n .. ' days')
		btn.days = n
		btn:SetScript('OnClick', function()
			set(this.days)
			for _, b in ipairs(buttons) do b:SetChecked(b.days == this.days) end
		end)
		tinsert(buttons, btn)
	end
	for _, b in ipairs(buttons) do b:SetChecked(b.days == get()) end
	return buttons
end

------------------------------------------------------------------------------

function tab.OPEN()
	frame:Show()
	draw()
end

function tab.CLOSE()
	frame:Hide()
end

local function shown(s)
	local v = db().show[s.key]
	if v == nil then return s.on and true or false end
	return v
end

function aux.handle.INIT_UI()
	frame = CreateFrame('Frame', nil, aux.frame)
	frame:SetAllPoints()
	frame:Hide()

	range_buttons(frame, 4, function() return db().stats_days or 30 end,
		function(n) db().stats_days = n draw() end)

	-- one checkbox per series, coloured like its bars
	checks = {}
	for i, s in ipairs(SERIES) do
		local cb = gui.checkbox(frame)
		cb:SetPoint('TOPLEFT', aux.frame.content, 'TOPLEFT', 4 + (i - 1) * 124, -32)
		local text = cb:CreateFontString(nil, 'OVERLAY')
		text:SetFont(gui.font, 12)
		text:SetPoint('LEFT', cb, 'RIGHT', 2, 0)
		text:SetText(s.label)
		text:SetTextColor(s.color[1], s.color[2], s.color[3])
		cb.series = s
		cb:SetChecked(shown(s))
		cb:SetScript('OnClick', function()
			db().show[this.series.key] = this:GetChecked() and true or false
			draw()
		end)
		tinsert(checks, cb)
	end

	graph = gui.panel(frame)
	graph:SetPoint('TOPLEFT', aux.frame.content, 'TOPLEFT', 0, -56)
	graph:SetPoint('BOTTOMRIGHT', aux.frame.content, 'BOTTOMRIGHT', 0, 0)
	canvas_ = canvas(graph)

	hover = CreateFrame('Frame', nil, graph)
	hover:SetAllPoints()
	hover:EnableMouse(true)
	hover:SetScript('OnLeave', function() GameTooltip:Hide() this.day = nil if this.mark then this.mark:Hide() end end)
	hover:SetScript('OnUpdate', function() if MouseIsOver(this) then hover_update() end end)

	totals = frame:CreateFontString(nil, 'OVERLAY')
	totals:SetFont(gui.font, 13)
	totals:SetPoint('TOPLEFT', aux.frame.content, 'BOTTOMLEFT', 4, -12)
	totals:SetJustifyH('LEFT')
end

local LEFT, RIGHT, TOP, BOTTOM = 56, 44, 12, 20

-- money text that still reads as money when it is zero ('0c', not a bare '0')
local function gold_text(v)
	if not v or v == 0 then return '|cffa0a0a00c' .. FONT_COLOR_CODE_CLOSE end
	return money.to_string2(v)
end

-- sums[day][series key]
local function sums(days, index)
	local out = {}
	for i = 1, getn(days) do out[i] = {} end
	for _, e in ipairs(events()) do
		local i = index[day_start(e.t)]
		if i then
			for _, s in ipairs(SERIES) do
				if e.k == s.kind then
					local v = s.field == 'g' and e.g or s.field == 'n' and math.max(e.n, 1) or 1
					out[i][s.key] = (out[i][s.key] or 0) + v
				end
			end
		end
	end
	return out
end

function M.draw()
	if not frame or not frame:IsShown() then return end
	local c = canvas_
	c:reset()
	local w, h = graph:GetWidth() - LEFT - RIGHT, graph:GetHeight() - TOP - BOTTOM
	if w <= 0 or h <= 0 then
		-- not laid out yet: try again next frame
		frame:SetScript('OnUpdate', function() this:SetScript('OnUpdate', nil) draw() end)
		return
	end
	local n = db().stats_days or 30
	local days, index = days(n)
	local data = sums(days, index)
	view = {days = days, data = data, w = w}

	local on = {}
	local max_gold, max_count = 0, 0
	for _, s in ipairs(SERIES) do
		if shown(s) then
			tinsert(on, s)
			for i = 1, n do
				local v = data[i][s.key] or 0
				if s.gold then max_gold = math.max(max_gold, v) else max_count = math.max(max_count, v) end
			end
		end
	end

	-- grid and axis labels
	for k = 0, 4 do
		local y = BOTTOM + h * k / 4
		c:rect(LEFT, y, w, 1, 1, 1, 1, k == 0 and .25 or .07)
		if max_gold > 0 then c:label(LEFT - 4, y - 5, short_money(max_gold * k / 4), 'RIGHT') end
		if max_count > 0 then c:label(LEFT + w + 4, y - 5, floor(max_count * k / 4 + .5), 'LEFT') end
	end
	local step = math.max(1, floor(n / 7))
	for i = n, 1, -step do
		c:label(LEFT + (i - .5) * w / n, 4, date('%b %d', days[i]), 'CENTER')
	end

	-- bars
	local slot = w / n
	local k = getn(on)
	if k > 0 then
		local bw = math.max(1, (slot * .8) / k)
		for i = 1, n do
			for j, s in ipairs(on) do
				local v = data[i][s.key] or 0
				local top = s.gold and max_gold or max_count
				if v > 0 and top > 0 then
					c:rect(LEFT + (i - 1) * slot + slot * .1 + (j - 1) * bw, BOTTOM, math.max(1, bw - (bw > 3 and 1 or 0)),
						v / top * h, s.color[1], s.color[2], s.color[3], .9)
				end
			end
		end
	end
	if k == 0 then
		c:label(LEFT + w / 2, BOTTOM + h / 2, 'Tick something above to graph it.', 'CENTER')
	elseif getn(events()) == 0 then
		c:label(LEFT + w / 2, BOTTOM + h / 2, 'Nothing recorded yet: buying, posting and collecting your auction mail fills this in.', 'CENTER')
	end

	-- totals for the range
	local t = {}
	for i = 1, n do
		for key, v in pairs(data[i]) do t[key] = (t[key] or 0) + v end
	end
	local net = (t.earned or 0) - (t.spent or 0) - (t.lost or 0)
	totals:SetText(format('Last %d days:  spent %s   deposits lost %s   from sales %s   net %s%s',
		n, gold_text(t.spent), gold_text(t.lost),
		gold_text(t.earned), net < 0 and '-' or '', gold_text(math.abs(net))))
end

function M.hover_update()
	if not view then return end
	local x = GetCursorPosition() / graph:GetEffectiveScale() - graph:GetLeft() - LEFT
	local n = getn(view.days)
	local i = floor(x / view.w * n) + 1
	if i < 1 or i > n then GameTooltip:Hide() hover.day = nil if hover.mark then hover.mark:Hide() end return end
	if hover.day == i then return end
	hover.day = i
	if not hover.mark then
		hover.mark = hover:CreateTexture(nil, 'BACKGROUND')
		hover.mark:SetTexture(1, 1, 1, .06)
	end
	hover.mark:ClearAllPoints()
	hover.mark:SetPoint('TOPLEFT', graph, 'TOPLEFT', LEFT + (i - 1) * view.w / n, -TOP)
	hover.mark:SetWidth(view.w / n)
	hover.mark:SetHeight(graph:GetHeight() - TOP - BOTTOM)
	hover.mark:Show()
	GameTooltip:SetOwner(hover, 'ANCHOR_CURSOR')
	GameTooltip:AddLine(date('%A %b %d', view.days[i]))
	for _, s in ipairs(SERIES) do
		local v = view.data[i][s.key]
		if v then
			GameTooltip:AddDoubleLine(s.label, s.gold and gold_text(v) or v, s.color[1], s.color[2], s.color[3], 1, 1, 1)
		end
	end
	GameTooltip:Show()
end
