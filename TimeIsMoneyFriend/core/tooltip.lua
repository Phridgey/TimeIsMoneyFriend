module 'aux.core.tooltip'

local T = require 'T'
local aux = require 'aux'
local info = require 'aux.util.info'
local money =  require 'aux.util.money'
local disenchant = require 'aux.core.disenchant'
local history = require 'aux.core.history'
local gui = require 'aux.gui'

local UNKNOWN = GRAY_FONT_COLOR_CODE .. '?' .. FONT_COLOR_CODE_CLOSE

local game_tooltip_hooks, game_tooltip_money = {}, 0

function aux.handle.LOAD()
	settings = aux.character_data.tooltip
	do
		local inside_hook = false
	    for name, f in game_tooltip_hooks do
	        local name, f = name, f
	        aux.hook(name, GameTooltip, T.vararg-function(arg)
                game_tooltip_money = 0
                inside_hook = true
	            local tmp = T.list(aux.orig[GameTooltip][name](unpack(arg)))
	            inside_hook = false
	            f(unpack(arg))
	            return T.unpack(tmp)
	        end)
	    end
        SetTooltipMoney = SetTooltipMoney
        _G.SetTooltipMoney = T.vararg-function(arg)
            if inside_hook then
                game_tooltip_money = arg[2]
            else
                return SetTooltipMoney(unpack(arg))
            end
        end
    end
    local orig = SetItemRef
    setglobal('SetItemRef', T.vararg-function(arg)
        local name, _, quality = GetItemInfo(arg[1])
        local tmp = T.list(orig(unpack(arg)))
        if not IsShiftKeyDown() and not IsControlKeyDown() and name then
            local color_code = aux.select(4, GetItemQualityColor(quality))
            local link = color_code ..  '|H' .. arg[1] .. '|h[' .. name .. ']|h' .. FONT_COLOR_CODE_CLOSE
            extend_tooltip(ItemRefTooltip, link, 1)
        end
        return T.unpack(tmp)
    end)
end

function M.extend_tooltip(tooltip, link, quantity)
    local item_id, suffix_id = info.parse_link(link)
    quantity = IsShiftKeyDown() and quantity or 1
    local item_info = T.temp-info.item(item_id)
    if item_info then
        local distribution = disenchant.distribution(item_info.slot, item_info.quality, item_info.level, item_id)
        if getn(distribution) > 0 then
            if settings.disenchant_distribution then
                tooltip:AddLine('Disenchants into:', aux.color.tooltip.disenchant.distribution())
                sort(distribution, function(a,b) return a.probability > b.probability end)
                for _, event in ipairs(distribution) do
                    tooltip:AddLine(format('  %s%% %s (%s-%s)', event.probability * 100, info.display_name(event.item_id, true) or 'item:' .. event.item_id, event.min_quantity, event.max_quantity), aux.color.tooltip.disenchant.distribution())
                end
            end
            if settings.disenchant_value then
                local disenchant_value = disenchant.value(item_info.slot, item_info.quality, item_info.level, item_id)
                tooltip:AddLine('Disenchant: ' .. (disenchant_value and money.to_string2(disenchant_value) or UNKNOWN), aux.color.tooltip.disenchant.value())
                local recent_de_value = disenchant.value(item_info.slot, item_info.quality, item_info.level, item_id, true)
                tooltip:AddLine('Disenchant (2-day): ' .. (recent_de_value and money.to_string2(recent_de_value) or UNKNOWN), aux.color.tooltip.disenchant.value())
                local crafted = disenchant.crafted_lines(item_info.slot, item_info.quality, item_info.level, item_id)
                for i = 1, table.getn(crafted) do
                    tooltip:AddLine(crafted[i].label .. (crafted[i].value and money.to_string2(crafted[i].value) or UNKNOWN), aux.color.tooltip.disenchant.value())
                end
            end
        end
    end
    if settings.merchant_buy then
        local _, price, limited = info.merchant_info(item_id)
        if price then
            tooltip:AddLine('Vendor Buy ' .. (limited and '(limited): ' or ': ') .. money.to_string2(price * quantity), aux.color.tooltip.merchant())
        end
    end
    if settings.merchant_sell then
        local price = info.merchant_info(item_id)
		if price == nil and ShaguTweaks and ShaguTweaks.SellValueDB[item_id] ~= nil then
			local charges = 1
			if info.max_item_charges(item_id) ~= nil then 
				charges=info.max_item_charges(item_id) 
			end
			price = ShaguTweaks.SellValueDB[item_id] / charges
		end
        if price ~= 0 then
            tooltip:AddLine('Vendor: ' .. (price and money.to_string2(price * quantity) or UNKNOWN), aux.color.tooltip.merchant())
        end
    end
    local auctionable = not item_info or info.auctionable(T.temp-info.tooltip('link', item_info.itemstring), item_info.quality)
    local item_key = (item_id or 0) .. ':' .. (suffix_id or 0)
    local value = history.value(item_key)
    if auctionable then
        if settings.value then
            tooltip:AddLine('Value: ' .. (value and money.to_string2(value * quantity) or UNKNOWN), aux.color.tooltip.value())
        end
        local mats = disenchant.material_lines(item_id)
        for i = 1, getn(mats) do
            local m = mats[i]
            -- surplus per single item: what crafting it into the product earns over selling
            -- it as is (product price minus every other material, shared per unit of this one,
            -- minus this item's own price). Shift does not multiply these by the stack.
            local text
            -- "selling it -> extra from crafting it"
            if m.diff then
                text = m.label .. money.to_string(m.own, nil, true) .. ' -> ' .. (m.diff >= 0 and '|cff40ff40+|r' or '|cffff4040-|r') .. money.to_string(math.abs(m.diff), nil, true)
            else
                text = m.label .. UNKNOWN
            end
            tooltip:AddLine(text, aux.color.tooltip.disenchant.value())
        end
        if settings.graph ~= false then
            draw_graph(tooltip, history.snapshots(item_key))
        end
        if settings.daily  then
            local market_value = history.market_value(item_key)
            tooltip:AddLine('Today: ' .. (market_value and money.to_string2(market_value * quantity) .. ' (' .. gui.percentage_historical(aux.round(market_value / value * 100)) .. ')' or UNKNOWN), aux.color.tooltip.value())
        end
    end

    if tooltip == GameTooltip and game_tooltip_money > 0 then
        SetTooltipMoney(tooltip, game_tooltip_money)
    end
    tooltip:Show()
end

-- Local addition: a tiny graph of your own searches for this item over the last 3 days:
-- bright line = median listed price, dim line = lowest price, white dot = latest search.
-- Spaced by real time. It sits on four reserved tooltip lines and hides itself as soon as
-- the tooltip shows something else.
local GRAPH_MARK = '|cff000001' .. string.rep(' ', 34) .. '|r'
local GRAPH_W, GRAPH_H = 130, 26
function draw_graph(tooltip, snaps)
    if getn(snaps) < 1 or not tooltip.GetName or not tooltip:GetName() then return end
    tooltip:AddLine(GRAPH_MARK)
    local first = tooltip:NumLines()
    tooltip:AddLine(' ')
    tooltip:AddLine(' ')
    tooltip:AddLine(' ')  -- room below the graph so the background covers it
    local g = tooltip.aux_graph
    if not g then
        g = CreateFrame('Frame', nil, tooltip)
        g:SetWidth(GRAPH_W)
        g:SetHeight(GRAPH_H)
        g.dots = {}
        g.tooltip = tooltip
        -- legend to the right of the graph: latest search's median and lowest price
        g.legend = {}
        for i = 1, 2 do
            local fs = g:CreateFontString(nil, 'OVERLAY', 'GameFontHighlightSmall')
            fs:SetJustifyH('LEFT')
            fs:SetPoint('TOPLEFT', g, 'TOPRIGHT', 8, 2 - (i - 1) * 11)
            g.legend[i] = fs
        end
        g:SetScript('OnUpdate', function()
            local fs = getglobal(this.tooltip:GetName() .. 'TextLeft' .. this.line)
            if not fs or not fs:IsShown() or fs:GetText() ~= GRAPH_MARK then this:Hide() return end
            -- the tooltip sizes itself to its text, which doesn't include the legend: widen it
            if this.need and this.tooltip:GetWidth() < this.need then this.tooltip:SetWidth(this.need) end
        end)
        tooltip.aux_graph = g
    end
    g.line = first
    g:ClearAllPoints()
    g:SetPoint('TOPLEFT', getglobal(tooltip:GetName() .. 'TextLeft' .. first), 'TOPLEFT', 0, -4)
    local n = getn(snaps)
    local t0, t1 = snaps[1][1], snaps[n][1]
    local low, high = snaps[1][2], snaps[1][3]
    for i = 1, n do
        if snaps[i][2] < low then low = snaps[i][2] end
        if snaps[i][3] > high then high = snaps[i][3] end
    end
    local function x(t)
        if t1 == t0 then return (GRAPH_W - 4) / 2 end
        return (t - t0) * (GRAPH_W - 4) / (t1 - t0)
    end
    local function y(v)
        if high == low then return GRAPH_H / 2 end
        return (v - low) * (GRAPH_H - 4) / (high - low)
    end
    local used = 0
    local function dot(px, py, size, r, gr, b)
        used = used + 1
        local tex = g.dots[used]
        if not tex then
            tex = g:CreateTexture(nil, 'OVERLAY')
            g.dots[used] = tex
        end
        tex:SetTexture(r, gr, b, 1)
        tex:SetWidth(size)
        tex:SetHeight(size)
        tex:ClearAllPoints()
        tex:SetPoint('BOTTOMLEFT', g, 'BOTTOMLEFT', px, py)
        tex:Show()
    end
    local function line(field, size, r, gr, b)
        for i = 1, n - 1 do
            local x0, y0, x1, y1 = x(snaps[i][1]), y(snaps[i][field]), x(snaps[i + 1][1]), y(snaps[i + 1][field])
            local steps = math.max(1, math.ceil(math.max(math.abs(x1 - x0), math.abs(y1 - y0))))
            for k = 0, steps - 1 do
                local f = k / steps
                dot(x0 + (x1 - x0) * f, y0 + (y1 - y0) * f, size, r, gr, b)
            end
        end
    end
    line(2, 1, .35, .35, .4)   -- lowest price, dim
    line(3, 2, .35, .7, .9)    -- median, bright
    dot(x(t1) - 1, y(snaps[n][3]) - 1, 4, 1, 1, 1)
    g.legend[1]:SetText('|cff59b3e6median|r ' .. money.to_string2(snaps[n][3]))
    g.legend[2]:SetText('|cff8c8c99lowest|r ' .. money.to_string2(snaps[n][2]))
    local left, tleft = getglobal(tooltip:GetName() .. 'TextLeft' .. first):GetLeft(), tooltip:GetLeft()
    local pad = (left and tleft and left > tleft) and (left - tleft) or 10
    g.need = pad + GRAPH_W + 8 + math.max(g.legend[1]:GetStringWidth(), g.legend[2]:GetStringWidth()) + pad
    for i = used + 1, getn(g.dots) do g.dots[i]:Hide() end
    g:Show()
end

function game_tooltip_hooks:SetHyperlink(itemstring)
    local name, _, quality = GetItemInfo(itemstring)
    if name then
        local hex = aux.select(4, GetItemQualityColor(quality))
        local link = hex ..  '|H' .. itemstring .. '|h[' .. name .. ']|h' .. FONT_COLOR_CODE_CLOSE
        extend_tooltip(GameTooltip, link, 1)
    end
end

function game_tooltip_hooks:SetAuctionItem(type, index)
	local link = GetAuctionItemLink(type, index)
    if link then
        extend_tooltip(GameTooltip, link, aux.select(3, GetAuctionItemInfo(type, index)))
    end
end

function game_tooltip_hooks:SetLootItem(slot)
	local link = GetLootSlotLink(slot)
    if link then
        extend_tooltip(GameTooltip, link, aux.select(3, GetLootSlotInfo(slot)))
    end
end

function game_tooltip_hooks:SetQuestItem(qtype, slot)
	local link = GetQuestItemLink(qtype, slot)
    if link then
        extend_tooltip(GameTooltip, link, aux.select(3, GetQuestItemInfo(qtype, slot)))
    end
end

function game_tooltip_hooks:SetQuestLogItem(qtype, slot)
	local link = GetQuestLogItemLink(qtype, slot)
    if link then
        extend_tooltip(GameTooltip, link, aux.select(3, GetQuestLogRewardInfo(slot)))
    end
end

function game_tooltip_hooks:SetBagItem(bag, slot)
	local link = GetContainerItemLink(bag, slot)
    if link then
        extend_tooltip(GameTooltip, link, aux.select(2, GetContainerItemInfo(bag, slot)))
    end
end

function game_tooltip_hooks:SetInboxItem(index)
    local name, _, quantity = GetInboxItem(index)
    local id = name and info.item_id(name)
    if id then
        local _, itemstring, quality = GetItemInfo(id)
		if quality and itemstring then
			local hex = aux.select(4, GetItemQualityColor(tonumber(quality)))
			local link = hex ..  '|H' .. itemstring .. '|h[' .. name .. ']|h' .. FONT_COLOR_CODE_CLOSE
			extend_tooltip(GameTooltip, link, quantity)
		end
    end
end

function game_tooltip_hooks:SetInventoryItem(unit, slot)
	local link = GetInventoryItemLink(unit, slot)
    if link then
        extend_tooltip(GameTooltip, link, 1)
    end
end

function game_tooltip_hooks:SetMerchantItem(slot)
	local link = GetMerchantItemLink(slot)
    if link then
        local quantity = aux.select(4, GetMerchantItemInfo(slot))
        extend_tooltip(GameTooltip, link, quantity)
    end
end

function game_tooltip_hooks:SetCraftItem(skill, slot)
    local link, quantity
    if slot then
        link, quantity = GetCraftReagentItemLink(skill, slot), aux.select(3, GetCraftReagentInfo(skill, slot))
    else
        link, quantity = GetCraftItemLink(skill), 1
    end
    if link then
	    extend_tooltip(GameTooltip, link, quantity)
    end
end

function game_tooltip_hooks:SetCraftSpell(slot)
	local link = GetCraftItemLink(slot)
    if link then
        extend_tooltip(GameTooltip, link, 1)
    end
end

function game_tooltip_hooks:SetTradeSkillItem(skill, slot)
    local link, quantity
    if slot then
        link, quantity = GetTradeSkillReagentItemLink(skill, slot), aux.select(3, GetTradeSkillReagentInfo(skill, slot))
    else
        link, quantity = GetTradeSkillItemLink(skill), 1
    end
    if link then
        extend_tooltip(GameTooltip, link, quantity)
    end
end

function game_tooltip_hooks:SetAuctionSellItem()
    local name, _, quantity = GetAuctionSellItemInfo()
    if name then
        for slot in info.inventory() do
	        T.temp(slot)
            local link = GetContainerItemLink(unpack(slot))
            if link and aux.select(5, info.parse_link(link)) == name then
                extend_tooltip(GameTooltip, link, quantity)
                return
            end
        end
    end
end