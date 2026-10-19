module 'aux.tabs.post'

local T = require 'T'
local aux = require 'aux'
local info = require 'aux.util.info'
local sort_util = require 'aux.util.sort'
local persistence = require 'aux.util.persistence'
local money = require 'aux.util.money'
local scan_util = require 'aux.util.scan'
local post = require 'aux.core.post'
local scan = require 'aux.core.scan'
local history = require 'aux.core.history'
local item_listing = require 'aux.gui.item_listing'
local al = require 'aux.gui.auction_listing'
local gui = require 'aux.gui'

local tab = aux.tab 'Post'

local settings_schema = {'tuple', '#', {duration='number'}, {start_price='number'}, {buyout_price='number'}, {hidden='boolean'}, {stack_size='number'}}

local scan_id, inventory_records, bid_records, buyout_records = 0, {}, {}, {}

M.DURATION_2, M.DURATION_8, M.DURATION_24 = 120, 480, 1440

M.SORT_NAME_ASC = 1
M.SORT_NAME_DESC = 2
M.SORT_QUALITY_DESC = 3
M.SORT_QUALITY_ASC = 4
M.SORT_COUNT_DESC = 5
M.SORT_COUNT_ASC = 6

sort_options = {
	{ text = 'Name (A-Z)', value = SORT_NAME_ASC },
	{ text = 'Name (Z-A)', value = SORT_NAME_DESC },
	{ text = 'Rarity (High to Low)', value = SORT_QUALITY_DESC },
	{ text = 'Rarity (Low to High)', value = SORT_QUALITY_ASC },
	{ text = 'Quantity (High to Low)', value = SORT_COUNT_DESC },
	{ text = 'Quantity (Low to High)', value = SORT_COUNT_ASC },
}

selected_type = 0
selected_quality = -1
selected_sort = 1

refresh = true

selected_item = nil

function get_default_settings()
	return T.map('duration', aux.account_data.post_duration, 'start_price', 0, 'buyout_price', 0, 'hidden', false, 'stack_size', 1)
end

function aux.handle.LOAD2()
	data = aux.faction_data.post
end

function read_settings(item_key)
	item_key = item_key or selected_item.key
	return data[item_key] and persistence.read(settings_schema, data[item_key]) or get_default_settings()
end
function write_settings(settings, item_key)
	item_key = item_key or selected_item.key
	data[item_key] = persistence.write(settings_schema, settings)
end

do
	local bid_selections, buyout_selections = {}, {}
	function get_bid_selection()
		return bid_selections[selected_item.key]
	end
	function set_bid_selection(record)
		bid_selections[selected_item.key] = record
	end
	function get_buyout_selection()
		return buyout_selections[selected_item.key]
	end
	function set_buyout_selection(record)
		buyout_selections[selected_item.key] = record
	end
end

function refresh_button_click()
	scan.abort(scan_id)
	refresh_entries()
	refresh = true
end

function tab.OPEN()
    frame:Show()
    update_inventory_records()
    selected_sort = aux.account_data.post_sort or selected_sort or 1
    if type_dropdown then
        UIDropDownMenu_Initialize(type_dropdown, initialize_type_dropdown)
        UIDropDownMenu_SetSelectedValue(type_dropdown, selected_type or 0)
    end
    if rarity_dropdown then
        UIDropDownMenu_Initialize(rarity_dropdown, initialize_rarity_dropdown)
        UIDropDownMenu_SetSelectedValue(rarity_dropdown, selected_quality or -1)
    end
    if sort_dropdown then
        UIDropDownMenu_Initialize(sort_dropdown, initialize_sort_dropdown)
        UIDropDownMenu_SetSelectedValue(sort_dropdown, selected_sort or 1)
    end
    update_filter_dropdown_text()
    refresh = true
end

function tab.CLOSE()
    selected_item = nil
    frame:Hide()
end

function tab.USE_ITEM(item_info)
	select_item(item_info.item_key)
end

function get_unit_start_price()
	return selected_item and read_settings().start_price or 0
end

function set_unit_start_price(amount)
	local settings = read_settings()
	settings.start_price = amount
	write_settings(settings)
end

function get_unit_buyout_price()
	return selected_item and read_settings().buyout_price or 0
end

function set_unit_buyout_price(amount)
	local settings = read_settings()
	settings.buyout_price = amount
	write_settings(settings)
end

local function sort_records(records)
	local sort_mode = selected_sort or 1
	if sort_mode == SORT_NAME_DESC then
		sort(records, function(a, b)
			return sort_util.multi_lt(
				b.name, a.name,
				b.quality, a.quality,
				a.key, b.key
			)
		end)
	elseif sort_mode == SORT_QUALITY_DESC then
		sort(records, function(a, b)
			return sort_util.multi_lt(
				b.quality, a.quality,
				a.name, b.name,
				a.key, b.key
			)
		end)
	elseif sort_mode == SORT_QUALITY_ASC then
		sort(records, function(a, b)
			return sort_util.multi_lt(
				a.quality, b.quality,
				a.name, b.name,
				a.key, b.key
			)
		end)
	elseif sort_mode == SORT_COUNT_DESC then
		sort(records, function(a, b)
			return sort_util.multi_lt(
				b.aux_quantity, a.aux_quantity,
				b.quality, a.quality,
				a.name, b.name,
				a.key, b.key
			)
		end)
	elseif sort_mode == SORT_COUNT_ASC then
		sort(records, function(a, b)
			return sort_util.multi_lt(
				a.aux_quantity, b.aux_quantity,
				b.quality, a.quality,
				a.name, b.name,
				a.key, b.key
			)
		end)
	else
		sort(records, function(a, b)
			return sort_util.multi_lt(
				a.name, b.name,
				b.quality, a.quality,
				a.key, b.key
			)
		end)
	end
end

function update_inventory_listing()
	local records = aux.values(aux.filter(aux.copy(inventory_records), function(record)
		local settings = read_settings(record.key)
		if record.aux_quantity <= 0 then
			return false
		end
		if settings.hidden and not show_hidden_checkbox:GetChecked() and not aux.account_data.showhidden then
			return false
		end
		if selected_type and selected_type ~= 0 and selected_type ~= '' then
			local item_class = record.class
			if not item_class and record.item_id then
				local info_data = info.item(record.item_id)
				if info_data then
					record.class = info_data.class
					item_class = info_data.class
				end
			end
			if item_class ~= selected_type then
				return false
			end
		end
		if selected_quality and selected_quality >= 0 then
			if record.quality ~= selected_quality then
				return false
			end
		end
		return true
	end))
	sort_records(records)
	item_listing.populate(inventory_listing, records)
end

function update_auction_listing(listing, records, reference)
	local rows = T.acquire()
	if selected_item then
		local historical_value = history.value(selected_item.key)
		local stack_size = stack_size_slider:GetValue()
		for _, record in records[selected_item.key] or T.empty do
			local price_color = undercut(record, stack_size_slider:GetValue(), listing == 'bid') < reference and aux.color.red
			local price = record.unit_price * (listing == 'bid' and record.stack_size / stack_size_slider:GetValue() or 1)
			tinsert(rows, T.map(
				'cols', T.list(
				T.map('value', record.own and aux.color.green(record.count) or record.count),
				T.map('value', al.time_left(record.duration)),
				T.map('value', record.stack_size == stack_size and aux.color.green(record.stack_size) or record.stack_size),
				T.map('value', money.to_string(price, true, nil, price_color)),
				T.map('value', historical_value and gui.percentage_historical(aux.round(price / historical_value * 100)) or '---')
			),
				'record', record
			))
		end
		if historical_value then
			tinsert(rows, T.map(
				'cols', T.list(
				T.map('value', '---'),
				T.map('value', '---'),
				T.map('value', '---'),
				T.map('value', money.to_string(historical_value, true, nil, aux.color.green)),
				T.map('value', historical_value and gui.percentage_historical(100) or '---')
			),
				'record', T.map('historical_value', true, 'stack_size', stack_size, 'unit_price', historical_value, 'own', true)
			))
		end
		sort(rows, function(a, b)
			return sort_util.multi_lt(
				a.record.unit_price * (listing == 'bid' and a.record.stack_size or 1),
				b.record.unit_price * (listing == 'bid' and b.record.stack_size or 1),

				a.record.historical_value and 1 or 0,
				b.record.historical_value and 1 or 0,

				b.record.own and 0 or 1,
				a.record.own and 0 or 1,

				a.record.stack_size,
				b.record.stack_size,

				a.record.duration,
				b.record.duration
			)
		end)
	end
	if listing == 'bid' then
		bid_listing:SetData(rows)
	elseif listing == 'buyout' then
		buyout_listing:SetData(rows)
	end
end

function update_auction_listings()
	update_auction_listing('bid', bid_records, get_unit_start_price())
	update_auction_listing('buyout', buyout_records, get_unit_buyout_price())
end

function M.select_item(item_key)
    for _, inventory_record in aux.filter(aux.copy(inventory_records), function(record) return record.aux_quantity > 0 end) do
        if inventory_record.key == item_key then
            update_item(inventory_record)
            return
        end
    end
end

function price_update()
    if selected_item then
        local historical_value = history.value(selected_item.key)
        if get_bid_selection() or get_buyout_selection() then
	        set_unit_start_price(undercut(get_bid_selection() or get_buyout_selection(), stack_size_slider:GetValue(), get_bid_selection()))
	        unit_start_price_input:SetText(money.to_string(get_unit_start_price(), true, nil, nil, true))
        end
        if get_buyout_selection() then
	        set_unit_buyout_price(undercut(get_buyout_selection(), stack_size_slider:GetValue()))
	        unit_buyout_price_input:SetText(money.to_string(get_unit_buyout_price(), true, nil, nil, true))
        end
        start_price_percentage:SetText(historical_value and gui.percentage_historical(aux.round(get_unit_start_price() / historical_value * 100)) or '---')
        buyout_price_percentage:SetText(historical_value and gui.percentage_historical(aux.round(get_unit_buyout_price() / historical_value * 100)) or '---')
    end
end

function post_auctions()
	if selected_item then
        local unit_start_price = get_unit_start_price()
        local unit_buyout_price = get_unit_buyout_price()
        local stack_size = stack_size_slider:GetValue()
        local stack_count
        stack_count = stack_count_slider:GetValue()
        local duration = UIDropDownMenu_GetSelectedValue(duration_dropdown)
		local key = selected_item.key

        local duration_code
		if duration == DURATION_2 then
            duration_code = 2
		elseif duration == DURATION_8 then
            duration_code = 3
		elseif duration == DURATION_24 then
            duration_code = 4
		end

		post.start(
			key,
			stack_size,
			duration,
            unit_start_price,
            unit_buyout_price,
			stack_count,
			function(posted)
				if not frame:IsShown() then
					return
				end
				for i = 1, posted do
                    record_auction(key, stack_size, unit_start_price * stack_size, unit_buyout_price, duration_code, UnitName'player')
                end
                update_inventory_records()
				local same
                for _, record in inventory_records do
                    if record.key == key then
	                    same = record
	                    break
                    end
                end
                if same then
	                update_item(same)
                else
                    selected_item = nil
                end
                refresh = true
			end
		)
	end
end

function M.post_auctions_bind()
	if selected_item then
        local unit_start_price = get_unit_start_price()
        local unit_buyout_price = get_unit_buyout_price()
        local stack_size = stack_size_slider:GetValue()
        local stack_count
        stack_count = stack_count_slider:GetValue()
        local duration = UIDropDownMenu_GetSelectedValue(duration_dropdown)
		local key = selected_item.key

        local duration_code
		if duration == DURATION_2 then
            duration_code = 2
		elseif duration == DURATION_8 then
            duration_code = 3
		elseif duration == DURATION_24 then
            duration_code = 4
		end

		post.start(
			key,
			stack_size,
			duration,
            unit_start_price,
            unit_buyout_price,
			stack_count,
			function(posted)
				if not frame:IsShown() then
					return
				end
				for i = 1, posted do
                    record_auction(key, stack_size, unit_start_price * stack_size, unit_buyout_price, duration_code, UnitName'player')
                end
                update_inventory_records()
				local same
                for _, record in inventory_records do
                    if record.key == key then
	                    same = record
	                    break
                    end
                end
                if same then
	                update_item(same)
                else
                    selected_item = nil
                end
                refresh = true
			end
		)
	end
end

function validate_parameters()
    if not selected_item then
        post_button:Disable()
        return
    end
    if get_unit_buyout_price() > 0 and get_unit_start_price() > get_unit_buyout_price() then
        post_button:Disable()
        return
    end
    if get_unit_start_price() == 0 then
        post_button:Enable()
        return
    end
    if stack_count_slider:GetValue() == 0 then
        post_button:Disable()
        return
    end
    post_button:Enable()
end

function update_item_configuration()
	if not selected_item then
        refresh_button:Disable()

        item.texture:SetTexture(nil)
        item.count:SetText()
        item.name:SetTextColor(aux.color.label.enabled())
        item.name:SetText('No item selected')

        unit_start_price_input:Hide()
        unit_buyout_price_input:Hide()
        stack_size_slider:Hide()
        stack_count_slider:Hide()
        deposit:Hide()
        duration_dropdown:Hide()
        hide_checkbox:Hide()
        vendor_price_label:Hide()
    else
		unit_start_price_input:Show()
        unit_buyout_price_input:Show()
        stack_size_slider:Show()
        stack_count_slider:Show()
        deposit:Show()
        duration_dropdown:Show()
        hide_checkbox:Show()
        vendor_price_label:Show()

        item.texture:SetTexture(selected_item.texture)
        item.name:SetText('[' .. selected_item.name .. ']')
		do
	        local color = ITEM_QUALITY_COLORS[selected_item.quality]
	        item.name:SetTextColor(color.r, color.g, color.b)
        end
		if selected_item.aux_quantity > 1 then
            item.count:SetText(selected_item.aux_quantity)
		else
            item.count:SetText()
        end

        stack_size_slider.editbox:SetNumber(stack_size_slider:GetValue())
        stack_count_slider.editbox:SetNumber(stack_count_slider:GetValue())

        do
            local deposit_factor = 0.025
            local duration_factor = UIDropDownMenu_GetSelectedValue(duration_dropdown) / 120
            local stack_size, stack_count = selected_item.max_charges and 1 or stack_size_slider:GetValue(), stack_count_slider:GetValue()
            local max_stack = selected_item.max_stack
            local amount = floor(selected_item.unit_vendor_price * stack_size * duration_factor * (1 + (max_stack - stack_size) * 0.05) * deposit_factor) * stack_count
            deposit:SetText('Deposit: ' .. money.to_string(amount, nil, nil, aux.color.text.enabled))
        end

        --vendor price
        do
            local unit_vendor_price = selected_item.unit_vendor_price
            if not unit_vendor_price then
                vendor_price_label:SetText("Unit Vendor Price: N/A")
            elseif unit_vendor_price == 0 then
                vendor_price_label:SetText("Unit Vendor Price: None")
            else
                vendor_price_label:SetText("Unit Vendor Price: " .. money.to_string(unit_vendor_price, nil, nil, aux.color.text.enabled))
            end
        end

        refresh_button:Enable()
	end
end

function undercut(record, stack_size, stack)
    local price = ceil(record.unit_price * (stack and record.stack_size or stack_size))
    if not record.own then
        if aux.account_data.undercut then
            price = price - 1
        end
    end
    return price / stack_size
end

function quantity_update(maximize_count)
    if selected_item then
        local max_stack_count = selected_item.max_charges and selected_item.availability[stack_size_slider:GetValue()] or floor(selected_item.availability[0] / stack_size_slider:GetValue())
        stack_count_slider:SetMinMaxValues(1, max_stack_count)
        if maximize_count then
            stack_count_slider:SetValue(max_stack_count)
        end
    end
    refresh = true
end

function unit_vendor_price(item_key)
    for slot in info.inventory() do
	    T.temp(slot)
        local item_info = T.temp-info.container_item(unpack(slot))
        if item_info and item_info.item_key == item_key then
            if info.auctionable(item_info.tooltip, nil, true) and not item_info.lootable then
                ClearCursor()
                PickupContainerItem(unpack(slot))
                ClickAuctionSellItemButton()
                local auction_sell_item = T.temp-info.auction_sell_item()
                ClearCursor()
                ClickAuctionSellItemButton()
                ClearCursor()
                if auction_sell_item then
                    return auction_sell_item.vendor_price / auction_sell_item.count
                end
            end
        end
    end
end

function update_item(item)
    local settings = read_settings(item.key)

    item.unit_vendor_price = unit_vendor_price(item.key)
    if not item.unit_vendor_price then
        settings.hidden = true
        write_settings(settings, item.key)
        refresh = true
        return
    end

    scan.abort(scan_id)

    selected_item = item

    UIDropDownMenu_Initialize(duration_dropdown, initialize_duration_dropdown)
    UIDropDownMenu_SetSelectedValue(duration_dropdown, settings.duration)

    hide_checkbox:SetChecked(settings.hidden)
	
	local ii = 1
	if selected_item.max_charges then
		for i = selected_item.max_charges, 1, -1 do
			if selected_item.availability[i] > 0 then
				stack_size_slider:SetMinMaxValues(1, i)
				ii=i
				break
			end
		end
	else
		-- local change: the cached stack limit can be older than the server's (items that
		-- stack on this server but not in the original game); a bigger stack in the bags wins
		local max_stack = max(selected_item.max_stack or 1, selected_item.max_count or 1)
		ii = min(max_stack, selected_item.aux_quantity)
		stack_size_slider:SetMinMaxValues(1, ii)
	end
		
	if not aux.account_data.post_stack then
		-- post_stack OFF: Always use full/max stack size
		stack_size_slider:SetValue(aux.huge)
	else
		-- post_stack ON: Use saved stack size if available, otherwise full stack
		local settings = read_settings(selected_item.key)
		if settings.stack_size and settings.stack_size > 0 and settings.stack_size <= ii then
			stack_size_slider:SetValue(settings.stack_size)
		else
			stack_size_slider:SetValue(aux.huge)
		end
	end

    quantity_update(true)

    unit_start_price_input:SetText(money.to_string(settings.start_price, true, nil, nil, true))
    unit_buyout_price_input:SetText(money.to_string(settings.buyout_price, true, nil, nil, true))

    if not bid_records[selected_item.key] then
        refresh_entries()
    end

    write_settings(settings, item.key)

    refresh = true
end

function update_inventory_records()
    local auctionable_map = T.temp-T.acquire()
    for slot in info.inventory() do
	    T.temp(slot)
	    local item_info = T.temp-info.container_item(unpack(slot))
        if item_info then
            local charge_class = item_info.charges or 0
            -- local change: a partly used charged item (an oil with 2 of its 5 charges left) is
            -- not offered for posting
            local used = item_info.charges_left and item_info.charges_left < 5
            if info.auctionable(item_info.tooltip, nil, true) and not item_info.lootable and not used then
                if not auctionable_map[item_info.item_key] then
                    local availability = T.acquire()
                    for i = 0, 10 do
                        availability[i] = 0
                    end
                    availability[charge_class] = item_info.count
                    local info_data = info.item(item_info.item_id)
                    local item_class = item_info.class or (info_data and info_data.class)
                    local item_subclass = item_info.subclass or (info_data and info_data.subclass)
                    auctionable_map[item_info.item_key] = T.map(
	                    'item_id', item_info.item_id,
	                    'suffix_id', item_info.suffix_id,
	                    'key', item_info.item_key,
	                    'itemstring', item_info.itemstring,
	                    'name', item_info.name,
	                    'texture', item_info.texture,
	                    'quality', item_info.quality,
	                    'aux_quantity', item_info.charges or item_info.count,
	                    'max_stack', item_info.max_stack,
	                    'max_charges', item_info.max_charges,
	                    'max_count', item_info.count,
	                    'availability', availability,
	                    'class', item_class,
	                    'subclass', item_subclass
                    )
                else
                    local auctionable = auctionable_map[item_info.item_key]
                    auctionable.availability[charge_class] = (auctionable.availability[charge_class] or 0) + item_info.count
                    auctionable.aux_quantity = auctionable.aux_quantity + (item_info.charges or item_info.count)
                    if item_info.count > (auctionable.max_count or 0) then auctionable.max_count = item_info.count end
                end
            end
        end
    end
    T.release(inventory_records)
    inventory_records = aux.values(auctionable_map)
    refresh = true
end

function refresh_entries()
	if selected_item then
        local item_key = selected_item.key
		set_bid_selection()
        set_buyout_selection()
        bid_records[item_key], buyout_records[item_key] = nil, nil
        local query = scan_util.item_query(selected_item.item_id)
        status_bar:update_status(0, 0)
        status_bar:set_text('Scanning auctions...')

		scan_id = scan.start{
            type = 'list',
            ignore_owner = true,
			queries = T.list(query),
			on_page_loaded = function(page, total_pages)
                status_bar:update_status(page / total_pages, 0) -- TODO
                status_bar:set_text(format('Scanning Page %d / %d', page, total_pages))
			end,
			on_auction = function(auction_record)
				if auction_record.item_key == item_key then
                    record_auction(
                        auction_record.item_key,
                        auction_record.aux_quantity,
                        auction_record.unit_blizzard_bid,
                        auction_record.unit_buyout_price,
                        auction_record.duration,
                        auction_record.owner
                    )
				end
			end,
			on_abort = function()
				bid_records[item_key], buyout_records[item_key] = nil, nil
                status_bar:update_status(1, 1)
                status_bar:set_text('Scan aborted')
			end,
			on_complete = function()
				bid_records[item_key] = bid_records[item_key] or T.acquire()
				buyout_records[item_key] = buyout_records[item_key] or T.acquire()
                refresh = true
                status_bar:update_status(1, 1)
                status_bar:set_text('Scan complete')
            end,
		}
	end
end

function record_auction(key, aux_quantity, unit_blizzard_bid, unit_buyout_price, duration, owner)
    bid_records[key] = bid_records[key] or T.acquire()
    do
	    local entry
	    for _, record in bid_records[key] do
	        if unit_blizzard_bid == record.unit_price and aux_quantity == record.stack_size and duration == record.duration and info.is_player(owner) == record.own then
	            entry = record
	        end
	    end
	    if not entry then
	        entry = T.map('stack_size', aux_quantity, 'unit_price', unit_blizzard_bid, 'duration', duration, 'own', info.is_player(owner), 'count', 0)
	        tinsert(bid_records[key], entry)
	    end
	    entry.count = entry.count + 1
    end
    buyout_records[key] = buyout_records[key] or T.acquire()
    if unit_buyout_price == 0 then return end
    do
	    local entry
	    for _, record in buyout_records[key] do
		    if unit_buyout_price == record.unit_price and aux_quantity == record.stack_size and duration == record.duration and info.is_player(owner) == record.own then
			    entry = record
		    end
	    end
	    if not entry then
		    entry = T.map('stack_size', aux_quantity, 'unit_price', unit_buyout_price, 'duration', duration, 'own', info.is_player(owner), 'count', 0)
		    tinsert(buyout_records[key], entry)
	    end
	    entry.count = entry.count + 1
    end
end

function on_update()
    if refresh then
        refresh = false
        price_update()
        update_item_configuration()
        update_inventory_listing()
        update_auction_listings()
    end
    validate_parameters()
end

function initialize_duration_dropdown()
    local function on_click()
        UIDropDownMenu_SetSelectedValue(duration_dropdown, this.value)
        local settings = read_settings()
        settings.duration = this.value
        write_settings(settings)
        refresh = true
    end
    UIDropDownMenu_AddButton{
        text = '6 Hours',
        value = DURATION_2,
        func = on_click,
    }
    UIDropDownMenu_AddButton{
        text = '24 Hours',
        value = DURATION_8,
        func = on_click,
    }
    UIDropDownMenu_AddButton{
        text = '72 Hours',
        value = DURATION_24,
        func = on_click,
    }
end

function update_filter_dropdown_text()
	if not type_dropdown or not rarity_dropdown or not sort_dropdown then
		return
	end

	-- Type
	local type_text = ALL
	if selected_type and selected_type ~= 0 and selected_type ~= '' then
		type_text = selected_type
	end
	UIDropDownMenu_SetText(type_text, type_dropdown)

	-- Rarity
	local rarity_text = ALL
	if selected_quality and selected_quality >= 0 then
		local _, _, _, hex = GetItemQualityColor(selected_quality)
		local q_name = _G['ITEM_QUALITY' .. selected_quality .. '_DESC'] or ''
		rarity_text = (hex or '') .. q_name .. FONT_COLOR_CODE_CLOSE
	end
	UIDropDownMenu_SetText(rarity_text, rarity_dropdown)

	-- Sort
	local sort_text = 'Name (A-Z)'
	for _, opt in ipairs(sort_options) do
		if opt.value == (selected_sort or 1) then
			sort_text = opt.text
			break
		end
	end
	UIDropDownMenu_SetText(sort_text, sort_dropdown)
end

function initialize_type_dropdown()
	local function on_click()
		UIDropDownMenu_SetSelectedValue(type_dropdown, this.value)
		selected_type = this.value
		update_filter_dropdown_text()
		refresh = true
	end
	UIDropDownMenu_AddButton{
		text = ALL,
		value = 0,
		func = on_click,
	}
	local classes = T.temp-T.list(GetAuctionItemClasses())
	local added = T.temp-T.acquire()
	for _, class in ipairs(classes) do
		added[class] = true
		UIDropDownMenu_AddButton{
			text = class,
			value = class,
			func = on_click,
		}
	end
	for _, record in inventory_records or T.empty do
		if record.class and not added[record.class] then
			added[record.class] = true
			UIDropDownMenu_AddButton{
				text = record.class,
				value = record.class,
				func = on_click,
			}
		end
	end
end

function initialize_rarity_dropdown()
	local function on_click()
		UIDropDownMenu_SetSelectedValue(rarity_dropdown, this.value)
		selected_quality = this.value
		update_filter_dropdown_text()
		refresh = true
	end
	UIDropDownMenu_AddButton{
		text = ALL,
		value = -1,
		func = on_click,
	}
	for i = 0, 5 do
		local _, _, _, hex = GetItemQualityColor(i)
		local quality_name = _G['ITEM_QUALITY' .. i .. '_DESC']
		if quality_name then
			UIDropDownMenu_AddButton{
				text = (hex or '') .. quality_name .. FONT_COLOR_CODE_CLOSE,
				value = i,
				func = on_click,
			}
		end
	end
end

function initialize_sort_dropdown()
	local function on_click()
		UIDropDownMenu_SetSelectedValue(sort_dropdown, this.value)
		selected_sort = this.value
		aux.account_data.post_sort = this.value
		update_filter_dropdown_text()
		refresh = true
	end
	for _, opt in ipairs(sort_options) do
		UIDropDownMenu_AddButton{
			text = opt.text,
			value = opt.value,
			func = on_click,
		}
	end
end
