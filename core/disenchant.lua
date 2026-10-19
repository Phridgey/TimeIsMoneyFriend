module 'aux.core.disenchant'

local T = require 'T'
local history = require 'aux.core.history'
local info = require 'aux.util.info'

local UNCOMMON, RARE, EPIC = 2, 3, 4

local ARMOR = T.set(
	'INVTYPE_HEAD',
	'INVTYPE_NECK',
	'INVTYPE_SHOULDER',
	'INVTYPE_BODY',
	'INVTYPE_CHEST',
	'INVTYPE_ROBE',
	'INVTYPE_WAIST',
	'INVTYPE_LEGS',
	'INVTYPE_FEET',
	'INVTYPE_WRIST',
	'INVTYPE_HAND',
	'INVTYPE_FINGER',
	'INVTYPE_TRINKET',
	'INVTYPE_CLOAK',
	'INVTYPE_HOLDABLE'
)

local WEAPON = T.set(
	'INVTYPE_2HWEAPON',
	'INVTYPE_WEAPONMAINHAND',
	'INVTYPE_WEAPON',
	'INVTYPE_WEAPONOFFHAND',
	'INVTYPE_SHIELD',
	'INVTYPE_RANGED',
	'INVTYPE_RANGEDRIGHT'
)

function M.value(slot, quality, level, item_id, recent)
    local expectation
    for _, event in distribution(slot, quality, level, item_id) do
        local value, is_recent = history.price(event.item_id .. ':' .. 0, recent)
		if not value then
            return
        end
		-- the two-day price already includes today's low; only the long average is capped by it
		local market_value = not is_recent and history.market_value(event.item_id .. ':' .. 0)
		if market_value then
			value=min(value,market_value)
		end
		expectation = (expectation or 0) + event.probability * (event.min_quantity + event.max_quantity) / 2 * value
    end
    return expectation
end

-- Local addition: disenchant value when the materials go into the staple enchanting
-- crafts and the product is sold (two-day prices). One line per craft: that craft's
-- materials are crafted, every other material is valued as sold.
local ENCH_LEATHER, RUGGED_LEATHER = 12810, 8170
local ENCH_THORIUM, THORIUM_BAR = 12655, 12359
local ENCH_GEMSTONE_OIL, GEMSTONE_OIL_VENDOR = 55248, 2500  -- Gemstone Oil: 25s from a vendor
local ILLUSION_DUST, LESSER_ETERNAL, GREATER_ETERNAL, GREATER_NETHER = 16204, 16202, 16203, 11175  -- Enchanted Thorium: 1 Thorium Bar + 3 Illusion Dust on OctoWow

local function price_2day(id)
	return history.price(id .. ':' .. 0, true)
end

-- Dreamshard Elixir = 1 Small Dream Shard + 1 Dream Dust + 1 Crystal Vial (vendor)
local DREAMSHARD_ELIXIR, SMALL_DREAM_SHARD, DREAM_DUST, CRYSTAL_VIAL = 61224, 61198, 11176, 8925
local BRIGHT_DREAM_SHARD = 61199  -- breaks down into 3 Small Dream Shards
local DREAMTONIC = 61423          -- an NPC trades one for each Small Dream Shard
local function vial_price()
	local _, buy = info.merchant_info(CRYSTAL_VIAL)
	return buy or 400  -- about 4s at a vendor
end
-- Firebloom: Brilliant Wizard Oil = 3 Firebloom + 2 Large Brilliant Shard + 1 Imbued Vial
-- (vendor); Greater Fire Protection Potion = 1 Firebloom + 1 Elemental Fire + 1 Crystal Vial
local FIREBLOOM, BRILLIANT_WIZARD_OIL, LARGE_BRILLIANT, IMBUED_VIAL = 4625, 20749, 14344, 18256
local GREATER_FIRE_PROT, ELEMENTAL_FIRE = 13457, 7068
local function vendor(id, fallback)
	local _, buy = info.merchant_info(id)
	return buy or fallback
end
local function firebloom_as_oil()
	local oil, shard = price_2day(BRILLIANT_WIZARD_OIL), price_2day(LARGE_BRILLIANT)
	if oil and shard then return (oil - 2 * shard - vendor(IMBUED_VIAL, 4800)) / 3 end
end
-- Brilliant Mana Oil = 3 Purple Lotus + 2 Large Brilliant Shard + 1 Imbued Vial
local BRILLIANT_MANA_OIL, PURPLE_LOTUS = 20748, 8831
local function shard_as_oil(oil_id, herb_id)
	local oil, herb = price_2day(oil_id), price_2day(herb_id)
	if oil and herb then return (oil - 3 * herb - vendor(IMBUED_VIAL, 4800)) / 2 end
end
local function shard_as_wizard_oil() return shard_as_oil(BRILLIANT_WIZARD_OIL, FIREBLOOM) end
local function shard_as_mana_oil() return shard_as_oil(BRILLIANT_MANA_OIL, PURPLE_LOTUS) end
local function lotus_as_mana_oil()
	local oil, shard = price_2day(BRILLIANT_MANA_OIL), price_2day(LARGE_BRILLIANT)
	if oil and shard then return (oil - 2 * shard - vendor(IMBUED_VIAL, 4800)) / 3 end
end
local function firebloom_as_potion()
	local pot, fire = price_2day(GREATER_FIRE_PROT), price_2day(ELEMENTAL_FIRE)
	if pot and fire then return pot - fire - vendor(CRYSTAL_VIAL, 400) end
end
local function fire_as_potion()
	local pot, bloom = price_2day(GREATER_FIRE_PROT), price_2day(FIREBLOOM)
	if pot and bloom then return pot - bloom - vendor(CRYSTAL_VIAL, 400) end
end
-- what the materials for one potion cost: 1 Firebloom + 1 Elemental Fire + 1 Crystal Vial
local function fire_potion_mats()
	local bloom, fire = price_2day(FIREBLOOM), price_2day(ELEMENTAL_FIRE)
	if bloom and fire then return bloom + fire + vendor(CRYSTAL_VIAL, 400) end
end

local function elixir_without(other)
	local a, b = price_2day(DREAMSHARD_ELIXIR), price_2day(other)
	if a and b then return a - vial_price() - b end
end
local function leather_each()
	local a, b = price_2day(ENCH_LEATHER), price_2day(RUGGED_LEATHER)
	if a and b then return a - b end
end
local function thorium_per_dust()
	local a, b = price_2day(ENCH_THORIUM), price_2day(THORIUM_BAR)
	if a and b then return (a - b) / 3 end
end
local function oil_without(other_essence)
	local a, b = price_2day(ENCH_GEMSTONE_OIL), price_2day(other_essence)
	if a and b then return a - GEMSTONE_OIL_VENDOR - b end
end

-- value of one unit of a material when it goes into this craft; nothing if the craft doesn't use it
local function crafted_unit(material, craft)
	if craft == 'thorium' then
		if material == ILLUSION_DUST then return thorium_per_dust(), true end
	elseif craft == 'leather' then
		if material == LESSER_ETERNAL then return leather_each(), true end
		if material == GREATER_ETERNAL then  -- one Greater Eternal splits into three Lesser
			local each = leather_each()
			return each and 3 * each, true
		end
	elseif craft == 'dreamshard' then
		if material == DREAM_DUST then return elixir_without(SMALL_DREAM_SHARD), true end
	elseif craft == 'wizardoil' then
		if material == LARGE_BRILLIANT then return shard_as_wizard_oil(), true end
	elseif craft == 'manaoil' then
		if material == LARGE_BRILLIANT then return shard_as_mana_oil(), true end
	elseif craft == 'oil' then
		if material == GREATER_ETERNAL then return oil_without(GREATER_NETHER), true end
		if material == GREATER_NETHER then return oil_without(GREATER_ETERNAL), true end
	end
end

-- expected value with this craft's materials crafted and everything else sold; uses = whether the item gives any of them
local function crafted_expectation(slot, quality, level, item_id, craft)
	local total, unknown, uses = 0, false, false
	for _, event in distribution(slot, quality, level, item_id) do
		local unit, crafted = crafted_unit(event.item_id, craft)
		if crafted then
			uses = true
		else
			unit = price_2day(event.item_id)
		end
		if unit then
			total = total + event.probability * (event.min_quantity + event.max_quantity) / 2 * unit
		else
			unknown = true
		end
	end
	return (not unknown) and total or nil, uses
end

local CRAFTS = {
	{key = 'thorium', label = 'Ench. Thorium'},
	{key = 'oil', label = 'Gemstone Oil'},
	{key = 'leather', label = 'Ench. Leather'},
	{key = 'dreamshard', label = 'Dreamshard Elixir'},
	{key = 'wizardoil', label = 'Brilliant Wizard Oil'},
	{key = 'manaoil', label = 'Brilliant Mana Oil'},
}

--- Tooltip lines { {label, value}, ... }: one per staple craft that this item's materials feed.
function M.crafted_lines(slot, quality, level, item_id)
	local lines = {}
	for i = 1, table.getn(CRAFTS) do
		local value, uses = crafted_expectation(slot, quality, level, item_id, CRAFTS[i].key)
		if uses then
			tinsert(lines, {label = 'Disenchant as ' .. CRAFTS[i].label .. ' (2-day): ', value = value})
		end
	end
	return lines
end

-- Local addition: on a material's own tooltip, what one unit is worth when crafted into
-- each staple product and the product is sold (two-day prices), and the gain or loss
-- against selling the material itself. { {label, value, diff}, ... }
local function bar_each()
	local a, d = price_2day(ENCH_THORIUM), price_2day(ILLUSION_DUST)
	if a and d then return a - 3 * d end
end
local function rugged_each()
	local a, l = price_2day(ENCH_LEATHER), price_2day(LESSER_ETERNAL)
	if a and l then return a - l end
end
local MATERIAL_CRAFTS = {
	[ILLUSION_DUST] = {{'Ench. Thorium', thorium_per_dust}},
	[THORIUM_BAR] = {{'Ench. Thorium', bar_each}},
	[LESSER_ETERNAL] = {{'Ench. Leather', leather_each}},
	[RUGGED_LEATHER] = {{'Ench. Leather', rugged_each}},
	[GREATER_ETERNAL] = {
		{'Gemstone Oil', function() return oil_without(GREATER_NETHER) end},
		{'3 Ench. Leather', function() local e = leather_each() return e and 3 * e end},
	},
	[GREATER_NETHER] = {{'Gemstone Oil', function() return oil_without(GREATER_ETERNAL) end}},
	[DREAM_DUST] = {{'Dreamshard Elixir', function() return elixir_without(SMALL_DREAM_SHARD) end}},
	[LARGE_BRILLIANT] = {
		{'Brilliant Wizard Oil', shard_as_wizard_oil},
		{'Brilliant Mana Oil', shard_as_mana_oil},
	},
	[PURPLE_LOTUS] = {{'Brilliant Mana Oil', lotus_as_mana_oil}},
	[FIREBLOOM] = {
		{'Brilliant Wizard Oil', firebloom_as_oil},
		{'Gr. Fire Protection', firebloom_as_potion},
	},
	[ELEMENTAL_FIRE] = {{'Gr. Fire Protection', fire_as_potion}},
	[SMALL_DREAM_SHARD] = {
		{'Dreamshard Elixir', function() return elixir_without(DREAM_DUST) end},
		{'Dreamtonic', function() return price_2day(DREAMTONIC) end},
	},
	[BRIGHT_DREAM_SHARD] = {
		{'3 Dreamshard Elixirs', function() local e = elixir_without(DREAM_DUST) return e and 3 * e end},
		{'3 Dreamtonics', function() local t = price_2day(DREAMTONIC) return t and 3 * t end},
	},
}
-- crafted products: on the product's own tooltip, what its materials cost and how much
-- more the product sells for (same line format: materials -> gain from crafting)
local PRODUCTS = {
	[GREATER_FIRE_PROT] = {'Craft from Firebloom + Elemental Fire: ', fire_potion_mats},
}

function M.material_lines(item_id)
	local lines = {}
	local product = PRODUCTS[item_id]
	if product then
		local cost, own = product[2](), price_2day(item_id)
		tinsert(lines, {label = product[1], value = cost, own = cost, diff = cost and own and own - cost})
		return lines
	end
	local crafts = MATERIAL_CRAFTS[item_id]
	if not crafts then return lines end
	local own = price_2day(item_id)
	for i = 1, table.getn(crafts) do
		local value = crafts[i][2]()
		tinsert(lines, {label = 'Craft into ' .. crafts[i][1] .. ': ', value = value, own = own, diff = value and own and value - own})
	end
	return lines
end

-- items the server disenchants as a different level band than their item level says
-- (seen in play): item id -> level to use
local DE_LEVEL = {
	[41345] = 40,  -- Royal Gemstone Staff (item level 41): gives Lesser Nether Essence
}

function M.distribution(slot, quality, level, item_id)
	level = DE_LEVEL[item_id] or level
    if not ARMOR[slot] and not WEAPON[slot] or level == 0 then
        return T.acquire()
	elseif --special items not following general rules
	--twillight cultist items are not disenchantable
	item_id==20408 or item_id==20407 or item_id==20406 
	--enchanting created wands are not disenchantable
	or item_id==11288 or item_id==11290 or item_id==11287 or item_id==11289 
	then
		return T.acquire()
    end

    local function p(probability_armor, probability_weapon)
        if ARMOR[slot] then
            return probability_armor
        elseif WEAPON[slot] then
            return probability_weapon
        end
    end

    if quality == UNCOMMON then
        if level <= 10 then
            return T.temp-T.list(
	            T.temp-T.map('item_id', 10940, 'min_quantity', 1, 'max_quantity', 2, 'probability', p(.8, .2)),
	            T.temp-T.map('item_id', 10938, 'min_quantity', 1, 'max_quantity', 2, 'probability', p(.2, .8))
            )
        elseif level <= 15 then
            return T.temp-T.list(
	            T.temp-T.map('item_id', 10940, 'min_quantity', 2, 'max_quantity', 3, 'probability', p(.75, .2)),
	            T.temp-T.map('item_id', 10939, 'min_quantity', 1, 'max_quantity', 2, 'probability', p(.2, .75)),
	            T.temp-T.map('item_id', 10978, 'min_quantity', 1, 'max_quantity', 1, 'probability', .05)
            )
        elseif level <= 20 then
            return T.temp-T.list(
	            T.temp-T.map('item_id', 10940, 'min_quantity', 4, 'max_quantity', 6, 'probability', p(.75, .15)),
	            T.temp-T.map('item_id', 10998, 'min_quantity', 1, 'max_quantity', 2, 'probability', p(.15, .75)),
	            T.temp-T.map('item_id', 10978, 'min_quantity', 1, 'max_quantity', 1, 'probability', .10)
            )
        elseif level <= 25 then
            return T.temp-T.list(
	            T.temp-T.map('item_id', 11083, 'min_quantity', 1, 'max_quantity', 2, 'probability', p(.75, .2)),
	            T.temp-T.map('item_id', 11082, 'min_quantity', 1, 'max_quantity', 2, 'probability', p(.2, .75)),
	            T.temp-T.map('item_id', 11084, 'min_quantity', 1, 'max_quantity', 1, 'probability', .05)
			)
        elseif level <= 30 then
            return T.temp-T.list(
	            T.temp-T.map('item_id', 11083, 'min_quantity', 2, 'max_quantity', 5, 'probability', p(.75, .2)),
	            T.temp-T.map('item_id', 11134, 'min_quantity', 1, 'max_quantity', 2, 'probability', p(.2, .75)),
	            T.temp-T.map('item_id', 11138, 'min_quantity', 1, 'max_quantity', 1, 'probability', .05)
            )
        elseif level <= 35 then
            return T.temp-T.list(
	            T.temp-T.map('item_id', 11137, 'min_quantity', 1, 'max_quantity', 2, 'probability', p(.75, .2)),
	            T.temp-T.map('item_id', 11135, 'min_quantity', 1, 'max_quantity', 2, 'probability', p(.2, .75)),
	            T.temp-T.map('item_id', 11139, 'min_quantity', 1, 'max_quantity', 1, 'probability', .05)
            )
        elseif level <= 40 then
            return T.temp-T.list(
	            T.temp-T.map('item_id', 11137, 'min_quantity', 2, 'max_quantity', 5, 'probability', p(.75, .2)),
	            T.temp-T.map('item_id', 11174, 'min_quantity', 1, 'max_quantity', 2, 'probability', p(.2, .75)),
	            T.temp-T.map('item_id', 11177, 'min_quantity', 1, 'max_quantity', 1, 'probability', .05)
            )
        elseif level <= 45 then
            return T.temp-T.list(
	            T.temp-T.map('item_id', 11176, 'min_quantity', 1, 'max_quantity', 2, 'probability', p(.75, .2)),
	            T.temp-T.map('item_id', 11175, 'min_quantity', 1, 'max_quantity', 2, 'probability', p(.2, .75)),
	            T.temp-T.map('item_id', 11178, 'min_quantity', 1, 'max_quantity', 1, 'probability', .05)
            )
        elseif level <= 50 then
            return T.temp-T.list(
	            T.temp-T.map('item_id', 11176, 'min_quantity', 2, 'max_quantity', 5, 'probability', p(.75, .22)),
	            T.temp-T.map('item_id', 16202, 'min_quantity', 1, 'max_quantity', 2, 'probability', p(.2, .75)),
	            T.temp-T.map('item_id', 14343, 'min_quantity', 1, 'max_quantity', 1, 'probability', p(.05, .03))
            )
        elseif level <= 55 then
            return T.temp-T.list(
	            T.temp-T.map('item_id', 16204, 'min_quantity', 1, 'max_quantity', 2, 'probability', p(.75, .22)),
	            T.temp-T.map('item_id', 16203, 'min_quantity', 1, 'max_quantity', 2, 'probability', p(.2, .75)),
	            T.temp-T.map('item_id', 14344, 'min_quantity', 1, 'max_quantity', 1, 'probability', p(.05, .03))
			)
        elseif level <= 60 then
            return T.temp-T.list(
	            T.temp-T.map('item_id', 16204, 'min_quantity', 2, 'max_quantity', 5, 'probability', p(.75, .22)),
	            T.temp-T.map('item_id', 16203, 'min_quantity', 2, 'max_quantity', 3, 'probability', p(.2, .75)),
	            T.temp-T.map('item_id', 14344, 'min_quantity', 1, 'max_quantity', 1, 'probability', p(.05, .03))
			)
        end
    elseif quality == RARE then
        if level <= 20 then
            return T.temp-T.list(T.temp-T.map('item_id', 10978, 'min_quantity', 1, 'max_quantity', 1, 'probability', 1))
        elseif level <= 25 then
            return T.temp-T.list(T.temp-T.map('item_id', 11084, 'min_quantity', 1, 'max_quantity', 1, 'probability', 1))
        elseif level <= 30 then
            return T.temp-T.list(T.temp-T.map('item_id', 11138, 'min_quantity', 1, 'max_quantity', 1, 'probability', 1))
        elseif level <= 35 then
            return T.temp-T.list(T.temp-T.map('item_id', 11139, 'min_quantity', 1, 'max_quantity', 1, 'probability', 1))
        elseif level <= 40 then
            return T.temp-T.list(T.temp-T.map('item_id', 11177, 'min_quantity', 1, 'max_quantity', 1, 'probability', 1))
        elseif level <= 45 then
            return T.temp-T.list(T.temp-T.map('item_id', 11178, 'min_quantity', 1, 'max_quantity', 1, 'probability', 1))
        elseif level <= 50 then
            return T.temp-T.list(T.temp-T.map('item_id', 14343, 'min_quantity', 1, 'max_quantity', 1, 'probability', 1))
        elseif level <= 55 then
            return T.temp-T.list(T.temp-T.map('item_id', 14344, 'min_quantity', 1, 'max_quantity', 1, 'probability', .995), T.temp-T.map('item_id', 20725, 'min_quantity', 1, 'max_quantity', 1, 'probability', .005))
        elseif level <= 60 then
            return T.temp-T.list(T.temp-T.map('item_id', 14344, 'min_quantity', 1, 'max_quantity', 1, 'probability', .995), T.temp-T.map('item_id', 20725, 'min_quantity', 1, 'max_quantity', 1, 'probability', .005))
        end
    elseif quality == EPIC then
        if level <= 40 then
            return T.temp-T.list(T.temp-T.map('item_id', 11177, 'min_quantity', 2, 'max_quantity', 4, 'probability', 1))
        elseif level <= 45 then
            return T.temp-T.list(T.temp-T.map('item_id', 11178, 'min_quantity', 2, 'max_quantity', 4, 'probability', 1))
        elseif level <= 50 then
            return T.temp-T.list(T.temp-T.map('item_id', 14343, 'min_quantity', 2, 'max_quantity', 4, 'probability', 1))
        elseif level <= 55 then
            return T.temp-T.list(T.temp-T.map('item_id', 20725, 'min_quantity', 1, 'max_quantity', 1, 'probability', 1))
        elseif level <= 60 then
            return T.temp-T.list(T.temp-T.map('item_id', 20725, 'min_quantity', 1, 'max_quantity', 2, 'probability', 1))
        end
    end
    return T.acquire()
end