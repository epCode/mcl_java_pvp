-- Weapon and tool attack stats (Java 1.21 attack_damage / attack_speed).
--
-- Java weapons have a fractional attack damage (shovels deal 2.5 ... 6.5)
-- and an attack speed (attacks per second).  The engine can only store an
-- integer damage group, so the exact values are kept in the item
-- definition fields `_jp_attack_damage` and `_jp_attack_speed`, which
-- melee.lua uses.  tool_capabilities are updated as well (rounded) so the
-- tooltips and Mineclonia's own mob combat use the Java values.

local jp = mcl_java_pvp

-- Total attack damage (including the player's base 1) and attack speed.
local MATERIALS = { "wood", "gold", "stone", "copper", "iron", "diamond", "netherite" }

local STATS = {
	sword = {
		wood = { 4, 1.6 }, gold = { 4, 1.6 }, stone = { 5, 1.6 }, copper = { 5, 1.6 },
		iron = { 6, 1.6 }, diamond = { 7, 1.6 }, netherite = { 8, 1.6 },
	},
	axe = {
		wood = { 7, 0.8 }, gold = { 7, 1.0 }, stone = { 9, 0.8 }, copper = { 9, 0.8 },
		iron = { 9, 0.9 }, diamond = { 9, 1.0 }, netherite = { 10, 1.0 },
	},
	pick = {
		wood = { 2, 1.2 }, gold = { 2, 1.2 }, stone = { 3, 1.2 }, copper = { 3, 1.2 },
		iron = { 4, 1.2 }, diamond = { 5, 1.2 }, netherite = { 6, 1.2 },
	},
	shovel = {
		wood = { 2.5, 1.0 }, gold = { 2.5, 1.0 }, stone = { 3.5, 1.0 }, copper = { 3.5, 1.0 },
		iron = { 4.5, 1.0 }, diamond = { 5.5, 1.0 }, netherite = { 6.5, 1.0 },
	},
}
local HOE_SPEED = { wood = 1, gold = 1, stone = 2, copper = 2, iron = 3, diamond = 4, netherite = 4 }

-- Durability cost of one attack (Java: weapons 1, tools 2).
jp.ATTACK_DURABILITY = { sword = 1, mace = 1, trident = 1, axe = 2, pick = 2, shovel = 2, hoe = 2 }

local function set_stats(name, damage, speed, kind)
	local def = core.registered_items[name]
	if not def then
		core.log("warning", "[mcl_java_pvp] Weapon not found: " .. name)
		return
	end
	local caps = table.copy(def.tool_capabilities or {})
	caps.full_punch_interval = 1 / speed
	caps.damage_groups = table.copy(caps.damage_groups or {})
	caps.damage_groups.fleshy = math.floor(damage + 0.5)
	core.override_item(name, {
		tool_capabilities = caps,
		_jp_attack_damage = damage,
		_jp_attack_speed = speed,
		_jp_weapon_kind = kind,
	})
end

for kind, by_material in pairs(STATS) do
	for _, mat in ipairs(MATERIALS) do
		local s = by_material[mat]
		set_stats("mcl_tools:" .. kind .. "_" .. mat, s[1], s[2], kind)
	end
end
for _, mat in ipairs(MATERIALS) do
	set_stats("mcl_farming:hoe_" .. mat, 1, HOE_SPEED[mat], "hoe")
end

if core.registered_items["mcl_tridents:trident"] then
	set_stats("mcl_tridents:trident", 9, 1.1, "trident")
end
-- The mace's own on_use is replaced in melee.lua.
set_stats("mcl_tools:mace", 6, 0.6, "mace")

-- Shears have tool_capabilities without damage groups and therefore deal 0
-- damage; in Java they hit like any other item (1 damage, speed 4).
if core.registered_items["mcl_tools:shears"] then
	set_stats("mcl_tools:shears", 1, 4.0, nil)
end

-- Everything else (and the empty hand) attacks with 1 damage at speed 4.
jp.HAND_DAMAGE = 1
jp.HAND_SPEED = 4

-- Returns attack damage, attack speed and weapon kind of an item stack.
function jp.weapon_stats(stack)
	local def = stack:get_definition()
	if def and def._jp_attack_damage then
		return def._jp_attack_damage, def._jp_attack_speed, def._jp_weapon_kind
	end
	return jp.HAND_DAMAGE, jp.HAND_SPEED, nil
end

------------------------------------------------------------------------
-- Reach
------------------------------------------------------------------------
-- Java: entity_interaction_range 3.0 (creative 5.0), block_interaction_range
-- 4.5 (creative 5.0).  Luanti uses one `range` for both, so items keep the
-- 4.5 block reach and melee.lua rejects melee hits on players and entities
-- farther than 3.0 (+ a small latency allowance) from the attacker's eyes.
jp.ENTITY_REACH = jp.setting_number("entity_reach", 3.0)
jp.ENTITY_REACH_CREATIVE = 5.0
jp.REACH_TOLERANCE = jp.setting_number("reach_tolerance", 0.5)
