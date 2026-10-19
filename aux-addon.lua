module 'aux'

local T = require 'T'
local post = require 'aux.tabs.post'
local gui = require 'aux.gui'
local purchase_summary = require 'aux.util.purchase_summary'

M.print = T.vararg-function(arg)
	DEFAULT_CHAT_FRAME:AddMessage(LIGHTYELLOW_FONT_COLOR_CODE .. '<TIMF> ' .. join(map(arg, tostring), ' '))
end

local bids_loaded
function M.bids_loaded() return bids_loaded end

local current_owner_page
function M.current_owner_page() return current_owner_page end

local event_frame = CreateFrame'Frame'
for event in T.temp-T.set('ADDON_LOADED', 'VARIABLES_LOADED', 'PLAYER_LOGIN', 'AUCTION_HOUSE_SHOW', 'AUCTION_HOUSE_CLOSED', 'AUCTION_BIDDER_LIST_UPDATE', 'AUCTION_OWNED_LIST_UPDATE') do
	event_frame:RegisterEvent(event)
end

local set_handler = {}
M.handle = setmetatable({}, {__metatable=false, __newindex=function(_, k, v) set_handler[k](v) end})

do
	local handlers_INIT_UI, handlers_LOAD, handlers_LOAD2 = {}, {}, {}
    function set_handler.INIT_UI(f)
		tinsert(handlers_INIT_UI, f)
	end
	function set_handler.LOAD(f)
		tinsert(handlers_LOAD, f)
	end
	function set_handler.LOAD2(f)
		tinsert(handlers_LOAD2, f)
	end
	-- each runs once, whether from its event or from late_start
	local did_variables, did_login
	local function variables_loaded()
		if did_variables then return end
		did_variables = true
		gui.set_global_theme(aux and aux.account and aux.account.theme)
		for _, f in handlers_INIT_UI do f() end
		for _, f in handlers_LOAD do f() end
	end
	local function player_login()
		if did_login then return end
		did_login = true
		for _, f in handlers_LOAD2 do f() end
	end
	-- Local change: steps for being loaded after login (from when this was load-on-demand;
	-- unused now that it always loads, kept so a late LoadAddOn still works).
	local function late_start()
		variables_loaded()
		player_login()
		local wait = CreateFrame('Frame')
		wait:SetScript('OnUpdate', function()
			this:SetScript('OnUpdate', nil)
			-- Loaded by an auctioneer window that is open right now: leave this visit to
			-- the Blizzard window (taking it over mid-visit left searches hanging); aux
			-- hooks in when it closes and takes over from the next visit.
			if _G.aux_late_ah then
				print('loaded - talk to the auctioneer again to use aux.')
			elseif IsAddOnLoaded('Blizzard_AuctionUI') then
				auction_ui_loaded()
			end
		end)
	end
	event_frame:SetScript('OnEvent', function()
		if event == 'ADDON_LOADED' then
			if arg1 == 'Blizzard_AuctionUI' then
                auction_ui_loaded()
			elseif arg1 == 'TimeIsMoneyFriend' and _G.aux_late_load then
				late_start()
			end
		elseif event == 'VARIABLES_LOADED' then
            variables_loaded()
		elseif event == 'PLAYER_LOGIN' then
			player_login()
		else
			_M[event]()
		end
	end)
end

function handle.LOAD()
    _G.aux = aux or {}
    assign(aux, {
        account = {},
        realm = {},
        faction = {},
        character = {},
    })
    M.account_data = assign(aux.account, {
        scale = 1,
        ignore_owner = true,
        crafting_cost = true,
        post_bid = false,
        post_duration = post.DURATION_24,
        post_stack = true,
        undercut = true,
        price_per_unit = false,
        items = {},
        item_ids = {},
        auctionable_items = {},
        merchant_buy = {},
        merchant_sell = {},
        sharing = true,
        theme = 'blizzard',
        purchase_summary = true,
        post_sort = 1,
    })
    do
        local key = format('%s|%s', GetCVar'realmName', UnitName'player')
        aux.character[key] = aux.character[key] or {}
        M.character_data = assign(aux.character[key], {
            tooltip = {
                value = true,
                merchant_sell = false,
                merchant_buy = false,
                daily = false,
                disenchant_value = false,
                disenchant_distribution = false,
            }
        })
    end
    do
        local key = GetCVar'realmName'
        aux.realm[key] = aux.realm[key] or {}
        M.realm_data = assign(aux.realm[key], {
            characters = {},
            recent_searches = {},
            favorite_searches = {},
        })
    end
end

function handle.LOAD2()
    local key = format('%s|%s', GetCVar'realmName', UnitFactionGroup'player')
	if GetCVar'realmName' == 'Nordanaar' then
		key = format('%s|%s', GetCVar'realmName', 'Horde')
	end
    aux.faction[key] = aux.faction[key] or {}
    M.faction_data = assign(aux.faction[key], {
        history = {},
        post = {},
    })
end

tab_info = {}
function M.tab(name)
	local tab = T.map('name', name)
	local tab_event = {
		OPEN = function(f) tab.OPEN = f end,
		CLOSE = function(f) tab.CLOSE = f end,
		USE_ITEM = function(f) tab.USE_ITEM = f end,
		CLICK_LINK = function(f) tab.CLICK_LINK = f end,
	}
	tinsert(tab_info, tab)
	return setmetatable({}, {__metatable=false, __newindex=function(_, k, v) tab_event[k](v) end})
end

do
	local index
	function M.get_tab() return tab_info[index] end
	function on_tab_click(i)
		CloseDropDownMenus()
		do (index and get_tab().CLOSE or pass)() end
		index = i
		do (index and get_tab().OPEN or pass)() end
	end
end

M.orig = setmetatable({[_G]=T.acquire()}, {__index=function(self, key) return self[_G][key] end})
M.hook = T.vararg-function(arg)
	local name, object, handler
	if getn(arg) == 3 then
		name, object, handler = unpack(arg)
	else
		object, name, handler = _G, unpack(arg)
	end
	handler = handler or getfenv(3)[name]
	orig[object] = orig[object] or T.acquire()
	assert(not orig[object][name], '"' .. name .. '" is already hooked into.')
	orig[object][name], object[name] = object[name], handler
	return hook
end

do
	local locked
	function M.bid_in_progress() return locked end
	function M.place_bid(type, index, amount, on_success)
		if locked then return end
		local money = GetMoney()
		PlaceAuctionBid(type, index, amount)
		if money >= amount then
			locked = true
			local send_signal, signal_received = signal()
			local name, texture, count, _, _, _, _, _, buyout_price = GetAuctionItemInfo(type, index)
			thread(when, signal_received, function()
				-- Track all (buyout) purchases after successful bid
				if name and amount > 0 and amount >= buyout_price then
					purchase_summary.add_purchase(name, texture, count, amount)
					purchase_summary.update_display()
				end
				do (on_success or pass)() end
				locked = false
			end)
			thread(when, later(5), send_signal)
			event_listener('CHAT_MSG_SYSTEM', function(kill)
				if arg1 == ERR_AUCTION_BID_PLACED then
					send_signal()
					kill()
				end
			end)
		end
	end
end

do
	local locked
	function M.cancel_in_progress() return locked end
	function M.cancel_auction(index, on_success)
		if locked then return end
		locked = true
		CancelAuction(index)
		local send_signal, signal_received = signal()
		thread(when, signal_received, function()
			do (on_success or pass)() end
			locked = false
		end)
		thread(when, later(5), send_signal)
		event_listener('CHAT_MSG_SYSTEM', function(kill)
			if arg1 == ERR_AUCTION_REMOVED then
				send_signal()
				kill()
			end
		end)
	end
end

function handle.LOAD2()
	frame:SetScale(account_data.scale)
end

function AUCTION_HOUSE_SHOW()
	if not frame or not AuctionFrame then return end
	if _G.aux_late_ah then return end   -- this visit opened before aux was loaded: Blizzard window keeps it
	-- Hooking first matters when aux was loaded late, with the Blizzard window already
	-- open: its own OnHide closes the auction house, which left searches waiting forever
	-- and aux stuck on (taking every right-click). auction_ui_loaded only runs once.
	auction_ui_loaded()
	AuctionFrame:Hide()
	frame:Show()
	set_tab(1)
end

do
	local handlers = {}
	function set_handler.CLOSE(f)
		tinsert(handlers, f)
	end
	function AUCTION_HOUSE_CLOSED()
		-- a visit left to the Blizzard window (aux loaded mid-visit): hook in now
		if IsAddOnLoaded('Blizzard_AuctionUI') then auction_ui_loaded() end
		bids_loaded = false
		current_owner_page = nil
		for _, handler in handlers do
			handler()
		end
		set_tab()
		frame:Hide()
	end
end

function AUCTION_BIDDER_LIST_UPDATE()
	bids_loaded = true
end

do
	local last_owner_page_requested
	function GetOwnerAuctionItems(index)
		last_owner_page_requested = index
		return orig.GetOwnerAuctionItems(index)
	end
	function AUCTION_OWNED_LIST_UPDATE()
		current_owner_page = last_owner_page_requested or 0
	end
end

local ui_hooked
function auction_ui_loaded()
	if ui_hooked then return end
	ui_hooked = true
	AuctionFrame:UnregisterEvent('AUCTION_HOUSE_SHOW')
	AuctionFrame:SetScript('OnHide', nil)
	hook('ShowUIPanel', T.vararg-function(arg)
		if arg[1] == AuctionFrame then return AuctionFrame:Show() end
		return orig.ShowUIPanel(unpack(arg))
	end)
	hook 'GetOwnerAuctionItems' 'SetItemRef' 'UseContainerItem' 'AuctionFrameAuctions_OnEvent'
end

AuctionFrameAuctions_OnEvent = T.vararg-function(arg)
    if AuctionFrameAuctions:IsVisible() then
	    return orig.AuctionFrameAuctions_OnEvent(unpack(arg))
    end
end
