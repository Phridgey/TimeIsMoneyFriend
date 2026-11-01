module 'aux.descan'

-- Local addition: Disenchant scan. One button searches the auction house for green and
-- blue gear under set prices (per level band and kind), lists what it found in a window
-- with every item ticked, and "Buy" buys the ticked ones. /timf descan changes the prices.
--
-- The game only accepts a purchase from a click, so Buy takes one auction per click.
-- The scan stops on each page that has ticked auctions: they are on screen right then, so
-- each click buys one at once with no second search. When none are left on that page
-- (bought, unticked, or Next pressed) the scan carries on from the same page (buying
-- moves later auctions up onto it). Auctions passed over with Next are looked up one by
-- one after the scan, as before.

local aux = require 'aux'
local gui = require 'aux.gui'
local money = require 'aux.util.money'
local scan = require 'aux.core.scan'
local scan_util = require 'aux.util.scan'

-- levels are required levels, as in the auction house's own level search
local GROUPS = {
	{key = 'armor51',  label = '51-55 green armour',  quality = 2, min = 51, max = 55, kind = 'armor',  price = 20100},
	{key = 'armor56',  label = '56-59 green armour',  quality = 2, min = 56, max = 59, kind = 'armor',  price = 32000},
	{key = 'blue51',   label = '51-59 blues',         quality = 3, min = 51, max = 59, kind = 'any',    price = 22500},
	{key = 'weapon51', label = '51-55 green weapons', quality = 2, min = 51, max = 55, kind = 'weapon', price = 50000},
	{key = 'shield51', label = '51-55 green shields', quality = 2, min = 51, max = 55, kind = 'shield', price = 50000},
	{key = 'weapon56', label = '56-60 green weapons', quality = 2, min = 56, max = 60, kind = 'weapon', price = 90000},
	{key = 'shield56', label = '56-60 green shields', quality = 2, min = 56, max = 60, kind = 'shield', price = 90000},
	{key = 'armor41',  label = '41-45 green armour',  quality = 2, min = 41, max = 45, kind = 'armor',  price = 8500},
	{key = 'weapon41', label = '41-45 green weapons', quality = 2, min = 41, max = 45, kind = 'weapon', price = 32500},
	{key = 'shield41', label = '41-45 green shields', quality = 2, min = 41, max = 45, kind = 'shield', price = 32500},
}

for i = 1, getn(GROUPS) do GROUPS[i].order = i end

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
-- state
------------------------------------------------------------------------------
local ROWS, ROW_HEIGHT = 18, 20
local found = {}      -- {record, group, checked, bought, gone}
local window, rows, status, buy_button, rescan_button
local offset = 0
local scanning        -- the search is running
local paused          -- {qi, page}: the scan is stopped on this page for buying
local pausing         -- set while the scan winds down to a pause
local scan_gen = 0    -- each scan's number: callbacks from an older scan are ignored
local unticked, passed = {}, {}   -- by auction signature, kept when a page is read again
local target          -- the ticked auction the next Buy click buys
local target_index    -- its place on the auction house page, once found
local finding         -- looking it up
local bidding         -- a purchase is under way
local generation = 0  -- each lookup's number: answers from an older one are ignored
local bought_count = 0
local note            -- a one-off message for the status line

local function wanted(f) return f.checked and not f.bought and not f.gone end
-- ticked auctions on the page the scan is stopped on
local function on_page(f) return paused and f.qi == paused.qi and f.page == paused.page end
local function buyable_here(f) return wanted(f) and not f.passed and on_page(f) end

local function ticked_total()
	local n, total = 0, 0
	for i = 1, getn(found) do
		local f = found[i]
		if wanted(f) then n = n + 1 total = total + f.record.buyout_price end
	end
	return n, total
end

local update   -- below

local status_adapter = {
	update_status = function() end,
	set_text = function() end,
}

local function locate()
	generation = generation + 1
	local my = generation
	target, target_index, finding = nil, nil, nil
	for i = 1, getn(found) do
		if wanted(found[i]) then target = found[i] break end
	end
	if not target then update() return end
	finding = true
	update()
	local t = target
	scan_util.find(t.record, status_adapter,
		function()   -- stopped
			if my ~= generation then return end
			finding = nil
			update()
		end,
		function()   -- not listed any more
			if my ~= generation then return end
			t.gone = true
			return locate()
		end,
		function(index)
			if my ~= generation then return end
			finding = nil
			target_index = index
			update()
		end)
end

------------------------------------------------------------------------------
-- the window
------------------------------------------------------------------------------
update = function()
	if not window then return end
	local n = getn(found)
	offset = max(0, min(offset, n - ROWS))
	for i = 1, ROWS do
		local row = rows[i]
		local f = found[i + offset]
		if f then
			local r = f.record
			row.item = f
			row.check:SetChecked(wanted(f))
			if f.bought or f.gone then row.check:Disable() else row.check:Enable() end
			row.icon:SetTexture(r.texture)
			local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[r.quality]
			local tag = f.bought and ' |cff40ff40(bought)|r' or f.gone and ' |cff888888(gone)|r'
				or f == target and (target_index and ' |cffffd100<- next|r' or ' |cff888888(finding...)|r') or ''
			row.name:SetText((color and color.hex or '') .. r.name .. FONT_COLOR_CODE_CLOSE .. tag)
			row.level:SetText(r.level)
			row.price:SetText(money.to_string(r.buyout_price, nil, true))
			row.group:SetText(f.group.label)
			row:Show()
		else
			row.item = nil
			row:Hide()
		end
	end
	local c, total = ticked_total()
	if scanning and not paused then
		buy_button:Disable()
		buy_button:SetText('Buy')
	elseif target and target_index and not bidding then
		buy_button:Enable()
		buy_button:SetText(format('Buy (%d)', c))
	else
		buy_button:Disable()
		buy_button:SetText(finding and 'Finding...' or bidding and 'Buying...' or 'Buy')
	end
	if paused then
		local here = 0
		for i = 1, n do if buyable_here(found[i]) then here = here + 1 end end
		status:SetText(format('Stopped on page %d of search %d: %d to buy here (Next skips them)', paused.page + 1, paused.qi, here))
	elseif not scanning then
		local text = format('%d found, %d ticked: %s', n, c, money.to_string(total, nil, true))
		if bought_count > 0 then text = text .. format('  (bought %d)', bought_count) end
		if note then text = note .. '  ' .. text end
		status:SetText(text)
	end
	if paused then
		rescan_button:SetText('Next')
		rescan_button:Enable()
	else
		rescan_button:SetText('Rescan')
		if scanning then rescan_button:Disable() else rescan_button:Enable() end
	end
end

local function create_window()
	window = CreateFrame('Frame', 'TIMFDisenchantScan', UIParent)
	gui.set_window_style(window)
	-- local change: a little more opaque than the standard window (about 20%)
	local shade = window:CreateTexture(nil, 'BACKGROUND')
	shade:SetPoint('TOPLEFT', 3, -3)
	shade:SetPoint('BOTTOMRIGHT', -3, 3)
	shade:SetTexture(0, 0, 0, .3)
	-- above the auction house window and its neighbours
	window:SetFrameStrata('DIALOG')
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
		if scanning or finding then scan.abort() end
		generation = generation + 1
		scan_gen = scan_gen + 1
		scanning, finding, target, target_index, paused, pausing = nil, nil, nil, nil, nil, nil
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
			if f and not f.bought and not f.gone then
				f.checked = this:GetChecked() and true or false
				unticked[f.record.search_signature] = not f.checked or nil
				return choose()
			end
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
			if not f or f.bought or f.gone then return end
			if IsShiftKeyDown() and ChatFrameEditBox:IsVisible() then
				ChatFrameEditBox:Insert(f.record.link)
				return
			end
			f.checked = not f.checked
			unticked[f.record.search_signature] = not f.checked or nil
			return choose()
		end)
		rows[i] = row
	end

	status = gui.label(window, gui.font_size.small)
	status:SetPoint('BOTTOMLEFT', 10, 14)
	status:SetWidth(240)
	status:SetJustifyH('LEFT')

	local close = gui.button(window, gui.font_size.small)
	close:SetPoint('BOTTOMRIGHT', -8, 8)
	gui.set_size(close, 60, 24)
	close:SetText('Close')
	close:SetScript('OnClick', function() window:Hide() end)

	buy_button = gui.button(window, gui.font_size.small)
	buy_button:SetPoint('RIGHT', close, 'LEFT', -5, 0)
	gui.set_size(buy_button, 80, 24)
	buy_button:SetScript('OnClick', function() buy() end)

	rescan_button = gui.button(window, gui.font_size.small)
	rescan_button:SetPoint('RIGHT', buy_button, 'LEFT', -5, 0)
	gui.set_size(rescan_button, 60, 24)
	rescan_button:SetText('Rescan')
	rescan_button:SetScript('OnClick', function()
		if paused then next_page() else start() end
	end)
end

------------------------------------------------------------------------------
-- scanning and buying
------------------------------------------------------------------------------
local function at_auction_house()
	return AuctionFrame and aux.frame and aux.frame:IsShown() and not aux.is_away()
end

-- where the auction is on the page now on screen (buying moves later ones up)
local function index_on_page(record)
	local n = GetNumAuctionItems('list')
	for i = 1, n do
		if scan_util.test(record, i) then return i end
	end
end

local run_scan

-- pick the next auction to buy: one on the stopped page, else carry on scanning, else
-- (scan over) look the next passed-over one up
function M.choose()
	if paused then
		generation = generation + 1
		target, target_index, finding = nil, nil, nil
		for i = 1, getn(found) do
			local f = found[i]
			if buyable_here(f) then
				local index = index_on_page(f.record)
				if index then
					target, target_index = f, index
					break
				end
				f.gone = true   -- bought by someone else meanwhile
			end
		end
		if target then update() return end
		-- nothing left to buy here: read this page again and carry on
		local at = paused
		paused = nil
		return run_scan(at.qi, at.page)
	end
	if scanning then update() return end
	if target and target_index and wanted(target) then update() return end
	return locate()
end

-- Next: leave the rest of this page for later and carry on scanning
function M.next_page()
	if not paused then return end
	for i = 1, getn(found) do
		local f = found[i]
		if buyable_here(f) then f.passed = true passed[f.record.search_signature] = true end
	end
	target, target_index = nil, nil
	return choose()
end

run_scan = function(qi, page)
	scan_gen = scan_gen + 1
	local my = scan_gen
	-- auctions read earlier from this page (not bought) are read again below
	for i = getn(found), 1, -1 do
		local f = found[i]
		if f.qi == qi and f.page == page and not f.bought then tremove(found, i) end
	end
	local list = queries()
	for k = 1, qi - 1 do tremove(list, 1) end
	list[1].blizzard_query.first_page = page
	scanning, pausing = true, nil
	local query_no, page_no = qi - 1, 0
	local current_page
	update()
	scan.start{
		type = 'list',
		queries = list,
		on_start_query = function()
			if my ~= scan_gen then return end
			query_no = query_no + 1
			page_no = 0
		end,
		on_page_loaded = function(_, total_pages)
			if my ~= scan_gen then return end
			page_no = page_no + 1
			status:SetText(format('Scanning %d / %d (page %d / %d)', query_no, getn(SEARCHES), page_no, max(total_pages, 1)))
		end,
		on_auction = function(record)
			if my ~= scan_gen then return end
			current_page = record.page
			local g = group_of(record)
			if g then
				local sig = record.search_signature
				tinsert(found, {record = record, group = g, qi = query_no, page = record.page,
					checked = not unticked[sig], passed = passed[sig]})
			end
		end,
		on_page_scanned = function()
			if my ~= scan_gen or pausing then return end
			local here = 0
			for i = 1, getn(found) do
				local f = found[i]
				if wanted(f) and not f.passed and f.qi == query_no and f.page == current_page then here = here + 1 end
			end
			if here > 0 then
				-- stop on this page: its auctions are on screen and can be bought at once
				pausing = {qi = query_no, page = current_page}
				scan.stop()
				paused = pausing
				scan_gen = scan_gen + 1   -- the stopped scan's last callbacks are ignored
				scanning = true
				choose()
				return
			end
			update()
		end,
		on_complete = function()
			if my ~= scan_gen then return end
			scanning = nil
			table.sort(found, function(a, b)
				if a.group ~= b.group then return a.group.order < b.group.order end
				return a.record.unit_buyout_price < b.record.unit_buyout_price
			end)
			locate()
		end,
		on_abort = function()
			if my ~= scan_gen then return end
			scanning, paused = nil, nil
			note = 'Scan stopped.'
			update()
		end,
	}
end

function M.start()
	if scanning and not paused then return end
	if not at_auction_house() then aux.print('Disenchant scan: open the auction house first.') return end
	if not window then create_window() end
	-- the Professions panel sits in the same place
	local professions = require 'aux.core.professions'
	if professions.set_professions_open then professions.set_professions_open(false) end
	window:Show()
	window:Raise()   -- to the front every time DE Scan is pressed
	for i = getn(found), 1, -1 do tremove(found, i) end
	for k in pairs(unticked) do unticked[k] = nil end
	for k in pairs(passed) do passed[k] = nil end
	offset, bought_count, note = 0, 0, nil
	generation = generation + 1
	target, target_index, finding, bidding, paused = nil, nil, nil, nil, nil
	status:SetText('Scanning...')
	run_scan(1, 0)
end

-- one click, one auction: buy the one found, then look up the next
function M.buy()
	if (scanning and not paused) or bidding or not target or not target_index or aux.bid_in_progress() then return end
	if not at_auction_house() then aux.print('Disenchant scan: open the auction house first.') return end
	local f, index = target, target_index
	if not scan_util.test(f.record, index) then return choose() end   -- the page changed: look again
	if GetMoney() < f.record.buyout_price then
		note = '|cffff4040Not enough gold.|r'
		update()
		return
	end
	bidding = true
	note = nil
	update()
	aux.place_bid('list', index, f.record.buyout_price, function()
		bidding = nil
		f.bought = true
		bought_count = bought_count + 1
		choose()
	end)
	-- the purchase was not sent (it can only fail before sending when gold ran short):
	-- let the next click try again
	if not aux.bid_in_progress() and bidding and not f.bought then bidding = nil update() end
end

------------------------------------------------------------------------------
-- /timf descan [name price | reset | scan]
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
	if key == 'scan' then return start() end
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
