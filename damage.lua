-- Damage pipeline: Java 1.21 order of operations for damage to players.
--
-- Java (LivingEntity.hurtServer / actuallyHurt):
--   difficulty scaling -> Fire Resistance immunity -> shield -> hurt
--   invulnerability (10 ticks, only the excess over the last hit) ->
--   armor (+ armor durability, Breach) -> Resistance -> enchantment
--   protection (EPF) -> absorption -> health; totem on death.
--
-- Mineclonia ran crits, Resistance and (multiplicative) Strength/Weakness
-- inside the victim's damage chain and put shield, armor and Strength at the
-- same priority (undefined order).  This file removes those modifiers and
-- installs Java-ordered replacements.  Priorities used (ascending):
--   -1000 difficulty (Mineclonia, kept)        -50 Fire Resistance (kept)
--     -45 shield (shields.lua)                 -40 hurt invulnerability
--      10 armor -> Resistance -> EPF -> Thorns 300 absorption (kept)
--    1000 totem (kept)
--
-- Newer Mineclonia (with mcl_movement) already does part of this: its
-- mcl_damage applies the hurt cooldown itself between the modifiers below
-- and above mcl_damage.COOLDOWN_PRIORITY (-10), Resistance runs after armor
-- (priority 10), shields at -20, and Strength/Weakness are +3/-4 attack
-- damage for attacks not marked `attack_damage_applied'.  There this file
-- uses that cooldown instead of its own and removes the Resistance and
-- shield modifiers it replaces; this mod's own attacks are marked.

local jp = mcl_java_pvp

------------------------------------------------------------------------
-- Remove Mineclonia modifiers that are replaced
------------------------------------------------------------------------

-- Random additive crits and sprint "knockback" (melee.lua does Java crits).
jp.remove_modifier_from("mcl_criticals/init.lua")
-- Multiplicative Strength/Weakness (melee.lua: +3 / -4 attack damage).
-- Newer Mineclonia has Java's additive version at -150 instead, which
-- leaves alone attacks marked attack_damage_applied (all of this mod's) and
-- still covers mobs: keep that one.
if not jp.has_modifier_from("mcl_potions/functions.lua", -150) then
	jp.remove_modifier_from("mcl_potions/functions.lua", 0)
end
-- Resistance before armor (re-implemented after armor below).  Resistance
-- (priority -50; 10 in newer Mineclonia) and Absorption (priority 300) are
-- closures created by the `dmg_flag == ""` branch of generate_modifier_func
-- in mcl_potions; Fire Resistance comes from another branch.  Find that
-- branch's line in the source so the right closure is removed.
do
	local line
	local f = io.open(core.get_modpath("mcl_potions") .. "/functions.lua", "r")
	if f then
		local n = 0
		for l in f:lines() do
			n = n + 1
			if l:find('if dmg_flag == "" then return function', 1, true) then
				line = n
				break
			end
		end
		f:close()
	end
	if line then
		jp.remove_modifier_from("mcl_potions/functions.lua", { -50, 10 }, line)
	else
		core.log("warning", "[mcl_java_pvp] Resistance modifier not found; Resistance may apply twice")
	end
end
-- Armor/EPF/Breach/Thorns (re-implemented below).
jp.remove_modifier_from("mcl_armor/damage.lua", 0)
-- Mace: fall damage negated for 2 game seconds after any mace hit
-- (melee.lua resets fall distance only after a real smash attack).
jp.remove_modifier_from("mcl_tools/mace.lua", 0)
-- Fall damage modifier: movement.lua computes Java fall damage itself
-- (including water/cobweb/vines/powder snow and Jump Boost).
jp.remove_modifier_from("mcl_player/init.lua", -200)

------------------------------------------------------------------------
-- Damage type flags (Java damage type tags)
------------------------------------------------------------------------

local T = mcl_damage.types
-- fly_into_wall bypasses armor in Java.
T.fly_into_wall.bypasses_armor = true
-- Tridents are projectiles (#is_projectile), so Projectile Protection works.
T.trident.is_projectile = true
-- Wither skulls are projectiles, not explosions (the skull's explosion is a
-- separate "explosion" damage event).
T.wither_skull.is_projectile = true
T.wither_skull.is_explosion = nil
-- Java campfire damage: is_fire, reduced by armor, blocked by Fire Res.
T.campfire = { is_fire = true }
-- Java dragon breath bypasses shields (bypasses_armor already set).

------------------------------------------------------------------------
-- Campfire damage type (Mineclonia reported campfire damage as "generic",
-- which bypassed armor, Fire Protection and Fire Resistance).
------------------------------------------------------------------------

local from_mt = mcl_damage.from_mt
function mcl_damage.from_mt(mt_reason)
	local cached = mt_reason._mcl_cached_reason
	local reason = from_mt(mt_reason)
	if not cached and mt_reason.type == "node_damage" and mt_reason.node
			and core.get_item_group(mt_reason.node, "campfire") > 0 then
		reason.type = "campfire"
		reason.flags = T.campfire
	end
	return reason
end

------------------------------------------------------------------------
-- Fire block damage: Java in_fire deals 1 per hit, limited to one hit per
-- 10 ticks by i-frames = 2/s (soul fire 4/s).  The engine applies
-- damage_per_second once per second, so double it.
------------------------------------------------------------------------

for _, name in ipairs({ "mcl_fire:fire", "mcl_fire:eternal_fire", "mcl_blackstone:soul_fire" }) do
	local def = core.registered_nodes[name]
	if def and def.damage_per_second and def.damage_per_second > 0 then
		core.override_item(name, { damage_per_second = def.damage_per_second * 2 })
	end
end

------------------------------------------------------------------------
-- Hurt invulnerability ("i-frames")
------------------------------------------------------------------------
-- After a hit a player is invulnerable for 10 ticks (invulnerableTime 20,
-- checked "> 10").  During that window a new hit is ignored unless it is
-- stronger than the last one, in which case only the difference is dealt
-- and no knockback is applied.  Compared on damage after difficulty and
-- shield, before armor.

jp.IFRAME_TIME = 0.5

-- Result of the latest damage event per player, for knockback decisions:
--   fresh   = the hit started a new invulnerability window (base knockback)
--   applied = the hit dealt damage (or was absorbed) at all
--   blocked = a shield blocked it
jp.last_hurt = jp.player_table()

-- Every hit starts out as not applied: a modifier that cancels it (respawn
-- invulnerability, a shield...) must not leave the previous hit's result.
mcl_damage.register_modifier(function(obj)
	if obj:is_player() then
		jp.last_hurt[obj] = { fresh = false, applied = false, time = jp.now() }
	end
end, -math.huge)

if mcl_damage.apply_hurt_cooldown and mcl_damage.get_player_hurt_state
		and mcl_damage.COOLDOWN_PRIORITY then
	-- Mineclonia's own hurt cooldown (same rules; mcl_damage.time clock,
	-- 10 ticks less its rounding allowance).
	local WINDOW = jp.IFRAME_TIME - 0.025

	local function in_window(state)
		return state._hurt_stamp ~= nil and mcl_damage.time - state._hurt_stamp < WINDOW
	end

	function jp.in_iframes(player)
		return in_window(mcl_damage.get_player_hurt_state(player))
	end

	function jp.reset_iframes(player)
		local state = mcl_damage.get_player_hurt_state(player)
		state._hurt_stamp, state._last_hurt = nil, nil
	end

	function jp.register_blocked_hit(player)
		local state = mcl_damage.get_player_hurt_state(player)
		if not in_window(state) then
			state._hurt_stamp, state._last_hurt = mcl_damage.time, 0
		end
		jp.last_hurt[player] = { fresh = false, applied = false, blocked = true, time = jp.now() }
	end

	-- Runs right after the cooldown, only for hits it let through
	-- (`partial_hurt': only the excess over the last hit, no knockback).
	mcl_damage.register_modifier(function(obj, damage, reason)
		if obj:is_player() and damage > 0 then
			jp.last_hurt[obj] = { fresh = not reason.partial_hurt, applied = true, time = jp.now() }
		end
	end, mcl_damage.COOLDOWN_PRIORITY)
else
	local hurt = jp.player_table() -- player -> {last = amount, time = t}

	function jp.in_iframes(player)
		local h = hurt[player]
		return h and (jp.now() - h.time) < jp.IFRAME_TIME
	end

	function jp.reset_iframes(player)
		hurt[player] = nil
	end

	-- Called by shields.lua when a hit is fully blocked (Java still starts
	-- the invulnerability window with lastHurt = 0 if none was active).
	function jp.register_blocked_hit(player)
		if not jp.in_iframes(player) then
			hurt[player] = { last = 0, time = jp.now() }
		end
		jp.last_hurt[player] = { fresh = false, applied = false, blocked = true, time = jp.now() }
	end

	mcl_damage.register_modifier(function(obj, damage, reason)
		if not obj:is_player() or damage <= 0 then return end
		local now = jp.now()
		if reason.flags.bypasses_invulnerability then
			jp.last_hurt[obj] = { fresh = true, applied = true, time = now }
			return damage
		end
		local h = hurt[obj]
		if h and now - h.time < jp.IFRAME_TIME then
			if damage <= h.last then
				jp.last_hurt[obj] = { fresh = false, applied = false, time = now }
				return 0
			end
			local excess = damage - h.last
			h.last = damage
			jp.last_hurt[obj] = { fresh = false, applied = true, time = now }
			return excess
		end
		hurt[obj] = { last = damage, time = now }
		jp.last_hurt[obj] = { fresh = true, applied = true, time = now }
		return damage
	end, -40)

	core.register_on_respawnplayer(function(player)
		hurt[player] = nil
	end)
end

------------------------------------------------------------------------
-- Armor, Resistance, enchantment protection and Thorns
------------------------------------------------------------------------

local use_durability = mcl_armor.use_durability

local function add_epf(tbl, enchantments)
	local epf = 0
	if tbl then
		for _, ench in pairs(tbl) do
			local level = enchantments[ench.id]
			if level and level > 0 then
				epf = epf + level * ench.factor
			end
		end
	end
	return epf
end

-- Java CombatRules.getDamageAfterAbsorb with Breach (armor_effectiveness).
function jp.armor_reduce(damage, armor, toughness, breach_level)
	local f = 2 + toughness / 4
	local g = jp.clamp(armor - damage / f, armor * 0.2, 20)
	local h = g / 25
	if breach_level and breach_level > 0 then
		h = jp.clamp(h - 0.15 * breach_level, 0, 1)
	end
	return damage * (1 - h)
end

-- Breach level of the weapon that dealt this hit (melee only).
local function breach_level(reason)
	local weapon = reason.jp_weapon
	if not weapon and reason.type == "player" and reason.source and reason.source == reason.direct
			and reason.source:is_player() then
		weapon = reason.source:get_wielded_item()
	end
	if weapon and not weapon:is_empty() then
		return mcl_enchanting.get_enchantment(weapon, "breach")
	end
	return 0
end

mcl_damage.register_modifier(function(obj, damage, reason)
	local flags = reason.flags
	if damage <= 0 then return end

	local inv = mcl_util.get_inventory(obj)
	local luaentity = obj:get_luaentity()
	local is_mob = luaentity and luaentity.is_mob and luaentity.armor_list
	if is_mob then inv = nil end

	local raw = damage
	local points, toughness, epf = 0, 0, 0
	local pieces = {}

	if inv or is_mob then
		for name, element in pairs(mcl_armor.elements) do
			local stack
			if is_mob then
				stack = ItemStack(luaentity.armor_list[name] or "")
			else
				stack = inv:get_stack("armor", element.index)
			end
			if not stack:is_empty() then
				local itemname = stack:get_name()
				local enchantments = mcl_enchanting.get_enchantments(stack)
				local combat = core.get_item_group(itemname, "non_combat_armor") == 0
					and core.get_item_group(itemname, "elytra") == 0
				table.insert(pieces, { name = name, element = element, stack = stack,
					enchantments = enchantments, combat = combat })
				if combat then
					points = points + core.get_item_group(itemname, "mcl_armor_points")
					toughness = toughness + core.get_item_group(itemname, "mcl_armor_toughness")
				end
				if not flags.bypasses_magic then
					epf = epf + add_epf(mcl_armor.protection_enchantments.wildcard, enchantments)
					epf = epf + add_epf(mcl_armor.protection_enchantments.types[reason.type], enchantments)
					for flag, value in pairs(flags) do
						if value then
							epf = epf + add_epf(mcl_armor.protection_enchantments.flags[flag], enchantments)
						end
					end
				end
			end
		end
	end

	local function save(p)
		if is_mob then
			luaentity.armor_list[p.name] = p.stack:to_string()
		end
	end

	-- 1. Armor and armor durability (Java: max(1, floor(damage / 4)) per
	--    piece, from the damage before armor; netherite is immune to fire
	--    damage wear).
	if not flags.bypasses_armor then
		local wear = math.max(1, math.floor(raw / 4))
		for _, p in ipairs(pieces) do
			if p.combat and not (flags.is_fire
					and core.get_item_group(p.stack:get_name(), "armor_netherite") > 0) then
				use_durability(obj, inv, p.element.index, p.stack, wear)
				save(p)
			end
		end
		damage = jp.armor_reduce(damage, points, toughness, breach_level(reason))
	end

	-- 2. Resistance: 20% per level, after armor (not for starvation/void).
	if not flags.bypasses_magic then
		local res = jp.effect_level(obj, "resistance")
		if res > 0 then
			damage = damage * math.max(0, 25 - 5 * res) / 25
		end
	end

	-- 3. Enchantment protection factor, capped at 20 (80%).
	if epf > 0 and damage > 0 then
		damage = damage * (1 - math.min(20, epf) / 25)
	end

	-- 4. Thorns: each piece rolls 15% x level; damage is a uniform float in
	--    [1, 5).  The attacker's own invulnerability means only the largest
	--    roll counts.  Each triggering piece loses 2 durability.
	local source = reason.source
	if source and source ~= obj and reason.type ~= "thorns" and source:is_valid()
			and jp.is_living(source) then
		local thorns = 0
		for _, p in ipairs(pieces) do
			local level = p.enchantments.thorns or 0
			if level > 0 and math.random() < 0.15 * level then
				thorns = math.max(thorns, 1 + math.random() * 4)
				use_durability(obj, inv, p.element.index, p.stack, 2)
				save(p)
			end
		end
		if thorns > 0 then
			mcl_util.deal_damage(source, thorns, { type = "thorns", direct = obj,
				attack_damage_applied = true })
		end
	end

	if obj:is_valid() then
		mcl_armor.update(obj)
	end
	return damage
end, 10)

------------------------------------------------------------------------
-- Netherite armor durability (Java 407/592/555/481; Mineclonia used the
-- leggings value 555 as the base, giving 381/556/521/451).  Mineclonia
-- stores Java durability + 1 as mcl_armor_uses; keep that convention.
------------------------------------------------------------------------

for piece, uses in pairs({ helmet = 407, chestplate = 592, leggings = 555, boots = 481 }) do
	local name = "mcl_armor:" .. piece .. "_netherite"
	local def = core.registered_items[name]
	if def then
		local groups = table.copy(def.groups)
		groups.mcl_armor_uses = uses + 1
		core.override_item(name, { groups = groups })
	end
end

------------------------------------------------------------------------
-- Fire Protection burn time: Java sums the levels of all pieces (burning
-- time -15% per level, 7+ total levels = no burning); Mineclonia used the
-- highest single piece.  Pre-scale the burn time so Mineclonia's own
-- max-level reduction ends up at the Java value.
------------------------------------------------------------------------

local set_on_fire = mcl_burning.set_on_fire
function mcl_burning.set_on_fire(obj, burn_time, ...)
	local inv = obj and obj.is_player and obj:is_player() and obj:get_inventory()
	if not inv or not burn_time or burn_time <= 0 then
		return set_on_fire(obj, burn_time, ...)
	end
	local sum, max = 0, 0
	for _, stack in ipairs(inv:get_list("armor") or {}) do
		local lvl = mcl_enchanting.get_enchantment(stack, "fire_protection")
		sum = sum + lvl
		if lvl > max then max = lvl end
	end
	if sum > 0 then
		local target = burn_time * math.max(0, 1 - 0.15 * sum)
		if target <= 0 then return end
		burn_time = target / math.max(0.01, 1 - 0.15 * max)
	end
	return set_on_fire(obj, burn_time, ...)
end

------------------------------------------------------------------------
-- Totem of Undying: Java does not refill air.  (Mineclonia sets breath to
-- 10 when it is below 11; harmless, left as is.)
------------------------------------------------------------------------
