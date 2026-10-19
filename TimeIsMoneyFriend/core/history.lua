module 'aux.core.history'


--not using acecomm anymore
--[[AuxAddon = AceLibrary("AceAddon-2.0"):new("AceComm-2.0")   --im unsure this is done correctly but seems to work lol

local commPrefix = "AuxAddon";
AuxAddon:SetCommPrefix(commPrefix)

function AuxAddon:OnEnable()
	--self:RegisterComm(commPrefix, "GROUP", "OnCommReceive"); --for testing purposes, not really useful in real world I think
	self:RegisterComm(commPrefix, "GUILD", "OnCommReceive");
	--self:RegisterComm(commPrefix, "ZONE", "OnCommReceive");
end ]]--

local T = require 'T'
local aux = require 'aux'

local persistence = require 'aux.util.persistence'

local history_schema = {'tuple', '#', {next_push='number'}, {daily_min_buyout='number'}, {data_points={'list', ';', {'tuple', '@', {value='number'}, {time='number'}}}}}

local value_cache = {}

-- Local change: wizard and mana oils are priced per oil now (they stack on OctoWow; aux
-- used to divide by charges). Prices recorded per charge are cleared once, and per-charge
-- prices shared by other players' aux are ignored for them.
local PER_OIL = {[20744] = true, [20746] = true, [20750] = true, [20749] = true, [20745] = true, [20747] = true, [20748] = true}

function aux.handle.LOAD2()
	data = aux.faction_data.history
	if not aux.faction_data.oils_per_item then
		local snaps = aux.faction_data.snapshots or {}
		for id in pairs(PER_OIL) do
			for _, store in ipairs({data, snaps}) do
				for key in pairs(store) do
					if strfind(key, '^' .. id .. ':') then store[key] = nil end
				end
			end
		end
		aux.faction_data.oils_per_item = true
	end
	local _, name = GetChannelName("LFT")
	if aux.account_data.sharing and not name then
		aux.thread(aux.when, aux.later(5), function()
			local shouldJoin = true
			for i, channel in ipairs({GetChannelList()}) do
				if channel == "LFT" then
					shouldJoin = false
					break
				end
			end
			if shouldJoin then
				JoinChannelByName("LFT")
			end
		end)
	end
end

do
	local next_push = 0
	function get_next_push()
		if time() > next_push then
			local date = date('*t')
			date.hour, date.min, date.sec = 24, 0, 0
			next_push = time(date)
		end
		return next_push
	end
end

function new_record()
	return T.temp-T.map('next_push', get_next_push(), 'data_points', T.acquire())
end

function read_record(item_key)
	local record = data[item_key] and persistence.read(history_schema, data[item_key]) or new_record()
	if record.next_push <= time() then
		push_record(record)
		write_record(item_key, record)
	end
	return record
end

function write_record(item_key, record)
	data[item_key] = persistence.write(history_schema, record)
	if value_cache[item_key] then
		T.release(value_cache[item_key])
		value_cache[item_key] = nil
	end
end

local data_sharer = CreateFrame("Frame", "aux_data_sharer")
data_sharer:RegisterEvent("CHAT_MSG_CHANNEL")

data_sharer:SetScript("OnEvent", function()
	if not aux.account_data.sharing then return end
	if arg2 == UnitName("player") then return end
	if strupper(arg9) ~= "LFT" then return end

	local _, _, item_key, munit_buyout_price = strfind(arg1 or "", "^AuxData,(.*),(.*)$") -- using , as a seperator because item_key contains a :

	if not item_key then return end
	local _, _, shared_id = strfind(item_key, '^(%d+):')
	if PER_OIL[tonumber(shared_id or 0)] then return end

	local unit_buyout_price = tonumber(munit_buyout_price) or 0
	local item_record = read_record(item_key)

	if unit_buyout_price > 0 and unit_buyout_price < (item_record.daily_min_buyout or aux.huge) then
		item_record.daily_min_buyout = unit_buyout_price
		write_record(item_key, item_record)
	end
	-- print(arg1)
end)

function M.process_auction(auction_record, pages)
	local item_record = read_record(auction_record.item_key)
	local unit_buyout_price = ceil(auction_record.buyout_price / auction_record.aux_quantity)
	local item_key = auction_record.item_key
	if unit_buyout_price > 0 and unit_buyout_price < (item_record.daily_min_buyout or aux.huge) then
		item_record.daily_min_buyout = unit_buyout_price
		write_record(auction_record.item_key, item_record)
		--AuxAddon:SendCommMessage("GUILD", item_key, unit_buyout_price) relies on acecomm
		if aux.account_data.sharing == true then
			if (tonumber(pages) or 0) < 15 then --to avoid sharing data when people do searches without a keyword "full scans"
				if GetChannelName("LFT") ~= 0 then
					ChatThrottleLib:SendChatMessage("BULK", nil, "AuxData," .. item_key .."," .. unit_buyout_price , "CHANNEL", nil, GetChannelName("LFT")) --ChatThrottleLib fixed for turtle by Candor https://github.com/trumpetx/ChatLootBidder/blob/master/ChatThrottleLib.lua
				  	--print("sent")
				end
		 	end
		end
	end
end

--[[ function AuxAddon:OnCommReceive(prefix, sender, distribution, item_key, unit_buyout_price) --copied code from process_auction. <- code for when using acecomm
	print("received data"); --for testing (print comes from PFUI)
	local item_record = read_record(item_key)
	if unit_buyout_price > 0 and unit_buyout_price < (item_record.daily_min_buyout or aux.huge) then
		item_record.daily_min_buyout = unit_buyout_price
		write_record(item_key, item_record)
		--print("wrote data"); --for testing (print comes from PFUI)
	end
end ]]--

function M.data_points(item_key)
	return read_record(item_key).data_points
end

function M.value(item_key)
	if not value_cache[item_key] or value_cache[item_key].next_push <= time() then
		local item_record, value
		item_record = read_record(item_key)
		if getn(item_record.data_points) > 0 then
			local total_weight, weighted_values = 0, T.temp-T.acquire()
			for _, data_point in item_record.data_points do
				local weight = .99 ^ aux.round((item_record.data_points[1].time - data_point.time) / (60 * 60 * 24))
				total_weight = total_weight + weight
				tinsert(weighted_values, T.map('value', data_point.value, 'weight', weight))
			end
			for _, weighted_value in weighted_values do
				weighted_value.weight = weighted_value.weight / total_weight
			end
			value = weighted_median(weighted_values)
		else
			value = item_record.daily_min_buyout
		end
		value_cache[item_key] = T.map('value', value, 'next_push', item_record.next_push)
	end
	return value_cache[item_key].value
end

function M.market_value(item_key)
	return read_record(item_key).daily_min_buyout
end

-- Local addition: a "two-day" price, the average of today's and yesterday's lowest
-- buyout. Used by the crafting cost (default; /timf recent switches it to the long
-- average) and as a second disenchant tooltip line. Returns value, true; or the long
-- average and false when neither day has been seen.
function M.recent_value(item_key)
	-- median of the lowest prices seen in your searches over the last 48 hours
	local cutoff = time() - 48 * 60 * 60
	local lows = {}
	for _, s in ipairs(_M.snapshots(item_key)) do
		if s[1] >= cutoff then tinsert(lows, s[2]) end
	end
	if getn(lows) > 0 then
		table.sort(lows)
		local n = getn(lows)
		if math.mod(n, 2) == 1 then return lows[(n + 1) / 2], true end
		return (lows[n / 2] + lows[n / 2 + 1]) / 2, true
	end
	-- no recent searches: average of today's and yesterday's lowest buyout
	local record = read_record(item_key)
	local today = record.daily_min_buyout
	local yesterday
	local point = record.data_points[1]
	if point and point.time > get_next_push() - 1.5 * 24 * 60 * 60 then
		yesterday = point.value
	end
	if today and yesterday then return (today + yesterday) / 2, true end
	if today or yesterday then return today or yesterday, true end
	return _M.value(item_key), false
end

-- Local addition: price snapshots from your own searches, last 3 days, per item:
-- aux.faction_data.snapshots[item_key] = "time:lowest:median:count;..."
local SNAPSHOT_DAYS = 3

local function snapshot_store()
	if not aux.faction_data.snapshots then aux.faction_data.snapshots = {} end
	return aux.faction_data.snapshots
end

-- list of { time, lowest, median, count }, oldest first, older than 3 days removed
function M.snapshots(item_key)
	local store = snapshot_store()
	local list = {}
	local cutoff = time() - SNAPSHOT_DAYS * 24 * 60 * 60
	for t, lo, med, n in string.gfind(store[item_key] or '', '(%d+):(%d+):(%d+):(%d+)') do
		t = tonumber(t)
		if t >= cutoff then tinsert(list, { t, tonumber(lo), tonumber(med), tonumber(n) }) end
	end
	return list
end

-- called when a search finishes: listings = { [item_key] = { {unit price, count}, ... } }
function M.record_search(listings)
	local store = snapshot_store()
	local now = time()
	for item_key, entries in pairs(listings) do
		table.sort(entries, function(a, b) return a[1] < b[1] end)
		local total = 0
		for i = 1, getn(entries) do total = total + entries[i][2] end
		local median, seen = entries[1][1], 0
		for i = 1, getn(entries) do
			seen = seen + entries[i][2]
			if seen >= total / 2 then median = entries[i][1] break end
		end
		local kept = {}
		for _, s in ipairs(_M.snapshots(item_key)) do
			tinsert(kept, s[1] .. ':' .. s[2] .. ':' .. s[3] .. ':' .. s[4])
		end
		tinsert(kept, now .. ':' .. floor(entries[1][1] + .5) .. ':' .. floor(median + .5) .. ':' .. total)
		store[item_key] = table.concat(kept, ';')
	end
end

-- the day's lowest buyout for each stored day, oldest first, today last.
function M.daily_lows(item_key)
	local record = read_record(item_key)
	local lows = {}
	for i = getn(record.data_points), 1, -1 do
		tinsert(lows, record.data_points[i].value)
	end
	if record.daily_min_buyout then tinsert(lows, record.daily_min_buyout) end
	return lows
end

function M.price(item_key, recent)
	if recent then
		return _M.recent_value(item_key)
	end
	return _M.value(item_key), false
end

function weighted_median(list)
	sort(list, function(a,b) return a.value < b.value end)
	local weight = 0
	for _, v in ipairs(list) do
		weight = weight + v.weight
		if weight >= .5 then
			return v.value
		end
	end
end

function push_record(item_record)
	if item_record.daily_min_buyout then
		tinsert(item_record.data_points, 1, T.map('value', item_record.daily_min_buyout, 'time', item_record.next_push))
		while getn(item_record.data_points) > 11 do
			T.release(item_record.data_points[getn(item_record.data_points)])
			tremove(item_record.data_points)
		end
	end
	item_record.next_push, item_record.daily_min_buyout = get_next_push(), nil
end