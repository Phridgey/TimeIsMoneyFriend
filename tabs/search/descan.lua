module 'aux.descan'

-- Local addition: Disenchant scan. One button searches the auction house for green and
-- blue gear under set prices (per level band and kind), lists what it found in a window
-- with every item ticked, and "Buy" buys the ticked ones. /timf descan changes the prices.

local aux = require 'aux'
local gui = require 'aux.gui'
local money = require 'aux.util.money'
local scan = require 'aux.core.scan'

-- levels are required levels, as in the auction house's own level search
local GROUPS = {
	{key = 'armor51',  label = '51-59 green armour',  quality = 2, min = 51, max = 59, kind = 'armor',  price = 20100},
	{key = 'blue51',   label = '51-59 blues',         quality = 3, min = 51, max = 59, kind = 'any',    price = 21000},
	{key = 'weapon51', label = '51-55 green weapons', quality = 2, min = 51, max = 55, kind = 'weapon', price = 50000},
	{key = 'shield51', label = '51-55 green shields', quality = 2, min = 51, max = 55, kind = 'shield', price = 50000},
	{key = 'weapon56', label = '56-60 green weapons', quality = 2, min = 56, max = 60, kind = 'weapon', price = 90000},
	{key = 'shield56', label = '56-60 green shields', quality = 2, min = 56, max = 60, kind = 'shield', price = 90000},
	{key = 'armor41',  label = '41-45 green armour',  quality = 2, min = 41, max = 45, kind = 'armor',  price = 8500},
	{key = 'weapon41', label = '41-45 green weapons', quality = 2, min = 41, max = 45, kind = 'weapon', price = 32500},
	{key = 'shield41', label = '41-45 green shields', quality = 2, min = 41, max = 45, kind = 'shield', price = 32500},
}

-- the searches sent to the auction house: weapons and armour (shields are armour) of
-- green or better in the two level bands, so every auction is looked at once
local SEARCHES = {
	{class = 1, min_level = 41, max_level = 45, quality = 2},
	{class = 2, min_level = 41, max_level = 45, quality = 2},
	{class = 1, min_level = 51, max_level = 60, quality = 2},
	{class = 2, min_level = 51, max_level = 60, quality = 2},
}

local function prices()
	aux.account_data.de_scan = aux.account_data.de_scan or {}
	return aux.account_data.de_scan
end

local function limit(group)
	return prices()[group.key] or group.price
end

local function queries()
	local list = {}
	for i = 1, getn(SEARCHES) do
		local s = SEARCHES[i]
		tinsert(list, {blizzard_query = {min_level = s.min_level, max_level = s.max_level, class = s.class, quality = s.quality}})
	end
	return list
end

local WEAPON, ARMOR
local function group_of(a)
	if not WEAPON then WEAPON, ARMOR = GetAuctionItemClasses() end
	if not a.buyout_price or a.buyout_price <= 0 or not a.level then return end
	if a.owner and a.owner == UnitName('player') then return end
	local kind
	if a.slot == 'INVTYPE_SHIELD' then kind = 'shield'
	elseif a.class == WEAPON then kind = 'weapon'
	elseif a.class == ARMOR then kind = 'armor' end
	if not kind then return end
	for i = 1, getn(GROUPS) do
		local g = GROUPS[i]
		if a.quality == g.quality and a.level >= g.min and a.level <= g.max and (g.kind == 'any' or g.kind == kind) then
			if a.unit_buyout_price <= limit(g) then return g end
			return
		end
	end
end

------------------------------------------------------------------------------
-- the window
------------------------------------------------------------------------------
local ROWS, ROW_HEIGHT = 18, 20
local found = {}      -- {record, group, checked, bought}
local window, rows, status, buy_button, rescan_button
local offset = 0
local busy            -- 'scan' or 'buy' while working

local function checked_total()
	local n, total = 0, 0
	for i = 1, getn(found) do
		local f = found[i]
		if f.checked and not f.bought then n = n + 1 total = total + f.record.buyout_price end
	end
	return n, total
end

local function update()
	if not window then return end
	local n = getn(found)
	offset = max(0, min(offset, n - ROWS))
	for i = 1, ROWS do
		local row = rows[i]
		local f = found[i + offset]
		if f then
			local r = f.record
			row.item = f
			row.check:SetChecked(f.checked and not f.bought)
			if f.bought then row.check:Disable() else row.check:Enable() end
			row.icon:SetTexture(r.texture)
			local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[r.quality]
			row.name:SetText((color and color.hex or '') .. r.name .. FONT_COLOR_CODE_CLOSE .. (f.bought and ' |cff40ff40(bought)|r' or ''))
			row.level:SetText(r.level)
			row.price:SetText(money.to_string(r.buyout_price, nil, true))
			row.group:SetText(f.group.label)
			row:Show()
		else
			row.item = nil
			row:Hide()
		end
	end
	local c, total = checked_total()
	if busy == 'scan' then
		buy_button:Disable()
	elseif busy == 'buy' then
		buy_button:Disable()
	else
		if c > 0 then buy_button:Enable() else buy_button:Disable() end
		status:SetText(format('%d found, %d ticked: %s', n, c, money.to_string(total, nil, true)))
	end
	buy_button:SetText(format('Buy %d', c))
	if busy then rescan_button:Disable() else rescan_button:Enable() end
end

local function create_window()
	window = CreateFrame('Frame', 'TIMFDisenchantScan', UIParent)
	gui.set_window_style(window)
	window:SetWidth(470)
	window:SetHeight(ROWS * ROW_HEIGHT + 78)
	window:SetPoint('TOPLEFT', aux.frame, 'TOPRIGHT', 6, 0)
	window:SetToplevel(true)
	window:SetMovable(true)
	window:EnableMouse(true)
	window:RegisterForDrag('LeftButton')
	window:SetScript('OnDragStart', function() this:StartMoving() end)
	window:SetScript('OnDragStop', function() this:StopMovingOrSizing() end)
	window:EnableMouseWheel(true)
	window:SetScript('OnMouseWheel', function()
		offset = offset - arg1 * 3
		update()
	end)
	window:SetScript('OnHide', function()
		if busy then scan.abort() end
	end)
	tinsert(UISpecialFrames, 'TIMFDisenchantScan')

	local title = gui.label(window, gui.font_size.medium)
	title:SetPoint('TOPLEFT', 10, -8)
	title:SetText('Disenchant scan')

	rows = {}
	for i = 1, ROWS do
		local row = CreateFrame('Button', nil, window)
		row:SetHeight(ROW_HEIGHT)
		row:SetPoint('TOPLEFT', 8, -28 - (i - 1) * ROW_HEIGHT)
		row:SetPoint('RIGHT', window, 'RIGHT', -8, 0)
		local hl = row:CreateTexture(nil, 'HIGHLIGHT')
		hl:SetAllPoints()
		hl:SetTexture(1, 1, 1, .1)

		local check = gui.checkbox(row)
		check:SetPoint('LEFT', 2, 0)
		check:SetScript('OnClick', function()
			local f = this:GetParent().item
			if f and not f.bought then f.checked = this:GetChecked() and true or false end
			update()
		end)
		row.check = check

		local icon = row:CreateTexture(nil, 'ARTWORK')
		icon:SetWidth(ROW_HEIGHT - 2)
		icon:SetHeight(ROW_HEIGHT - 2)
		icon:SetPoint('LEFT', check, 'RIGHT', 4, 0)
		row.icon = icon

		row.name = gui.label(row, gui.font_size.small)
		row.name:SetPoint('LEFT', icon, 'RIGHT', 4, 0)
		row.name:SetWidth(175)
		row.name:SetJustifyH('LEFT')

		row.level = gui.label(row, gui.font_size.small)
		row.level:SetPoint('LEFT', row.name, 'RIGHT', 2, 0)
		row.level:SetWidth(22)
		row.level:SetJustifyH('RIGHT')

		row.price = gui.label(row, gui.font_size.small)
		row.price:SetPoint('LEFT', row.level, 'RIGHT', 4, 0)
		row.price:SetWidth(70)
		row.price:SetJustifyH('RIGHT')

		row.group = gui.label(row, gui.font_size.small)
		row.group:SetPoint('LEFT', row.price, 'RIGHT', 8, 0)
		row.group:SetPoint('RIGHT', row, 'RIGHT', -2, 0)
		row.group:SetJustifyH('LEFT')
		row.group:SetTextColor(.6, .6, .6)

		row:SetScript('OnEnter', function()
			if this.item then
				GameTooltip:SetOwner(this, 'ANCHOR_LEFT')
				GameTooltip:SetHyperlink(this.item.record.itemstring)
				GameTooltip:AddLine('Seller: ' .. (this.item.record.owner or '?'), .7, .7, .7)
				GameTooltip:Show()
			end
		end)
		row:SetScript('OnLeave', function() GameTooltip:Hide() end)
		row:SetScript('OnClick', function()
			local f = this.item
			if not f or f.bought then return end
			if IsShiftKeyDown() and ChatFrameEditBox:IsVisible() then
				ChatFrameEditBox:Insert(f.record.link)
				return
			end
			f.checked = not f.checked
			update()
		end)
		rows[i] = row
	end

	status = gui.label(window, gui.font_size.small)
	status:SetPoint('BOTTOMLEFT', 10, 14)
	status:SetWidth(200)
	status:SetJustifyH('LEFT')

	local close = gui.button(window, gui.font_size.small)
	close:SetPoint('BOTTOMRIGHT', -8, 8)
	gui.set_size(close, 60, 24)
	close:SetText('Close')
	close:SetScript('OnClick', function() window:Hide() end)

	buy_button = gui.button(window, gui.font_size.small)
	buy_button:SetPoint('RIGHT', close, 'LEFT', -5, 0)
	gui.set_size(buy_button, 70, 24)
	buy_button:SetScript('OnClick', function() M.buy() end)

	rescan_button = gui.button(window, gui.font_size.small)
	rescan_button:SetPoint('RIGHT', buy_button, 'LEFT', -5, 0)
	gui.set_size(rescan_button, 70, 24)
	rescan_button:SetText('Rescan')
	rescan_button:SetScript('OnClick', function() M.start() end)
end

------------------------------------------------------------------------------
-- scanning and buying
------------------------------------------------------------------------------
local function at_auction_house()
	return AuctionFrame and aux.frame and aux.frame:IsShown() and not aux.is_away()
end

function M.start()
	if busy then return end
	if not at_auction_house() then aux.print('Disenchant scan: open the auction house first.') return end
	if not window then create_window() end
	window:Show()
	for i = getn(found), 1, -1 do tremove(found, i) end
	offset = 0
	busy = 'scan'
	local query_no, page_no = 0, 0
	scan.start{
		type = 'list',
		queries = queries(),
		on_start_query = function()
			query_no = query_no + 1
			page_no = 0
		end,
		on_page_loaded = function(_, total_pages)
			page_no = page_no + 1
			status:SetText(format('Scanning %d / %d (page %d / %d)', query_no, getn(SEARCHES), page_no, max(total_pages, 1)))
		end,
		on_auction = function(record)
			local g = group_of(record)
			if g then tinsert(found, {record = record, group = g, checked = true}) end
		end,
		on_page_scanned = function() update() end,
		on_complete = function()
			busy = nil
			table.sort(found, function(a, b)
				if a.group ~= b.group then return a.group.key < b.group.key end
				return a.record.unit_buyout_price < b.record.unit_buyout_price
			end)
			update()
		end,
		on_abort = function()
			busy = nil
			update()
			status:SetText('Scan stopped.')
		end,
	}
	update()
end

function M.buy()
	if busy then return end
	if not at_auction_house() then aux.print('Disenchant scan: open the auction house first.') return end
	-- how many of each listing to buy (identical auctions share a signature)
	local wanted, left = {}, 0
	for i = 1, getn(found) do
		local f = found[i]
		if f.checked and not f.bought then
			local s = f.record.search_signature
			wanted[s] = (wanted[s] or 0) + 1
			left = left + 1
		end
	end
	if left == 0 then return end
	busy = 'buy'
	local bought = 0
	status:SetText('Buying...')
	local function mark(signature)
		for i = 1, getn(found) do
			local f = found[i]
			if f.checked and not f.bought and f.record.search_signature == signature then
				f.bought = true
				return
			end
		end
	end
	scan.start{
		type = 'list',
		queries = queries(),
		auto_buy_validator = function(record)
			local s = record.search_signature
			if (wanted[s] or 0) > 0 and GetMoney() >= record.buyout_price then
				wanted[s] = wanted[s] - 1
				left = left - 1
				bought = bought + 1
				mark(s)
				status:SetText(format('Bought %d, %d to go...', bought, left))
				update()
				if left == 0 then scan.stop() end
				return true
			end
		end,
		on_complete = function()
			busy = nil
			update()
			status:SetText(format('Bought %d.%s', bought, left > 0 and format(' %d no longer listed.', left) or ''))
		end,
		on_abort = function()
			busy = nil
			update()
			status:SetText(format('Stopped: bought %d.', bought))
		end,
	}
	update()
end

------------------------------------------------------------------------------
-- /timf descan [group price | reset]
------------------------------------------------------------------------------
function M.slash(arguments)
	local key, value = arguments[2] and strlower(arguments[2]), arguments[3]
	if key == nil or key == '' then
		aux.print('Disenchant scan prices (change one with /timf descan <name> <price>, e.g. /timf descan armor51 2g1s; /timf descan reset puts them back):')
		for i = 1, getn(GROUPS) do
			local g = GROUPS[i]
			local set = prices()[g.key]
			aux.print(format('- %s: %s  (%s)%s', aux.color.blue(g.key), money.to_string(limit(g), nil, true), g.label, set and '' or ' default'))
		end
		return
	end
	if key == 'reset' then
		aux.account_data.de_scan = {}
		aux.print('Disenchant scan prices put back to the defaults.')
		return
	end
	if key == 'scan' then return M.start() end
	for i = 1, getn(GROUPS) do
		local g = GROUPS[i]
		if g.key == key then
			local amount = value and money.from_string(value)
			if not amount or amount <= 0 then
				aux.print('Disenchant scan: give a price, e.g. /timf descan ' .. key .. ' 2g1s')
				return
			end
			prices()[key] = aux.round(amount)
			aux.print(format('Disenchant scan: %s now %s or less.', g.label, money.to_string(prices()[key], nil, true)))
			return
		end
	end
	aux.print('Disenchant scan: no price called "' .. key .. '". /timf descan lists them.')
end
