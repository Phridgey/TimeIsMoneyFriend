module 'aux.tabs.itemstats'

-- Local addition: the Trades tab. Tick items you have traded; the graph shows each
-- one's lowest auction house price per day (from aux's history, which keeps about 11
-- days), your own purchase and sale prices as markers, and below it how many you bought
-- (bars up) and sold (bars down) each day.

local aux = require 'aux'
local gui = require 'aux.gui'
local money = require 'aux.util.money'
local history = require 'aux.core.history'
local cache = require 'aux.util.info'   -- core\cache.lua adds its functions to this module
local stats = require 'aux.tabs.stats'

local tab = aux.tab 'Trades'

-- Groups shown above the items: everything you traded that matches, added together.
-- quality 2 = green (uncommon); levels are required levels, as in aux's level searches.
-- all green gear: never listed itself; its pieces are listed through the groups below,
-- or as 'Other green gear' when no group takes them
local GEAR = {quality = 2, min = 0, max = 100, class = {Armor = true, Weapon = true}}
local OTHER = {name = 'Other green gear', other = true}

local GROUPS = {
	{name = 'Level 41-45 green armour', quality = 2, min = 41, max = 45, class = 'Armor'},
	{name = 'Level 41-45 green weapons', quality = 2, min = 41, max = 45, class = 'Weapon'},
	{name = 'Level 51-55 green armour', quality = 2, min = 51, max = 55, class = 'Armor'},
	{name = 'Level 51-55 green weapons', quality = 2, min = 51, max = 55, class = 'Weapon'},
	{name = 'Level 56-60 green armour', quality = 2, min = 56, max = 60, class = 'Armor'},
	{name = 'Level 56-60 green weapons', quality = 2, min = 56, max = 60, class = 'Weapon'},
}

-- item name -> its details (quality, level, class), looked up once
local details = {}
local function item_details(name)
	if details[name] == nil then
		-- random-suffix greens ("... of the Eagle") are stored under their base name
		local id = cache.item_id(name)
			or cache.item_id((string.gsub(name, ' of the [%a\' ]+$', '')))
			or cache.item_id((string.gsub(name, ' of [%a\' ]+$', '')))
		-- aux's saved item list first (known good), else the game's item info
		-- (aux's saved data is the most reliable source for quality, level and type)
		local d
		if id then
			local it = cache.item_info(id)
			if it and it.quality then
				d = {quality = tonumber(it.quality), level = tonumber(it.level), class = it.class}
			else
				local _, _, quality, level, class = GetItemInfo('item:' .. id .. ':0:0:0')
				if quality then d = {quality = tonumber(quality), level = tonumber(level), class = class} end
			end
		end
		details[name] = d or false
	end
	return details[name]
end

local function in_group(group, name)
	local d = item_details(name)
	if not (d and d.quality == group.quality and d.level and d.level >= group.min and d.level <= group.max) then
		return false
	end
	if type(group.class) == 'table' then return group.class[d.class] end
	return d.class == group.class
end

local function in_other(name)
	if not in_group(GEAR, name) then return false end
	for _, g in ipairs(GROUPS) do
		if in_group(g, name) then return false end
	end
	return true
end

-- does an event's item belong to this list entry (an item, or a group)?
local function matches(entry, name)
	if entry.group then
		if entry.group.other then return in_other(name) end
		return in_group(entry.group, name)
	end
	return name == entry.name
end

local COLORS = {{.35, .7, .95}, {.95, .55, .3}, {.5, .9, .4}, {.9, .4, .8}, {.95, .85, .3}, {.6, .6, 1}}
local ROWS, ROW_H = 15, 19
local LEFT, RIGHT, TOP, BOTTOM = 56, 12, 12, 20

function tab.OPEN()
	frame:Show()
	-- report a failure instead of leaving a half-built window
	local ok, err = pcall(function() build_items() update_list() draw() end)
	if not ok then
		DEFAULT_CHAT_FRAME:AddMessage('|cffff5555aux Trades error:|r ' .. tostring(err))
	end
end

function tab.CLOSE()
	frame:Hide()
end

-- traded items, most recently traded first: {name=, bought=, sold=, last=}
function M.build_items()
	local by = {}
	items = {}
	for _, e in ipairs(stats.events()) do
		-- green gear is shown only through the groups, not one row per piece
		if e.name and e.name ~= '?' and (e.k == 'b' or e.k == 's' or e.k == 'd' or e.k == 'e' or e.k == 'c')
				and not in_group(GEAR, e.name) then
			local it = by[e.name]
			if not it then
				it = {name = e.name, bought = 0, sold = 0, last = 0}
				by[e.name] = it
				tinsert(items, it)
			end
			if e.k == 'b' then it.bought = it.bought + math.max(e.n, 1) end
			if e.k == 's' then it.sold = it.sold + (e.n > 0 and e.n or 1) end
			if e.t > it.last then it.last = e.t end
		end
	end
	sort(items, function(a, b) return a.last > b.last end)
	-- groups first, but only those you have traded something in
	local groups = {}
	for _, g in ipairs(GROUPS) do tinsert(groups, g) end
	tinsert(groups, OTHER)
	for k = getn(groups), 1, -1 do
		local g = groups[k]
		local it = {name = g.name, group = g, bought = 0, sold = 0, last = 0}
		local traded = false
		for _, e in ipairs(stats.events()) do
			if (e.k == 'b' or e.k == 's') and matches(it, e.name) then
				traded = true
				if e.k == 'b' then it.bought = it.bought + math.max(e.n, 1) end
				if e.k == 's' then it.sold = it.sold + (e.n > 0 and e.n or 1) end
			end
		end
		if traded then tinsert(items, 1, it) end
	end
	offset = math.max(0, math.min(offset or 0, getn(items) - ROWS))
end

-- selected names in a fixed order, each with its colour
function M.selection()
	local sel = {}
	for _, it in ipairs(items or {}) do
		if stats.db().selected[it.name] then
			local c = COLORS[math.mod(getn(sel), getn(COLORS)) + 1]
			tinsert(sel, {name = it.name, color = c, entry = it})
		end
	end
	return sel
end

function aux.handle.INIT_UI()
	frame = CreateFrame('Frame', nil, aux.frame)
	frame:SetAllPoints()
	frame:Hide()

	stats.range_buttons(frame, 236, function() return stats.db().item_days or 14 end,
		function(n) stats.db().item_days = n draw() end)

	list = gui.panel(frame)
	list:SetPoint('TOPLEFT', aux.frame.content, 'TOPLEFT', 0, 0)
	list:SetPoint('BOTTOMLEFT', aux.frame.content, 'BOTTOMLEFT', 0, 0)
	list:SetWidth(228)
	list:EnableMouseWheel(true)
	list:SetScript('OnMouseWheel', function()
		offset = math.max(0, math.min((offset or 0) - arg1 * 3, getn(items or {}) - ROWS))
		update_list()
	end)
	rows = {}
	for i = 1, ROWS do
		local cb = gui.checkbox(list)
		cb:SetPoint('TOPLEFT', list, 'TOPLEFT', 6, -6 - (i - 1) * ROW_H)
		cb:SetWidth(16) cb:SetHeight(16)
		cb.text = cb:CreateFontString(nil, 'OVERLAY')
		cb.text:SetFont(gui.font, 12)
		cb.text:SetPoint('LEFT', cb, 'RIGHT', 4, 0)
		cb.text:SetWidth(200)
		cb.text:SetJustifyH('LEFT')
		cb:SetScript('OnClick', function()
			if not this.item then return end
			stats.db().selected[this.item.name] = this:GetChecked() and true or nil
			update_list()
			draw()
		end)
		cb:Hide()
		rows[i] = cb
	end
	empty = list:CreateFontString(nil, 'OVERLAY')
	empty:SetFont(gui.font, 12)
	empty:SetPoint('TOPLEFT', list, 'TOPLEFT', 8, -8)
	empty:SetWidth(210)
	empty:SetJustifyH('LEFT')
	empty:SetText('Items appear here once you buy, post or sell them.')

	graph = gui.panel(frame)
	graph:SetPoint('TOPLEFT', list, 'TOPRIGHT', 4, -28)
	graph:SetPoint('BOTTOMRIGHT', aux.frame.content, 'BOTTOMRIGHT', 0, 0)
	canvas_ = stats.canvas(graph)

	hover = CreateFrame('Frame', nil, graph)
	hover:SetAllPoints()
	hover:EnableMouse(true)
	hover:SetScript('OnLeave', function() GameTooltip:Hide() this.day = nil if this.mark then this.mark:Hide() end end)
	hover:SetScript('OnUpdate', function() if MouseIsOver(this) then hover_update() end end)

	note = frame:CreateFontString(nil, 'OVERLAY')
	note:SetFont(gui.font, 12)
	note:SetPoint('TOPLEFT', aux.frame.content, 'BOTTOMLEFT', 4, -12)
	note:SetJustifyH('LEFT')
	note:SetTextColor(.7, .7, .7)
	note:SetText('Line: lowest AH price.  Square: what you paid.  Ringed: what you sold for.  Bars: bought up, sold down.')
end

function M.update_list()
	if not rows then return end
	local sel = selection()
	local color_of = {}
	for _, s in ipairs(sel) do color_of[s.name] = s.color end
	empty:SetText(getn(items or {}) == 0 and 'Items appear here once you buy, post or sell them.' or '')
	for i = 1, ROWS do
		local cb, it = rows[i], items and items[(offset or 0) + i]
		cb.item = it
		if it then
			cb:Show()
			cb:SetChecked(stats.db().selected[it.name] and 1 or nil)
			local c = color_of[it.name]
			local counts = format('|cff8c8c8c  %d / %d|r', it.bought, it.sold)
			cb.text:SetText((it.group and '|cffffd100Group:|r ' or '') .. it.name .. counts)
			if c then cb.text:SetTextColor(c[1], c[2], c[3]) else cb.text:SetTextColor(.85, .85, .85) end
		else
			cb:Hide()
		end
	end
end

-- per selected item, per day: low price, your buys and sells
local function item_days(entry, index, n)
	local d = {}
	for i = 1, n do d[i] = {} end
	local name = entry.name
	local id = not entry.group and cache.item_id(name)
	if id then
		local key = id .. ':0'
		for _, p in ipairs(history.data_points(key)) do
			local i = index[stats.day_start(p.time - 1)]
			if i then d[i].low = p.value end
		end
		local today = history.market_value(key)
		if today then d[n].low = math.min(today, d[n].low or today) end
	end
	for _, e in ipairs(stats.events()) do
		if (e.k == 'b' or e.k == 's') and matches(entry, e.name) then
			local i = index[stats.day_start(e.t)]
			if i then
				local side = e.k == 'b' and 'buy' or 'sell'
				if e.n > 0 then
					d[i][side] = (d[i][side] or 0) + e.n
					d[i][side .. 'g'] = (d[i][side .. 'g'] or 0) + e.g
				else
					-- a sale whose stack size was not recorded (posted before AuxStats)
					d[i].unknown = (d[i].unknown or 0) + 1
				end
			end
		end
	end
	return d
end

function M.draw()
	if not frame or not frame:IsShown() then return end
	local c = canvas_
	c:reset()
	local w, h = graph:GetWidth() - LEFT - RIGHT, graph:GetHeight() - TOP - BOTTOM
	if w <= 0 or h <= 0 then
		frame:SetScript('OnUpdate', function() this:SetScript('OnUpdate', nil) draw() end)
		return
	end
	local n = stats.db().item_days or 14
	local days, index = stats.days(n)
	local sel = selection()
	local per = {}
	local top_price, top_qty = 0, 0
	for k, s in ipairs(sel) do
		per[k] = item_days(s.entry, index, n)
		for i = 1, n do
			local d = per[k][i]
			top_price = math.max(top_price, d.low or 0, d.buy and d.buyg / d.buy or 0, d.sell and d.sellg / d.sell or 0)
			top_qty = math.max(top_qty, d.buy or 0, d.sell or 0)
		end
	end
	view = {days = days, sel = sel, per = per, w = w}

	-- price area on top, quantity area below with its middle line at qy
	local ph = h * .62
	local py = BOTTOM + h - ph
	local qh = h - ph - 10
	local qy = BOTTOM + qh / 2
	for k = 0, 3 do
		local y = py + ph * k / 3
		c:rect(LEFT, y, w, 1, 1, 1, 1, k == 0 and .2 or .07)
		if top_price > 0 then c:label(LEFT - 4, y - 5, short(top_price * k / 3), 'RIGHT') end
	end
	c:rect(LEFT, qy, w, 1, 1, 1, 1, .2)
	if top_qty > 0 then
		c:label(LEFT - 4, qy + qh / 2 - 5, top_qty, 'RIGHT', .5, .5, .5)
		c:label(LEFT - 4, qy - qh / 2 - 5, top_qty, 'RIGHT', .5, .5, .5)
	end
	local step = math.max(1, floor(n / 6))
	for i = n, 1, -step do
		c:label(LEFT + (i - .5) * w / n, 4, date('%b %d', days[i]), 'CENTER')
	end

	if getn(sel) == 0 then
		c:label(LEFT + w / 2, py + ph / 2, 'Tick items on the left to graph them.', 'CENTER')
		return
	end

	local slot = w / n
	local function X(i) return LEFT + (i - .5) * slot end
	local function Y(v) return py + (top_price > 0 and v / top_price * ph or 0) end
	local bw = math.max(1, slot * .7 / getn(sel))
	for k, s in ipairs(sel) do
		local r, g, b = s.color[1], s.color[2], s.color[3]
		local d = per[k]
		-- price line through the days that have a price
		local last
		for i = 1, n do
			if d[i].low then
				if last then c:line(X(last), Y(d[last].low), X(i), Y(d[i].low), 2, r, g, b)
				else c:rect(X(i) - 1, Y(d[i].low) - 1, 2, 2, r, g, b) end
				last = i
			end
		end
		for i = 1, n do
			local x0 = LEFT + (i - 1) * slot + slot * .15 + (k - 1) * bw
			if d[i].buy then
				local y = Y(d[i].buyg / d[i].buy)
				c:rect(X(i) - 3, y - 3, 6, 6, r, g, b)
				if top_qty > 0 then c:rect(x0, qy, bw - (bw > 3 and 1 or 0), d[i].buy / top_qty * qh / 2, r, g, b, .9) end
			end
			if d[i].sell then
				local y = Y(d[i].sellg / d[i].sell)
				c:rect(X(i) - 4, y - 4, 8, 8, 1, 1, 1)
				c:rect(X(i) - 3, y - 3, 6, 6, r, g, b)
				if top_qty > 0 then
					local hh = d[i].sell / top_qty * qh / 2
					c:rect(x0, qy - hh, bw - (bw > 3 and 1 or 0), hh, r * .7, g * .7, b * .7, .9)
				end
			end
		end
	end
end

function M.short(copper)
	return stats.short_money(floor(copper + .5))
end

function M.hover_update()
	if not view then return end
	local x = GetCursorPosition() / graph:GetEffectiveScale() - graph:GetLeft() - LEFT
	local n = getn(view.days)
	local i = floor(x / view.w * n) + 1
	if i < 1 or i > n or getn(view.sel) == 0 then
		GameTooltip:Hide() hover.day = nil if hover.mark then hover.mark:Hide() end return
	end
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
	for k, s in ipairs(view.sel) do
		local d = view.per[k][i]
		local r, g, b = s.color[1], s.color[2], s.color[3]
		if d.low or d.buy or d.sell or d.unknown then
			GameTooltip:AddLine(s.name, r, g, b)
			if d.low then GameTooltip:AddDoubleLine('  lowest on AH', money.to_string2(d.low), .8, .8, .8, 1, 1, 1) end
			if d.buy then GameTooltip:AddDoubleLine('  you bought ' .. d.buy, 'at ' .. money.to_string2(floor(d.buyg / d.buy + .5)) .. ' each', .8, .8, .8, 1, 1, 1) end
			if d.sell then GameTooltip:AddDoubleLine('  you sold ' .. d.sell, 'at ' .. money.to_string2(floor(d.sellg / d.sell + .5)) .. ' each', .8, .8, .8, 1, 1, 1) end
			if d.unknown then GameTooltip:AddLine('  plus ' .. d.unknown .. ' sale(s) of unknown stack size', .6, .6, .6) end
		end
	end
	GameTooltip:Show()
end
