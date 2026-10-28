module 'aux.core.professions'

local aux = require 'aux'
local gui = require 'aux.gui'
local listing = require 'aux.gui.listing'
local search_tab = require 'aux.tabs.search'
local filter_util = require 'aux.util.filter'

local professions, panel, body, toggle, recipe_filter, recipe_list, help
local expanded = {}
local trade_open, craft_open, scanning, pending_trade, pending_craft, pending_discovery
local next_scan, ignore_updates_until = 0, 0
-- number of rows each window had when last read; an update only re-reads when it changes
local last_count = {}
local worker = CreateFrame('Frame')

local function item_name(link)
    if type(link) ~= 'string' then return end
    local _, _, name = strfind(link, '|h%[(.-)%]|h')
    return name
end

local function is_item(link)
    return type(link) == 'string' and strfind(link, 'item:%d+')
end

local function profession(name, kind, rank, max_rank)
    local p = professions[name]
    if not p then
        p = {name=name, recipes={}}
        professions[name] = p
    end
    p.kind, p.rank, p.max_rank = kind or p.kind, rank or p.rank, max_rank or p.max_rank
    return p
end

-- Icons identify localized profession spells without requiring English names.
local profession_icons = {
    trade_alchemy=true, trade_blacksmithing=true, trade_engineering=true,
    trade_leatherworking=true, trade_tailoring=true, trade_engraving=true,
    trade_brewpoison=true, inv_misc_food_15=true, trade_cooking=true,
    spell_holy_sealofsacrifice=true, inv_misc_bandage_01=true,
    trade_herbalism='gathering', trade_mining='gathering', trade_fishing='gathering',
    inv_misc_pelt_wolf_01='gathering', spell_nature_skinning='gathering',
}

local function discover()
    if not professions then return end
    local spells = {}
    local _, _, general_offset, general_count = GetSpellTabInfo(1)
    local i = 1
    while true do
        local name = GetSpellName(i, BOOKTYPE_SPELL or 'spell')
        if not name then break end
        spells[name] = true
        local texture = GetSpellTexture(i, BOOKTYPE_SPELL or 'spell')
        local _, _, icon = strfind(strlower(texture or ''), '([^\\]+)$')
        local kind = icon and profession_icons[icon]
        if kind and i > general_offset and i <= general_offset + general_count then
            profession(name, kind == 'gathering' and 'gathering' or nil)
        end
        i = i + 1
    end
    -- Forget a profession when the character unlearns it.
    if i > 1 then
        for name in pairs(professions) do
            if not spells[name] then professions[name] = nil end
        end
    end
end

function M.search_recipe(recipe)
    if not aux.frame:IsVisible() then return end
    if not recipe.complete then
        aux.print('Open this profession again to finish caching the recipe and its materials.')
        return
    end
    local queries, seen = {}, {}
    local function add(name)
        if not name or name == '' then return end
        name = strlower(name)
        if not seen[name] then
            seen[name] = true
            tinsert(queries, filter_util.quote(name) .. '/exact')
        end
    end
    add(recipe.output)
    for _, reagent in ipairs(recipe.reagents) do add(reagent.name) end
    if getn(queries) == 0 then
        aux.print('This recipe has no auctionable output or materials to search.')
        return
    end
    aux.set_tab(1)
    search_tab.set_filter(table.concat(queries, ';'), true)
    -- Ignore a previous page range: search every page for every ingredient.
    search_tab.clear_page_range()
    search_tab.execute(nil, false, true)
end

local function refresh()
    if not recipe_list or not professions then return end
    local filter = strlower(recipe_filter:GetText() or '')
    local sorted, rows = {}, {}
    for _, p in pairs(professions) do tinsert(sorted, p) end
    table.sort(sorted, function(a, b) return a.name < b.name end)
    for _, p in ipairs(sorted) do
        local matches = {}
        for _, recipe in ipairs(p.recipes) do
            if filter == '' or strfind(strlower(recipe.name), filter, 1, true)
                or strfind(strlower(p.name), filter, 1, true) then
                tinsert(matches, recipe)
            end
        end
        if filter == '' or getn(matches) > 0 then
            local open = expanded[p.name] or filter ~= ''
            local rank = p.rank and ('  ' .. p.rank .. '/' .. (p.max_rank or p.rank)) or ''
            tinsert(rows, {cols={{value=(open and '[-] ' or '[+] ') .. p.name .. rank}}, profession=p})
            if open then
                for _, recipe in ipairs(matches) do
                    tinsert(rows, {cols={{value='    ' .. recipe.name}}, recipe=recipe})
                end
                if getn(p.recipes) == 0 then
                    local text = p.kind == 'gathering' and '    No crafting recipes' or '    Open profession to cache recipes'
                    tinsert(rows, {cols={{value=aux.color.gray(text)}}})
                end
            end
        end
    end
    recipe_list:SetData(rows)
    if getn(sorted) == 0 then
        help:SetText('Open each profession once to cache its recipes here. They remain available at the auction house.')
    elseif filter ~= '' and getn(rows) == 0 then
        help:SetText('No matching recipes.')
    else
        help:SetText('Click a recipe: search its item + all materials.\nOpen professions to update learned recipes.')
    end
end

-- Temporarily remove trade-skill filters, then restore exactly what was selected.
local function clear_filter(get_options, get_filter, set_filter)
    if not get_options or not get_filter or not set_filter then return function() end end
    if get_filter(0) then return function() end end
    local options, selected = {get_options()}, {}
    for i = 1, getn(options) do
        if get_filter(i) then tinsert(selected, i) end
    end
    set_filter(0, 1, 1)
    return function()
        for i, index in ipairs(selected) do set_filter(index, 1, i == 1 and 1 or 0) end
    end
end

local scan_profession_inner
-- Local change: the HaveMats addon can hide recipes you lack materials for; it steps
-- aside while the whole list is read, so the cache keeps every recipe.
local function scan_profession(craft)
    _G.HaveMats_Bypass = true
    local ok, err = pcall(scan_profession_inner, craft)
    _G.HaveMats_Bypass = nil
    if not ok then error(err) end
end

function scan_profession_inner(craft)
    if not professions then return end
    local name, rank, max_rank
    if craft then
        if not GetCraftDisplaySkillLine then return end
        name, rank, max_rank = GetCraftDisplaySkillLine()
    else
        name, rank, max_rank = GetTradeSkillLine()
    end
    -- Beast training uses CraftUI too, but has no profession skill line.
    if not name or name == '' or name == UNKNOWN then return end
    local p = profession(name, craft and 'craft' or 'trade', rank, max_rank)
    local count = craft and GetNumCrafts or GetNumTradeSkills
    local get_info = craft and GetCraftInfo or GetTradeSkillInfo
    local get_link = craft and GetCraftItemLink or GetTradeSkillItemLink
    local get_reagent = craft and GetCraftReagentInfo or GetTradeSkillReagentInfo
    local get_reagent_link = craft and GetCraftReagentItemLink or GetTradeSkillReagentItemLink
    local reagent_count = craft and GetCraftNumReagents or GetTradeSkillNumReagents
    local expand = craft and ExpandCraftSkillLine or ExpandTradeSkillSubClass
    local collapse = craft and CollapseCraftSkillLine or CollapseTradeSkillSubClass
    local get_selection = craft and GetCraftSelectionIndex or GetTradeSkillSelectionIndex
    local select_recipe = craft and SelectCraft or SelectTradeSkill
    local selection = get_selection and get_selection()
    local restore_subclass, restore_slot
    if not craft then
        restore_subclass = clear_filter(GetTradeSkillSubClasses, GetTradeSkillSubClassFilter, SetTradeSkillSubClassFilter)
        restore_slot = clear_filter(GetTradeSkillInvSlots, GetTradeSkillInvSlotFilter, SetTradeSkillInvSlotFilter)
    end

    local collapsed, recipes = {}, {}
    local i = 1
    while i <= count() do
        local recipe_name, subname, recipe_type, is_expanded
        if craft then
            local available
            recipe_name, subname, recipe_type, available, is_expanded = get_info(i)
        else
            local available
            recipe_name, recipe_type, available, is_expanded = get_info(i)
        end
        if recipe_type == 'header' then
            if not is_expanded and expand then
                tinsert(collapsed, i)
                expand(i)
            end
        elseif recipe_name then
            local link = get_link and get_link(i)
            local output = is_item(link) and (item_name(link) or recipe_name) or not craft and recipe_name or nil
            local recipe = {name=recipe_name, output=output, link=link, reagents={}, complete=craft or not not is_item(link)}
            if subname and subname ~= '' then recipe.name = recipe_name .. ' (' .. subname .. ')' end
            for r = 1, reagent_count(i) do
                local reagent_name, texture, quantity = get_reagent(i, r)
                local reagent_link = get_reagent_link(i, r)
                reagent_name = item_name(reagent_link) or reagent_name
                if not reagent_name or reagent_name == '' or not quantity then recipe.complete = false end
                tinsert(recipe.reagents, {name=reagent_name, count=quantity, link=reagent_link})
            end
            tinsert(recipes, recipe)
        end
        i = i + 1
    end
    -- Reverse order keeps the saved indices valid as rows disappear.
    for i = getn(collapsed), 1, -1 do collapse(collapsed[i]) end
    if restore_slot then restore_slot() end
    if restore_subclass then restore_subclass() end
    if select_recipe and selection and selection > 0 and selection <= count() then select_recipe(selection) end
    last_count[craft and 'craft' or 'trade'] = count()
    table.sort(recipes, function(a, b) return a.name < b.name end)
    -- An opening window can briefly report zero rows before its data arrives.
    if getn(recipes) > 0 then p.recipes = recipes end
    refresh()
end

local function schedule(kind, force)
    if scanning or not force and kind ~= 'discovery' and GetTime() < ignore_updates_until then return end
    if kind == 'trade' then pending_trade = true
    elseif kind == 'craft' then pending_craft = true
    else pending_discovery = true end
    next_scan = GetTime() + .2
    worker:SetScript('OnUpdate', function()
        if GetTime() < next_scan then return end
        worker:SetScript('OnUpdate', nil)
        scanning = true
        if pending_discovery then discover() end
        if pending_trade and trade_open then scan_profession(false) end
        if pending_craft and craft_open then scan_profession(true) end
        pending_trade, pending_craft, pending_discovery = nil, nil, nil
        scanning = nil
        -- Filter/header changes can emit their update events on the next frame.
        ignore_updates_until = GetTime() + .2
        refresh()
    end)
end

-- Local change: the windows send update events after every craft (materials used up) and
-- while you click around. Re-reading the whole list each time could switch the selected
-- recipe back just as you pressed Create, and kept the game busy. Now the list is read
-- when a window opens, and again only if its number of rows changes (a new recipe, or a
-- window that opened empty and then filled in).
local function rows_changed(craft)
    local count = craft and GetNumCrafts or GetNumTradeSkills
    _G.HaveMats_Bypass = true
    local ok, n = pcall(count)
    _G.HaveMats_Bypass = nil
    return ok and n ~= last_count[craft and 'craft' or 'trade']
end

function aux.handle.LOAD()
    aux.character_data.professions = aux.character_data.professions or {}
    professions = aux.character_data.professions
    aux.event_listener('TRADE_SKILL_SHOW', function() trade_open = true; schedule('trade', true) end)
    aux.event_listener('TRADE_SKILL_CLOSE', function() trade_open = nil end)
    aux.event_listener('TRADE_SKILL_UPDATE', function() if trade_open and not scanning and rows_changed(false) then schedule('trade') end end)
    aux.event_listener('CRAFT_SHOW', function() craft_open = true; schedule('craft', true) end)
    aux.event_listener('CRAFT_CLOSE', function() craft_open = nil end)
    aux.event_listener('CRAFT_UPDATE', function() if craft_open and not scanning and rows_changed(true) then schedule('craft') end end)
    aux.event_listener('SPELLS_CHANGED', function() schedule('discovery') end)
end

function aux.handle.LOAD2()
    discover()
    refresh()
end

function aux.handle.INIT_UI()
    panel = gui.panel(search_tab.frame)
    panel:SetPoint('TOPLEFT', aux.frame, 'TOPRIGHT', 12, 0)
    panel:SetWidth(280)
    panel:SetHeight(447)
    panel:EnableMouse(true)
    panel:SetScript('OnShow', refresh)

    -- Local change: starts tucked away. Closed, only a small button shows beside the
    -- auction house window (no empty bar); open, the full panel. Not remembered: it
    -- starts closed at every login.
    toggle = gui.button(search_tab.frame, gui.font_size.small)
    toggle:SetPoint('TOPLEFT', panel, 'TOPLEFT', 0, 0)
    toggle:SetFrameLevel(panel:GetFrameLevel() + 5)
    local function set_open(open)
        if open then
            panel:Show()
            toggle:ClearAllPoints()
            toggle:SetPoint('TOPLEFT', panel, 'TOPLEFT', 6, -4)
            gui.set_size(toggle, 268, 26)
            toggle:SetText('[-] Professions')
            refresh()
        else
            panel:Hide()
            toggle:ClearAllPoints()
            toggle:SetPoint('TOPLEFT', panel, 'TOPLEFT', 0, 0)
            gui.set_size(toggle, 100, 22)
            toggle:SetText('[+] Professions')
        end
    end
    M.set_professions_open = set_open
    toggle:SetScript('OnClick', function() set_open(not panel:IsShown()) end)

    body = CreateFrame('Frame', nil, panel)
    body:SetPoint('TOPLEFT', 8, -38)
    gui.set_size(body, 264, 401)

    recipe_filter = gui.editbox(body)
    recipe_filter:SetPoint('TOPLEFT', 0, 0)
    gui.set_size(recipe_filter, 264, 24)
    recipe_filter.formatter = function(text) return text == '' and aux.color.gray('Find recipe...') or text end
    recipe_filter:SetText('')
    recipe_filter.change = function()
        if recipe_list then
            FauxScrollFrame_SetOffset(recipe_list.scrollFrame, 0)
            refresh()
        end
    end
    recipe_filter.enter = function() recipe_filter:ClearFocus() end

    local list_parent = CreateFrame('Frame', nil, body)
    list_parent:SetPoint('TOPLEFT', 0, -30)
    gui.set_size(list_parent, 264, 310)
    recipe_list = listing.new(list_parent)
    recipe_list:SetColInfo{{name='Profession / Recipe', width=1}}
    recipe_list:SetHandler('OnClick', function(_, row, _, button)
        if button ~= 'LeftButton' then return end
        if row.profession then
            expanded[row.profession.name] = not expanded[row.profession.name]
            refresh()
        elseif row.recipe then
            search_recipe(row.recipe)
        end
    end)
    recipe_list:SetHandler('OnEnter', function(_, row, button)
        GameTooltip:SetOwner(button, 'ANCHOR_LEFT')
        if row.recipe then
            local recipe = row.recipe
            GameTooltip:SetText(recipe.name, 1, .82, 0)
            if recipe.output then GameTooltip:AddLine('Item: ' .. recipe.output, 1, 1, 1, true)
            else GameTooltip:AddLine('This recipe has no auctionable output.', .7, .7, .7, true) end
            for _, reagent in ipairs(recipe.reagents) do
                GameTooltip:AddLine((reagent.count or '?') .. ' x ' .. (reagent.name or 'Uncached material'), 1, 1, 1, true)
            end
            GameTooltip:AddLine('Click to search item and materials.', .3, 1, .3)
        elseif row.profession then
            GameTooltip:SetText(row.profession.name)
            GameTooltip:AddLine(getn(row.profession.recipes) .. ' cached recipes', 1, 1, 1)
            GameTooltip:AddLine('Click to expand or collapse.', .3, 1, .3)
        else
            GameTooltip:SetText('Open this profession to update its recipes.')
        end
        GameTooltip:Show()
    end)
    recipe_list:SetHandler('OnLeave', function() GameTooltip:Hide() end)

    help = gui.label(body, gui.font_size.small)
    help:SetPoint('TOPLEFT', 2, -348)
    gui.set_size(help, 260, 50)
    help:SetJustifyH('LEFT')
    help:SetJustifyV('TOP')
    help:SetText('Open each profession once to cache its recipes here.')
    set_open(false)
end
