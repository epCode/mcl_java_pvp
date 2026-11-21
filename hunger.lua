-- Hunger, natural regeneration, eating and food items (Java Edition 1.21).
--
-- Java reference: net.minecraft.world.food.FoodData, Player.aiStep,
-- LivingEntity/Player.actuallyHurt, FoodProperties, ChorusFruitItem and the
-- data/minecraft/damage_type/*.json "exhaustion" values.
--
-- Units: Mineclonia stores exhaustion as Java exhaustion * 1000 (Java's
-- 4.0 threshold is 4000 here); hunger and saturation use Java units.
--
-- What this file changes:
--   * exhaustion: capped at 40.0 (not 4.0) and consumed 4.0 per tick with
--     the remainder carried over; saturation drops by 1.0 (not 1.5); in
--     Peaceful saturation still drains (food does not); no exhaustion for
--     creative players (Java abilities.invulnerable).
--   * the Mineclonia food globalstep is replaced by an exact 20 Hz port of
--     FoodData.tick (saturated regen every 10 ticks healing min(sat,6)/6,
--     slow regen every 80 ticks, starvation every 80 ticks) plus the
--     Peaceful extras of Player.aiStep.
--   * damage exhaustion: the damage type's Java exhaustion value (0.1 or
--     0), only when damage is actually dealt after absorption.
--   * eating: food first, then saturation capped at the *new* food level,
--     then the food's effects; item cooldowns block eating; Java eating
--     durations (32 ticks, honey 40, dried kelp 16).
--   * food values / effects: sweet berries, glow berries, pufferfish,
--     honey bottle (cures Poison), suspicious stew durations.
--   * chorus fruit: Java teleport algorithm, 20 tick cooldown, fall
--     distance reset, may land on fire/magma/cactus (only liquids and
--     collisions are rejected).
--   * death XP drop: min(7 * level, 100) points.

local jp = mcl_java_pvp
local TICK = jp.TICK

local function warn(msg)
	core.log("warning", "[mcl_java_pvp] hunger.lua: " .. msg)
end

if not mcl_hunger then
	warn("mcl_hunger not found, hunger changes disabled")
	return
end

local EXHAUST_SCALE = 1000          -- Mineclonia exhaustion units per Java unit
local EXHAUST_MAX = 40 * EXHAUST_SCALE
local EXHAUST_STEP = 4 * EXHAUST_SCALE

-- Optional "gamerule naturalRegeneration" (default true).
local natural_regen = jp.enabled("natural_regeneration")

local function difficulty()
	return (mcl_vars and mcl_vars.difficulty) or 2
end

------------------------------------------------------------------------
-- Generic FoodData helpers (also used by effects.lua for Saturation)
------------------------------------------------------------------------

-- Java FoodData.add(food, saturation): food = clamp(food + n, 0, 20);
-- saturation = clamp(saturation + s, 0, food) using the *new* food level.
-- `sat_points` is the saturation actually added (Java nutrition *
-- saturationModifier * 2, which is what Mineclonia's _mcl_saturation holds).
function jp.food_eat(player, nutrition, sat_points)
	if not mcl_hunger.active or not player or not player:is_player() then return end
	local food = math.min(20, math.max(0, mcl_hunger.get_hunger(player) + (nutrition or 0)))
	mcl_hunger.set_hunger(player, food, true)
	local sat = mcl_hunger.get_saturation(player) + (sat_points or 0)
	mcl_hunger.set_saturation(player, math.min(math.max(sat, 0), food))
end

------------------------------------------------------------------------
-- 1. Exhaustion (FoodData.addExhaustion / Player.causeFoodExhaustion)
------------------------------------------------------------------------

if mcl_hunger.active then
	-- Java caps exhaustion at 40.0 (Mineclonia capped at the 4.0 threshold,
	-- losing any excess).
	function mcl_hunger.set_exhaustion(player, exhaustion)
		exhaustion = math.min(EXHAUST_MAX, math.max(0.0, exhaustion))
		player:get_meta():set_string("mcl_hunger:exhaustion", tostring(exhaustion))
		return true
	end

	-- FoodData.addExhaustion: no creative check (used by regeneration).
	local function add_exhaustion(player, amount)
		if amount <= 0 then return end
		mcl_hunger.set_exhaustion(player, mcl_hunger.get_exhaustion(player) + amount)
	end
	jp.add_food_exhaustion = add_exhaustion

	-- Player.causeFoodExhaustion: ignored for invulnerable (creative)
	-- players.  Unlike Mineclonia, exhaustion also accumulates on Peaceful
	-- (it drains saturation there, but never food).  The 4.0 threshold is
	-- processed once per tick in the food tick below, as in Java.
	function mcl_hunger.exhaust(playername, increase)
		local player = core.get_player_by_name(playername)
		if not player or not increase then return false end
		if jp.is_creative(player) then return false end
		add_exhaustion(player, increase)
		return true
	end
end

------------------------------------------------------------------------
-- 2. Natural regeneration / starvation (FoodData.tick, Player.aiStep)
------------------------------------------------------------------------

-- Line on which a Mineclonia source file first matches `pattern` after a
-- line matching `after` (debug.getupvalue is unavailable under mod
-- security, so callbacks are identified by file and line).
local function find_line(modname, file, after, pattern)
	local path = core.get_modpath(modname)
	local f = path and io.open(path .. "/" .. file, "r")
	if not f then return nil end
	local n, armed, line = 0, after == nil, nil
	for l in f:lines() do
		n = n + 1
		if not armed and l:find(after, 1, true) then
			armed = true
		elseif armed and l:find(pattern, 1, true) then
			line = n
			break
		end
	end
	f:close()
	return line
end

local food_state = jp.player_table() -- player -> {timer = foodTickTimer, ticks = tickCount}

local function food_tick(player)
	local st = food_state[player]
	if not st then
		st = { timer = 0, ticks = 0 }
		food_state[player] = st
	end
	st.ticks = st.ticks + 1

	local hp = mcl_damage.get_hp(player)
	if hp <= 0 then return end -- dead players do not tick food
	local diff = difficulty()
	local hp_max = player:get_properties().hp_max or 20

	local food = mcl_hunger.get_hunger(player)
	local sat = mcl_hunger.get_saturation(player)
	local exh = mcl_hunger.get_exhaustion(player)

	-- Exhaustion: one 4.0 step per tick, remainder carried over.
	if exh > EXHAUST_STEP then
		mcl_hunger.set_exhaustion(player, exh - EXHAUST_STEP)
		if sat > 0 then
			sat = math.max(sat - 1, 0)
			mcl_hunger.set_saturation(player, sat)
		elseif diff ~= 0 then
			food = math.max(food - 1, 0)
			mcl_hunger.set_hunger(player, food, true)
		end
	end

	local hurt = hp > 0 and hp < hp_max
	if natural_regen and sat > 0 and hurt and food >= 20 then
		st.timer = st.timer + 1
		if st.timer >= 10 then
			local f = math.min(sat, 6)
			mcl_damage.heal_player(player, f / 6)
			jp.add_food_exhaustion(player, f * EXHAUST_SCALE)
			st.timer = 0
		end
	elseif natural_regen and food >= 18 and hurt then
		st.timer = st.timer + 1
		if st.timer >= 80 then
			mcl_damage.heal_player(player, 1)
			jp.add_food_exhaustion(player, 6 * EXHAUST_SCALE)
			st.timer = 0
		end
	elseif food <= 0 then
		st.timer = st.timer + 1
		if st.timer >= 80 then
			if hp > 10 or diff == 3 or (hp > 1 and diff == 2) then
				mcl_util.deal_damage(player, 1, { type = "starve" })
			end
			st.timer = 0
		end
	else
		st.timer = 0
	end

	-- Player.aiStep, Peaceful with naturalRegeneration.
	if diff == 0 and natural_regen then
		if st.ticks % 20 == 0 then
			hp = mcl_damage.get_hp(player)
			if hp > 0 and hp < hp_max then
				mcl_damage.heal_player(player, 1)
			end
			sat = mcl_hunger.get_saturation(player)
			if sat < 20 then
				-- (Mineclonia additionally caps saturation at the food level.)
				mcl_hunger.set_saturation(player, sat + 1)
			end
		end
		if st.ticks % 10 == 0 then
			food = mcl_hunger.get_hunger(player)
			if food < 20 then
				mcl_hunger.set_hunger(player, food + 1, true)
			end
		end
	end
end

if mcl_hunger.active then
	-- Remove Mineclonia's food globalstep (mcl_hunger/init.lua, the
	-- mcl_player.register_globalstep using `food_tick_timers`).
	local line = find_line("mcl_hunger", "init.lua", "local food_tick_timers",
		"mcl_player.register_globalstep(function")
	local list = mcl_player and mcl_player.registered_globalsteps
	if line and list then
		jp.remove_callbacks(list, "mcl_hunger/init.lua", line)
	else
		warn("Mineclonia food globalstep not found; regeneration may run twice")
	end

	-- Fixed 20 Hz tick accumulator shared by all players.
	local acc = 0
	core.register_globalstep(function(dtime)
		acc = acc + dtime
		local n = 0
		while acc >= TICK - 1e-6 do
			acc = acc - TICK
			n = n + 1
			if n > 10 then -- server lag: drop the backlog instead of spiralling
				acc = 0
				break
			end
			for _, player in ipairs(core.get_connected_players()) do
				food_tick(player)
			end
		end
	end)

	core.register_on_respawnplayer(function(player)
		food_state[player] = nil
	end)
end

------------------------------------------------------------------------
-- 3. Damage exhaustion (DamageSource.getFoodExhaustion)
------------------------------------------------------------------------

-- Java damage types with exhaustion 0.0 (all others: 0.1), mapped to
-- Mineclonia damage type names (from data/minecraft/damage_type/*.json).
local NO_EXHAUSTION = {
	cramming = true, dragon_breath = true, drown = true, ender_pearl = true,
	fall = true, fly_into_wall = true, freeze = true, generic = true,
	generic_kill = true, in_wall = true, indirect_magic = true, magic = true,
	on_fire = true, out_of_world = true, outside_border = true,
	sonic_boom = true, stalagmite = true, starve = true, wither = true,
}

function jp.damage_food_exhaustion(reason)
	local t = reason and reason.type
	if t and NO_EXHAUSTION[t] then return 0 end
	return 0.1
end

if mcl_hunger.active then
	-- Mineclonia exhausted 0.1 on every engine HP decrease (any type,
	-- including starvation and fractional damage that happened to cross an
	-- integer).
	jp.remove_callbacks(core.registered_on_player_hpchanges.loggers, "mcl_hunger/init.lua")

	-- Java applies the exhaustion in actuallyHurt when the damage left
	-- after absorption is non-zero (before the totem check).  Absorption
	-- runs at priority 300 and the totem at 1000, so 900 sees the final
	-- amount.  mcl_damage.run_modifiers stops at 0, so fully absorbed or
	-- blocked hits never reach this.
	mcl_damage.register_modifier(function(obj, damage, reason)
		if damage > 0 and obj:is_player() then
			local e = jp.damage_food_exhaustion(reason)
			if e > 0 then
				mcl_hunger.exhaust(obj:get_player_name(), e * EXHAUST_SCALE)
			end
		end
		return damage
	end, 900)
end

------------------------------------------------------------------------
-- 4. Eating (FoodData.eat order, saturation cap) + item cooldowns
------------------------------------------------------------------------

-- Replaces mcl_hunger's core.do_item_eat (PLAYER/mcl_hunger/hunger.lua).
-- Identical except:
--   * food is added before saturation, and saturation is capped at the
--     post-meal food level (Java FoodData.add);
--   * food is applied before the item's effects (Java eat -> addEatEffect);
--   * items on cooldown (chorus fruit) cannot be eaten.
function core.do_item_eat(hunger_points, replace_with_item, itemstack, user, pointed_thing)
	if not user or not user.is_player or not user:is_player() or user.is_fake_player then
		return itemstack
	end

	local rc = mcl_util.call_on_rightclick(itemstack, user, pointed_thing)
	if rc then
		return rc
	end

	local itemname = itemstack:get_name()
	if jp.item_cooldown(user, itemname) > 0 then
		return itemstack
	end
	local playername = user:get_player_name()
	local creative = core.is_creative_enabled(playername)
	local def = core.registered_items[itemname]

	local old_itemstack = itemstack

	if mcl_hunger.active and hunger_points then
		jp.food_eat(user, hunger_points, def and def._mcl_saturation or 0)
	elseif not mcl_hunger.active and hunger_points then
		mcl_damage.heal_player(user, hunger_points)
	end

	if def and def._mcl_eat_effect then
		def._mcl_eat_effect(itemstack, user)
	end

	if not creative then
		itemstack:take_item()
		local nstack = ItemStack(replace_with_item)
		local inv = user:get_inventory()
		if itemstack:is_empty() then
			itemstack:add_item(replace_with_item)
		elseif inv:room_for_item("main", nstack) then
			inv:add_item("main", nstack)
		else
			core.add_item(user:get_pos(), nstack)
		end
	end

	for _, callback in pairs(core.registered_on_item_eats) do
		local result = callback(hunger_points, replace_with_item, itemstack, user, pointed_thing, old_itemstack)
		if result then
			return result
		end
	end

	return itemstack
end

-- Item cooldown also blocks *starting* to eat (Java: an item on cooldown
-- cannot be used).  Wrap the hold-to-eat controls callback of holdeat.lua.
if controls and controls.registered_on_hold
		and not core.settings:get_bool("mcl_hunger_instant_eat", false) then
	jp.wrap_callbacks(controls.registered_on_hold, "mcl_hunger/holdeat.lua",
		function(original, player, key)
			if key == "RMB" and player and player:is_player() then
				local name = player:get_wielded_item():get_name()
				if name ~= "" and jp.item_cooldown(player, name) > 0 then
					return
				end
			end
			return original(player, key)
		end)
end

------------------------------------------------------------------------
-- 5/6. Food values, eating durations and food effects
------------------------------------------------------------------------

local function override(name, fields)
	if not core.registered_items[name] then
		return false
	end
	core.override_item(name, fields)
	return true
end

local function set_group(name, group, value)
	local def = core.registered_items[name]
	if not def then return false end
	local groups = table.copy(def.groups or {})
	groups[group] = value
	core.override_item(name, { groups = groups })
	return true
end

-- Sweet berries: Java 2 food / 0.4 saturation (Mineclonia 1).
set_group("mcl_farming:sweet_berry", "eatable", 2)
-- Glow berries: Java 2 food / 0.4 saturation (Mineclonia 1.2).
override("mcl_lush_caves:glow_berry", { _mcl_saturation = 0.4 })

-- Pufferfish: Java Poison II 60 s, Hunger III 15 s, Nausea I 15 s
-- (Mineclonia: Poison III, Nausea II).
override("mcl_fishing:pufferfish_raw", {
	_mcl_eat_effect = function(_, placer)
		mcl_potions.give_effect_by_level("hunger", placer, 3, 15)
		mcl_potions.give_effect_by_level("poison", placer, 2, 60)
		mcl_potions.give_effect_by_level("nausea", placer, 1, 15)
	end,
})

-- Honey bottle: cures Poison (Java HoneyBottleItem.finishUsingItem).
do
	local def = core.registered_items["mcl_honey:honey_bottle"]
	if def then
		local old_effect = def._mcl_eat_effect
		override("mcl_honey:honey_bottle", {
			_mcl_eat_delay = 2.0, -- 40 ticks (adjusted to the tick grid below)
			_mcl_eat_effect = function(itemstack, user)
				if old_effect then old_effect(itemstack, user) end
				if mcl_potions.has_effect(user, "poison") then
					mcl_potions.clear_effect(user, "poison")
				end
			end,
		})
	end
end

-- Eating durations on the 20 Hz grid.  holdeat.lua finishes when the hold
-- time *before* the current step is >= _mcl_eat_delay, so a delay of
-- N ticks - epsilon finishes exactly N ticks after starting (Java: 32 ticks
-- for food and potions, 40 for honey, 16 for dried kelp).  Mineclonia's
-- default 1.61 s took 34 steps.
core.register_on_mods_loaded(function()
	for name, def in pairs(core.registered_items) do
		if (def.groups and (def.groups.food or 0) > 0) then
			local delay = def._mcl_eat_delay or 1.6
			local ticks = math.max(1, math.floor(delay / TICK + 0.5))
			local new = ticks * TICK - 0.001
			if math.abs(new - delay) > 1e-9 then
				core.override_item(name, { _mcl_eat_delay = new })
			end
		end
	end
end)

------------------------------------------------------------------------
-- 8. Suspicious stew effect durations (Java 1.21.4+)
------------------------------------------------------------------------

-- The duration is the same for every flower giving a given effect, so it
-- can be keyed by effect.  Effects are applied at level I (Mineclonia passed
-- factor 1, which is level II/III for Regeneration, Leaping, Nausea and
-- Wither and no effect at all for Weakness).
local STEW_DURATIONS = {
	night_vision = 5,      -- Poppy, Torchflower
	saturation = 0.35,     -- Dandelion, Blue Orchid (7 ticks)
	regeneration = 7,      -- Oxeye Daisy
	weakness = 7,          -- Tulips
	fire_resistance = 3,   -- Allium
	blindness = 11,        -- Azure Bluet, Open Eyeblossom
	withering = 7,         -- Wither Rose
	poison = 11,           -- Lily of the Valley
	leaping = 5,           -- Cornflower
	nausea = 7,            -- Closed Eyeblossom
}

if core.registered_items["mcl_sus_stew:stew"] then
	local old_effect = core.registered_items["mcl_sus_stew:stew"]._mcl_eat_effect
	override("mcl_sus_stew:stew", {
		_mcl_eat_effect = function(itemstack, placer, pointed_thing)
			local effect = itemstack:get_meta():get_string("effect")
			if effect == "jump" then effect = "leaping" end
			local dur = STEW_DURATIONS[effect]
			if dur and mcl_potions.registered_effects[effect] then
				mcl_potions.give_effect_by_level(effect, placer, 1, dur)
			elseif old_effect then
				-- Unknown (e.g. modded) ingredient: keep Mineclonia's behaviour.
				return old_effect(itemstack, placer, pointed_thing)
			end
		end,
	})
end

------------------------------------------------------------------------
-- 7. Chorus fruit (ChorusFruitItem.finishUsingItem / Entity.randomTeleport)
------------------------------------------------------------------------

local CHORUS = "mcl_end:chorus_fruit"
local CHORUS_COOLDOWN = 20 * TICK

local function dimension_limits(pos)
	local dim = mcl_worlds and mcl_worlds.pos_to_dimension(pos) or "overworld"
	local v = mcl_vars or {}
	if dim == "nether" then
		return dim, v.mg_nether_min or -29067, v.mg_nether_max or -28939
	elseif dim == "end" then
		return dim, v.mg_end_min or -27073, v.mg_end_max or -2062
	end
	return dim, v.mg_overworld_min or -128, v.mg_overworld_max or 31000
end

local function node_def(pos)
	local node = core.get_node(pos)
	if node.name == "ignore" then return nil, node end
	return core.registered_nodes[node.name] or {}, node
end

local function blocks_motion(def, node)
	return def.walkable ~= false and node.name ~= "air"
end

-- Java: level.noCollision(entity) && !level.containsAnyLiquid(box) at the
-- candidate position.  Node shapes are approximated by full blocks.
local function box_free(pos, cb)
	local eps = 1e-4
	for x = math.floor(pos.x + cb[1] + eps), math.floor(pos.x + cb[4] - eps) do
	for y = math.floor(pos.y + cb[2] + eps), math.floor(pos.y + cb[5] - eps) do
	for z = math.floor(pos.z + cb[3] + eps), math.floor(pos.z + cb[6] - eps) do
		local def, node = node_def({ x = x, y = y, z = z })
		if not def then return false end -- unloaded
		if blocks_motion(def, node) then return false end
		if def.liquidtype and def.liquidtype ~= "none" then return false end
	end
	end
	end
	return true
end

-- Entity.randomTeleport(x, y, z): move down until the block below blocks
-- motion (keeping the fractional y), then accept if the box is free.
local function try_teleport(player, x, y, z, min_y)
	local bx, bz = math.floor(x), math.floor(z)
	local by = math.floor(y)
	local def0 = node_def({ x = bx, y = by, z = bz })
	if not def0 then return false end -- chunk not loaded
	local found = false
	local guard = 0
	while not found and by > min_y and guard < 1024 do
		guard = guard + 1
		local def, node = node_def({ x = bx, y = by - 1, z = bz })
		if not def or node.name == "mcl_core:void" then return false end
		if blocks_motion(def, node) then
			found = true
		else
			y = y - 1
			by = by - 1
		end
	end
	if not found then return false end
	local goal = vector.new(x, y, z)
	local cb = player:get_properties().collisionbox or { -0.3, 0, -0.3, 0.3, 1.8, 0.3 }
	if not box_free(goal, cb) then return false end
	player:set_pos(goal)
	return true
end

local function chorus_teleport(player)
	local pos = player:get_pos()
	if not pos then return false end
	local _, min_y, max_y = dimension_limits(pos)
	for _ = 1, 16 do
		local x = pos.x + (math.random() - 0.5) * 16
		local y = jp.clamp(pos.y + math.random(0, 15) - 8, min_y, max_y - 1)
		local z = pos.z + (math.random() - 0.5) * 16
		-- Java: entity.stopRiding() before each attempt.
		if player:get_attach() and mcl_util.detach_object then
			mcl_util.detach_object(player)
		end
		if try_teleport(player, x, y, z, min_y) then
			core.sound_play({ name = "mcl_end_teleport", gain = 0.7 },
				{ object = player, max_hear_distance = 16 }, true)
			if jp.reset_fall then jp.reset_fall(player) end
			return true
		end
	end
	return false
end
jp.chorus_teleport = chorus_teleport

if core.registered_items[CHORUS] then
	override(CHORUS, {
		_mcl_eat_effect = function(_, player)
			if not player or not player:is_player() then return end
			chorus_teleport(player)
			-- Cooldown applies whether or not the teleport succeeded.
			jp.set_item_cooldown(player, CHORUS, CHORUS_COOLDOWN)
		end,
	})
end

------------------------------------------------------------------------
-- 9. Death XP drop (Player.getBaseExperienceReward)
------------------------------------------------------------------------

if mcl_experience and mcl_experience.throw_xp then
	local n = jp.remove_callbacks(core.registered_on_dieplayers, "mcl_experience/init.lua")
	if n > 0 then
		core.register_on_dieplayer(function(player)
			if mcl_vars.keep_inventory then return end
			local ok, level = pcall(mcl_experience.get_level, player)
			level = ok and tonumber(level) or 0
			-- Java drops min(7 * level, 100) points; the rest is lost.
			local drop = math.min(7 * math.floor(level), 100)
			if drop > 0 then
				mcl_experience.throw_xp(player:get_pos(), drop)
			end
			mcl_experience.set_xp(player, 0)
		end)
	end
end
