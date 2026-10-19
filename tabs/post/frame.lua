module 'aux.tabs.post'

local aux = require 'aux'
local info = require 'aux.util.info'
local money = require 'aux.util.money'
local gui = require 'aux.gui'
local listing = require 'aux.gui.listing'
local item_listing = require 'aux.gui.item_listing'
local search_tab = require 'aux.tabs.search'

function aux.handle.INIT_UI()
    local THEME_PADDING = gui.is_blizzard() and 6.5 or 2.5

    frame = CreateFrame('Frame', nil, aux.frame)
    frame:SetAllPoints()
    frame:SetScript('OnUpdate', on_update)
    frame:Hide()

    frame.content = CreateFrame('Frame', nil, frame)
    frame.content:SetPoint('TOP', frame, 'TOP', 0, -8)
    frame.content:SetPoint('BOTTOMLEFT', aux.frame.content, 'BOTTOMLEFT', 0, 0)
    frame.content:SetPoint('BOTTOMRIGHT', aux.frame.content, 'BOTTOMRIGHT', 0, 0)

    frame.inventory = gui.panel(frame.content)
    frame.inventory:SetWidth(212)
    frame.inventory:SetPoint('TOPLEFT', 0, 0)
    frame.inventory:SetPoint('BOTTOMLEFT', 0, 0)

    frame.parameters = gui.panel(frame.content)
    frame.parameters:SetHeight(173)
    frame.parameters:SetPoint('TOPLEFT', frame.inventory, 'TOPRIGHT', THEME_PADDING, 0)
    frame.parameters:SetPoint('TOPRIGHT', 0, 0)

    frame.bid_listing = gui.panel(frame.content)
    frame.bid_listing:SetHeight(228)
    frame.bid_listing:SetWidth(271.5)
    frame.bid_listing:SetPoint('BOTTOMLEFT', frame.inventory, 'BOTTOMRIGHT', THEME_PADDING, 0)

    frame.buyout_listing = gui.panel(frame.content)
    frame.buyout_listing:SetPoint('TOPLEFT', frame.parameters, 'BOTTOMLEFT', 0, -THEME_PADDING)
    frame.buyout_listing:SetPoint('BOTTOMRIGHT', 0, 0)

    do
        local dropdown = gui.dropdown(frame.inventory)
        dropdown:SetPoint('TOPLEFT', 11, -15)
        dropdown:SetWidth(190)
        local label = gui.label(dropdown, gui.font_size.small)
        label:SetPoint('BOTTOMLEFT', dropdown, 'TOPLEFT', -2, -3)
        label:SetText('Item Type')
        UIDropDownMenu_Initialize(dropdown, initialize_type_dropdown)
        dropdown:SetScript('OnShow', function()
            UIDropDownMenu_Initialize(this, initialize_type_dropdown)
            update_filter_dropdown_text()
        end)
        type_dropdown = dropdown
    end

    do
        local dropdown = gui.dropdown(frame.inventory)
        dropdown:SetPoint('TOPLEFT', type_dropdown, 'BOTTOMLEFT', 0, gui.is_blizzard() and -10 or -15)
        dropdown:SetWidth(190)
        local label = gui.label(dropdown, gui.font_size.small)
        label:SetPoint('BOTTOMLEFT', dropdown, 'TOPLEFT', -2, -3)
        label:SetText('Item Rarity')
        UIDropDownMenu_Initialize(dropdown, initialize_rarity_dropdown)
        dropdown:SetScript('OnShow', function()
            UIDropDownMenu_Initialize(this, initialize_rarity_dropdown)
            update_filter_dropdown_text()
        end)
        rarity_dropdown = dropdown
    end

    do
        local dropdown = gui.dropdown(frame.inventory)
        dropdown:SetPoint('TOPLEFT', rarity_dropdown, 'BOTTOMLEFT', 0, gui.is_blizzard() and -10 or -15)
        dropdown:SetWidth(190)
        local label = gui.label(dropdown, gui.font_size.small)
        label:SetPoint('BOTTOMLEFT', dropdown, 'TOPLEFT', -2, -3)
        label:SetText('Sort By')
        UIDropDownMenu_Initialize(dropdown, initialize_sort_dropdown)
        dropdown:SetScript('OnShow', function()
            UIDropDownMenu_Initialize(this, initialize_sort_dropdown)
            update_filter_dropdown_text()
        end)
        sort_dropdown = dropdown
    end

    do
        local checkbox = gui.checkbox(frame.inventory)
        checkbox:SetPoint('TOPLEFT', sort_dropdown, 'BOTTOMLEFT', 0, -8)
        checkbox:SetScript('OnClick', function()
            refresh = true
        end)
        local label = gui.label(checkbox, gui.font_size.small)
        label:SetPoint('LEFT', checkbox, 'RIGHT', 4, 1)
        label:SetText('Show hidden items')
        show_hidden_checkbox = checkbox
    end

    gui.horizontal_line(frame.inventory, gui.is_blizzard() and -167 or -177)

    do
        local f = CreateFrame('Frame', nil, frame.inventory)
        f:SetPoint('TOPLEFT', 0, gui.is_blizzard() and -172 or -182)
        f:SetPoint('BOTTOMRIGHT', 0, 0)
        inventory_listing = item_listing.new(
            f,
            function()
                if arg1 == 'LeftButton' then
                    update_item(this.item_record)
                elseif arg1 == 'RightButton' then
                    aux.set_tab(1)
                    search_tab.set_filter(strlower(info.item(this.item_record.item_id).name) .. '/exact')
                    search_tab.execute(nil, false)
                end
            end,
            function(item_record)
                return item_record == selected_item
            end
        )
    end

    bid_listing = listing.new(frame.bid_listing)
    bid_listing:SetColInfo{
        {name='Auctions', width=.17, align='CENTER'},
        {name='Time\nLeft', width=.11, align='CENTER'},
        {name='Stack\nSize', width=.11, align='CENTER'},
        {name='Auction Bid\n(per item)', width=.4, align='RIGHT'},
        {name='% Hist.\nValue', width=.21, align='CENTER'},
    }
    bid_listing:SetSelection(function(data)
        return data.record == get_bid_selection() or data.record.historical_value and get_bid_selection() and get_bid_selection().historical_value
    end)
    bid_listing:SetHandler('OnClick', function(table, row_data, column, button)
        if button == 'RightButton' and row_data.record == get_bid_selection() or row_data.record.historical_value and get_bid_selection() and get_bid_selection().historical_value then
            set_bid_selection()
        else
            set_bid_selection(row_data.record)
        end
        refresh = true
    end)
    bid_listing:SetHandler('OnDoubleClick', function(table, row_data, column, button)
        stack_size_slider:SetValue(row_data.record.stack_size)
        refresh = true
    end)

    buyout_listing = listing.new(frame.buyout_listing)
    buyout_listing:SetColInfo{
        {name='Auctions', width=.17, align='CENTER'},
        {name='Time\nLeft', width=.11, align='CENTER'},
        {name='Stack\nSize', width=.12, align='CENTER'},
        {name='Auction Buyout\n(per item)', width=.4, align='RIGHT'},
        {name='% Hist.\nValue', width=.20, align='CENTER'},
    }
    buyout_listing:SetSelection(function(data)
        return data.record == get_buyout_selection() or data.record.historical_value and get_buyout_selection() and get_buyout_selection().historical_value
    end)
    buyout_listing:SetHandler('OnClick', function(table, row_data, column, button)
        if button == 'RightButton' and row_data.record == get_buyout_selection() or row_data.record.historical_value and get_buyout_selection() and get_buyout_selection().historical_value then
            set_buyout_selection()
        else
            set_buyout_selection(row_data.record)
        end
        refresh = true
    end)
    buyout_listing:SetHandler('OnDoubleClick', function(table, row_data, column, button)
        stack_size_slider:SetValue(row_data.record.stack_size)
        refresh = true
    end)

    do
        status_bar = gui.status_bar(frame)
        status_bar:SetWidth(265)
        status_bar:SetHeight(25)
        status_bar:SetPoint('TOPLEFT', aux.frame.content, 'BOTTOMLEFT', 0, -6)
        status_bar:update_status(1, 1)
        status_bar:set_text('')
    end
    do
        local btn = gui.button(frame.parameters)
        btn:SetPoint('TOPLEFT', status_bar, 'TOPRIGHT', 5, 0)
        btn:SetText('Post')
        btn:SetScript('OnClick', post_auctions)
        post_button = btn
    end
    do
        local btn = gui.button(frame.parameters)
        btn:SetPoint('TOPLEFT', post_button, 'TOPRIGHT', 5, 0)
        btn:SetText('Refresh')
        btn:SetScript('OnClick', refresh_button_click)
        refresh_button = btn
    end
    do
        -- Descending post: [x] To [85s] in [10] + [10]
        local row = CreateFrame('Frame', nil, frame.parameters)
        row:SetWidth(200)
        row:SetHeight(25)
        row:SetPoint('TOPLEFT', refresh_button, 'TOPRIGHT', 4, 0)
        descend_row = row

        local function explain()
            GameTooltip:SetOwner(row, 'ANCHOR_TOPRIGHT')
            GameTooltip:AddLine('Descending post')
            GameTooltip:AddLine('To: the target price per item.', 1, 1, 1)
            GameTooltip:AddLine('in: how many auctions to take to get there. Each one is the same', 1, 1, 1)
            GameTooltip:AddLine('step cheaper than the last, and the last of them is at the target.', 1, 1, 1)
            GameTooltip:AddLine('+: how many more auctions to post at the target.', 1, 1, 1)
            GameTooltip:AddLine('One item per auction, counting down from your buyout price;', 1, 1, 1)
            GameTooltip:AddLine('Stack Size and Stack Count are ignored, and so is autopricing.', 1, 1, 1)
            if selected_item then
                local plan, why = descend_plan()
                GameTooltip:AddLine(' ')
                if not plan then
                    GameTooltip:AddLine('To post: ' .. why .. '.', 1, .5, .5)
                else
                    for i = 1, plan.steps do
                        if i <= 3 or i == plan.steps then
                            GameTooltip:AddDoubleLine('Auction ' .. i, money.to_string(descended_price(plan.reference, i, plan.step, plan.steps), nil, true), 1, 1, 1, 1, 1, 1)
                        elseif i == 4 then
                            GameTooltip:AddLine('...', 1, 1, 1)
                        end
                    end
                    if plan.rest > 0 then
                        GameTooltip:AddDoubleLine('Then ' .. plan.rest .. ' more at', money.to_string(plan.target, nil, true), 1, 1, 1, 1, 1, 1)
                    end
                    GameTooltip:AddDoubleLine('Step', money.to_string(plan.step, nil, true), .7, .7, .7, .7, .7, .7)
                end
            end
            GameTooltip:AddLine('Turns itself off after a reload.', .6, .6, .6)
            GameTooltip:Show()
        end
        local function hide_tip() GameTooltip:Hide() end
        local function hover(f) f:SetScript('OnEnter', explain) f:SetScript('OnLeave', hide_tip) end

        local checkbox = gui.checkbox(row)
        checkbox:SetPoint('LEFT', 0, 0)
        checkbox:SetChecked(nil)
        checkbox:SetScript('OnClick', function()
            descending = this:GetChecked() and true or false
            refresh = true
        end)
        hover(checkbox)
        descend_checkbox = checkbox

        local function label(text, anchor, gap)
            local l = gui.label(row, gui.font_size.small)
            l:SetPoint('LEFT', anchor, 'RIGHT', gap, 0)
            l:SetText(text)
            return l
        end
        local function number_box(anchor, field)
            local box = gui.editbox(row)
            box:SetPoint('LEFT', anchor, 'RIGHT', 7, 0)
            box:SetWidth(22)
            box:SetHeight(22)
            box:SetAlignment('CENTER')
            box:SetNumeric(true)
            box:SetMaxLetters(3)
            box.change = function()
                if this.focused then
                    if field == 'steps' then set_descend(nil, this:GetNumber(), nil) else set_descend(nil, nil, this:GetNumber()) end
                end
                refresh = true
            end
            box.enter = function() this:ClearFocus() end
            box.focus_loss = function() refresh = true end
            hover(box)
            return box
        end

        local to = label('To', checkbox, 2)

        local target_box = gui.editbox(row)
        target_box:SetPoint('LEFT', to, 'RIGHT', 7, 0)
        target_box:SetWidth(42)
        target_box:SetHeight(22)
        target_box:SetAlignment('RIGHT')
        target_box.formatter = function() return money.to_string((get_descend()), true) end
        target_box.change = function()
            if this.focused then
                local amount = money.from_string(this:GetText())
                if amount then set_descend(aux.round(amount), nil, nil) end
            end
            refresh = true
        end
        target_box.enter = function() this:ClearFocus() end
        target_box.focus_loss = function()
            this:SetText(money.to_string((get_descend()), true, nil, nil, true))
            refresh = true
        end
        hover(target_box)
        descend_target_input = target_box

        local steps_box = number_box(label('in', target_box, 5), 'steps')
        descend_steps_input = steps_box
        local rest_box = number_box(label('+', steps_box, 5), 'rest')
        descend_rest_input = rest_box

        target_box:SetScript('OnTabPressed', function() steps_box:SetFocus() end)
        steps_box:SetScript('OnTabPressed', function() if IsShiftKeyDown() then target_box:SetFocus() else rest_box:SetFocus() end end)
        rest_box:SetScript('OnTabPressed', function() if IsShiftKeyDown() then steps_box:SetFocus() else target_box:SetFocus() end end)
    end
    do
        item = gui.item(frame.parameters)
        item:SetPoint('TOPLEFT', 10, -6)
        item.button:SetScript('OnEnter', function()
            if selected_item then
                info.set_tooltip(selected_item.itemstring, this, 'ANCHOR_RIGHT')
            end
        end)
        item.button:SetScript('OnLeave', function()
            GameTooltip:Hide()
        end)
    end
    do
        local slider = gui.slider(frame.parameters)
        slider:SetValueStep(1)
        slider:SetPoint('TOPLEFT', 13, -73)
        slider:SetWidth(190)
        slider:SetScript('OnValueChanged', function()
            quantity_update(true)
        end)
        local user_is_dragging = false
        local editbox_has_user_focus = false
        slider:SetScript('OnMouseDown', function()
            user_is_dragging = true
        end)
        slider:SetScript('OnMouseUp', function()
            -- Only save stack size if user was actively dragging
            if selected_item and aux.account_data.post_stack and user_is_dragging then
                local settings = read_settings()
                settings.stack_size = slider:GetValue()
                write_settings(settings)
            end
            user_is_dragging = false
        end)
        slider.editbox.change = function()
            slider:SetValue(this:GetNumber())
            quantity_update(true)
            -- Only save if user is actively typing (has focus)
            if editbox_has_user_focus and selected_item and aux.account_data.post_stack then
                local settings = read_settings()
                settings.stack_size = slider:GetValue()
                write_settings(settings)
            end
        end
        slider.editbox:SetScript('OnEnterPressed', function()
            slider.editbox:ClearFocus()
        end)
        slider.editbox:SetScript('OnTabPressed', function()
            if IsShiftKeyDown() then
                unit_buyout_price_input:SetFocus()
            elseif stack_count_slider.editbox:IsVisible() then
                stack_count_slider.editbox:SetFocus()
            else
                unit_start_price_input:SetFocus()
            end
        end)
        -- Hook into gui framework's focus system
        slider.editbox.focus_gain = function()
            editbox_has_user_focus = true
        end
        slider.editbox.focus_loss = function()
            editbox_has_user_focus = false
        end
        slider.editbox:SetNumeric(true)
        slider.editbox:SetMaxLetters(3)
        slider.label:SetText('Stack Size')
        stack_size_slider = slider
    end
    do
        local slider = gui.slider(frame.parameters)
        slider:SetValueStep(1)
        slider:SetPoint('TOPLEFT', stack_size_slider, 'BOTTOMLEFT', 0, gui.is_blizzard() and -25 or -32)
        slider:SetWidth(190)
        slider:SetScript('OnValueChanged', function()
            quantity_update()
        end)
        slider.editbox.change = function()
            slider:SetValue(this:GetNumber())
            quantity_update()
        end
        slider.editbox:SetScript('OnTabPressed', function()
            if IsShiftKeyDown() then
                stack_size_slider.editbox:SetFocus()
            else
                unit_start_price_input:SetFocus()
            end
        end)
        slider.editbox:SetNumeric(true)
        slider.label:SetText('Stack Count')
        stack_count_slider = slider
    end
    do
        local dropdown = gui.dropdown(frame.parameters)
        dropdown:SetPoint('TOPLEFT', stack_count_slider, 'BOTTOMLEFT', 0, gui.is_blizzard() and -10 or -22)
        dropdown:SetWidth(90)
        local label = gui.label(dropdown, gui.font_size.small)
        label:SetPoint('BOTTOMLEFT', dropdown, 'TOPLEFT', -2, -3)
        label:SetText('Duration')
        UIDropDownMenu_Initialize(dropdown, initialize_duration_dropdown)
        dropdown:SetScript('OnShow', function()
            UIDropDownMenu_Initialize(this, initialize_duration_dropdown)
        end)
        duration_dropdown = dropdown
    end
    do
        local checkbox = gui.checkbox(frame.parameters)
        checkbox:SetPoint('TOPRIGHT', -83, -6)
        checkbox:SetScript('OnClick', function()
            local settings = read_settings()
            settings.hidden = this:GetChecked()
            write_settings(settings)
            refresh = true
        end)
        local label = gui.label(checkbox, gui.font_size.small)
        label:SetPoint('LEFT', checkbox, 'RIGHT', 4, 1)
        label:SetText('Hide this item')
        hide_checkbox = checkbox
    end
    do
        local editbox = gui.editbox(frame.parameters)
        editbox:SetPoint('TOPRIGHT', -71, -60)
        editbox:SetWidth(180)
        editbox:SetHeight(22)
        editbox:SetAlignment('RIGHT')
        editbox:SetFontSize(17)
        editbox:SetScript('OnTabPressed', function()
            if IsShiftKeyDown() then
                stack_count_slider.editbox:SetFocus()
            else
                unit_buyout_price_input:SetFocus()
            end
        end)
        editbox.formatter = function() return money.to_string(get_unit_start_price(), true) end
        editbox.char = function() set_bid_selection(); set_buyout_selection(); set_unit_start_price(money.from_string(this:GetText())) end
        editbox.change = function() refresh = true end
        editbox.enter = function() this:ClearFocus() end
        editbox.focus_loss = function()
            this:SetText(money.to_string(get_unit_start_price(), true, nil, nil, true))
        end
        do
            local label = gui.label(editbox, gui.font_size.small)
            label:SetPoint('BOTTOMLEFT', editbox, 'TOPLEFT', -2, 1)
            label:SetText('Unit Starting Price')
        end
        do
            local label = gui.label(editbox, 14)
            label:SetPoint('LEFT', editbox, 'RIGHT', 8, 0)
            label:SetWidth(50)
            label:SetJustifyH('CENTER')
            start_price_percentage = label
        end
        unit_start_price_input = editbox
    end
    do
        local editbox = gui.editbox(frame.parameters)
        editbox:SetPoint('TOPRIGHT', unit_start_price_input, 'BOTTOMRIGHT', 0, -19)
        editbox:SetWidth(180)
        editbox:SetHeight(22)
        editbox:SetAlignment('RIGHT')
        editbox:SetFontSize(17)
        editbox:SetScript('OnTabPressed', function()
            if IsShiftKeyDown() then
                unit_start_price_input:SetFocus()
            else
                stack_size_slider.editbox:SetFocus()
            end
        end)
        editbox.formatter = function() return money.to_string(get_unit_buyout_price(), true) end
        editbox.char = function() set_buyout_selection(); set_unit_buyout_price(money.from_string(this:GetText())) end
        editbox.change = function() refresh = true end
        editbox.enter = function() this:ClearFocus() end
        editbox.focus_loss = function()
            this:SetText(money.to_string(get_unit_buyout_price(), true, nil, nil, true))
        end
        do
            local label = gui.label(editbox, gui.font_size.small)
            label:SetPoint('BOTTOMLEFT', editbox, 'TOPLEFT', -2, 1)
            label:SetText('Unit Buyout Price')
        end
        do
            local label = gui.label(editbox, 14)
            label:SetPoint('LEFT', editbox, 'RIGHT', 8, 0)
            label:SetWidth(50)
            label:SetJustifyH('CENTER')
            buyout_price_percentage = label
        end
        unit_buyout_price_input = editbox
    end
    do
        local label = gui.label(frame.parameters, gui.font_size.medium)
        label:SetPoint('TOPLEFT', unit_buyout_price_input, 'BOTTOMLEFT', -180, -24)
        deposit = label
    end
    do
        local label = gui.label(frame.parameters, gui.font_size.medium)
        label:SetPoint('TOPLEFT', unit_buyout_price_input, 'BOTTOMLEFT', 0, -24)
        vendor_price_label = label
    end

    function aux.handle.LOAD()
        if aux.account_data.post_bid then
            frame.bid_listing:SetPoint('TOPLEFT', frame.parameters, 'BOTTOMLEFT', 0, -THEME_PADDING)
            frame.bid_listing:SetPoint('BOTTOMLEFT', frame.inventory, 'BOTTOMRIGHT', THEME_PADDING, 0)
            frame.bid_listing:SetWidth(271.5 - (THEME_PADDING / 2))

            frame.buyout_listing:ClearAllPoints()
            frame.buyout_listing:SetPoint('TOPLEFT', frame.bid_listing, 'TOPRIGHT', THEME_PADDING, 0)
            frame.buyout_listing:SetPoint('BOTTOMRIGHT', 0, 0)
        else
            frame.bid_listing:Hide()
            buyout_listing:SetColInfo{
                {name='Auctions', width=.15, align='CENTER'},
                {name='Time Left', width=.15, align='CENTER'},
                {name='Stack Size', width=.15, align='CENTER'},
                {name='Auction Buyout (per item)', width=.4, align='RIGHT'},
                {name='% Hist. Value', width=.15, align='CENTER'},
            }
        end
    end
end