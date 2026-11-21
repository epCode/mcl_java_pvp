-- Melee PvP (Java 1.21 Player.attack).
--
-- Player-vs-player hits no longer use the engine's damage formula (linear
-- punch-interval scaling, truncated to integers).  Instead every hit by a
-- player on a player runs jp.player_attack:
--
--   damage   = attack_damage (+3 Strength / -4 Weakness per level)
--              * (0.2 + 0.8 c^2)          c = attack cooldown progress
--   enchant  = Sharpness (0.5 * level + 0.5) * c
--   mace     = + smash bonus (fall distance based, unscaled)
--   crit     = damage * 1.5   (c > 0.9, falling, not on ground/ladder/in
--              water/blind/riding/sprinting)
--   knockback: 0.4 base on a fresh hit, + 0.5 * (Knockback level + 1 if a
--              sprint hit with c > 0.9) along the attacker's facing; a
--              sprint hit slows the attacker to 60% and drops the sprint
--   sweep    : sword, c > 0.9, on ground, not crit/sprint, slow: hits
--              entities near the target for 1 + ratio * damage
--   cooldown : reset by attacking, switching items or swinging at air;
--              T = 20 / attack_speed ticks, Haste +10%, Mining Fatigue -10%
--   reach    : 3 blocks (creative 5)
--
-- Mineclonia's PvP-specific on_punchplayer callbacks (damage, Fire Aspect,
-- knockback, attack exhaustion) are skipped for player attackers.

local jp = mcl_java_pvp
local S = core.get_translator(jp.modname)

local function is_pvp(victim, hitter)
	return hitter and hitter:is_valid() and hitter:is_player() and victim:is_player()
		and hitter ~= victim
end

-- Skip Mineclonia's own handling of player-on-player punches.
local function skip_pvp(original, player, hitter, ...)
	if is_pvp(player, hitter) then return end
	return original(player, hitter, ...)
end
jp.wrap_callbacks(core.registered_on_punchplayers, "mcl_damage/init.lua", skip_pvp)
jp.wrap_callbacks(core.registered_on_punchplayers, "mcl_enchanting/enchantments.lua", skip_pvp)
jp.wrap_callbacks(core.registered_on_punchplayers, "mcl_player/init.lua", skip_pvp)
jp.wrap_callbacks(core.registered_on_punchplayers, "mcl_hunger/init.lua", skip_pvp)

------------------------------------------------------------------------
-- Sweeping Edge (missing in Mineclonia)
------------------------------------------------------------------------

if not mcl_enchanting.enchantments.sweeping_edge then
	mcl_enchanting.register_enchantment("sweeping_edge", {
		name = S("Sweeping Edge"),
		max_level = 3,
		primary = { sword = true },
		secondary = {},
		disallow = {},
		incompatible = {},
		weight = 2,
		description = S("Increases sweeping attack damage."),
		curse = false,
		on_enchant = function() end,
		requires_tool = false,
		treasure = false,
		power_range_table = { { 5, 20 }, { 14, 29 }, { 23, 38 } },
		inv_combat_tab = true,
		inv_tool_tab = false,
		anvil_item_factor = 4,
		anvil_book_factor = 2,
	})
end

------------------------------------------------------------------------
-- Attack cooldown
------------------------------------------------------------------------

local cooldown = jp.player_table() -- player -> {reset = time, item = name}

local function reset_cooldown(player)
	local c = cooldown[player]
	if not c then
		c = {}
		cooldown[player] = c
	end
	c.reset = jp.now()
end

local function attack_speed(player, stack)
	local _, speed = jp.weapon_stats(stack)
	local haste = jp.effect_level(player, "haste")
	local fatigue = jp.effect_level(player, "fatigue")
	speed = speed * (1 + 0.1 * haste) * math.max(0, 1 - 0.1 * fatigue)
	return math.max(speed, 0.01)
end

-- Java getAttackStrengthScale(0.5): clamp((ticks + 0.5) / (20 / speed)).
function jp.attack_strength(player)
	local c = cooldown[player]
	if not c or not c.reset then return 1 end
	local ticks = (jp.now() - c.reset) / jp.TICK
	local delay = 20 / attack_speed(player, player:get_wielded_item())
	return jp.clamp((ticks + 0.5) / delay, 0, 1)
end

core.register_on_joinplayer(function(player)
	cooldown[player] = { reset = jp.now(), item = player:get_wielded_item():get_name() }
end)

core.register_on_dignode(function(_, _, digger)
	if digger and digger:is_player() then
		reset_cooldown(digger)
	end
end)

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function fall_flying(player)
	local pdata = mcl_player.players[player]
	return pdata and pdata.elytra and pdata.elytra.active or false
end

local function in_water(player)
	local st = jp.state[player]
	return st and st.in_water or false
end

local function sharpness_bonus(stack)
	local level = mcl_enchanting.get_enchantment(stack, "sharpness")
	if level > 0 then
		return 0.5 * level + 0.5
	end
	return 0
end

-- Mace smash bonus for a fall distance (Java MaceItem.getAttackDamageBonus).
function jp.mace_bonus(fall, density_level)
	local bonus
	if fall <= 3 then
		bonus = 4 * fall
	elseif fall <= 8 then
		bonus = 12 + 2 * (fall - 3)
	else
		bonus = 22 + (fall - 8)
	end
	return bonus + 0.5 * (density_level or 0) * fall
end

local function crit_particles(pos, magic)
	core.add_particlespawner({
		amount = 15,
		time = 0.1,
		minpos = vector.offset(pos, -0.5, -0.5, -0.5),
		maxpos = vector.offset(pos, 0.5, 0.5, 0.5),
		minvel = vector.new(-0.1, -0.1, -0.1),
		maxvel = vector.new(0.1, 0.1, 0.1),
		minexptime = 1,
		maxexptime = 2,
		minsize = 1.5,
		maxsize = 1.5,
		collisiondetection = false,
		vertical = false,
		texture = magic and "mcl_particles_crit.png^[colorize:#5ac8ff:160"
			or "mcl_particles_crit.png^[colorize:#bc7a57:127",
	})
end

local function sweep_particles(pos, yaw)
	local fx, fz = -math.sin(yaw), math.cos(yaw)
	local p = vector.offset(pos, fx, 1.0, fz)
	core.add_particlespawner({
		amount = 8,
		time = 0.05,
		minpos = vector.offset(p, -0.6, -0.1, -0.6),
		maxpos = vector.offset(p, 0.6, 0.1, 0.6),
		minvel = vector.new(-0.3, 0, -0.3),
		maxvel = vector.new(0.3, 0, 0.3),
		minexptime = 0.2,
		maxexptime = 0.4,
		minsize = 3,
		maxsize = 4,
		texture = "mcl_particles_crit.png^[colorize:#ffffff:200",
	})
end

-- Deal damage through the mcl_damage chain and report the Java hurt()
-- outcome: applied (hurt returned true) and fresh (base knockback).
local function hurt(victim, amount, reason)
	if amount <= 0 then return false, false end
	if victim:is_player() then
		mcl_damage.damage_player(victim, amount, reason)
		local lh = jp.last_hurt[victim]
		if reason.jp_blocked or not lh then return false, false end
		return lh.applied, lh.fresh
	end
	local before = mcl_util.get_hp(victim)
	mcl_util.deal_damage(victim, amount, reason)
	local after = victim:is_valid() and mcl_util.get_hp(victim) or 0
	return (after or 0) < (before or 0), true
end

local function knockback_any(obj, strength, dx, dz)
	if obj:is_player() then
		jp.knockback(obj, strength, dx, dz)
	else
		local len = math.sqrt(dx * dx + dz * dz)
		if len < 1e-6 then return end
		local ent = obj:get_luaentity()
		local kbr = ent and ent.knockback_resistance or 0
		strength = strength * (1 - math.min(1, kbr))
		obj:add_velocity(vector.new(-dx / len * strength * 20, strength * 10, -dz / len * strength * 20))
	end
end

local function push_any(obj, x, y, z)
	if obj:is_player() then
		jp.push(obj, x, y, z)
	else
		obj:add_velocity(vector.new(x * 20, y * 20, z * 20))
	end
end

local function play(name, pos, gain, pitch)
	core.sound_play(name, { pos = pos, gain = gain or 1, pitch = pitch or 1, max_hear_distance = 16 }, true)
end

------------------------------------------------------------------------
-- Mace post-hit effects (smash): attacker bounce, AoE knockback, Wind Burst
------------------------------------------------------------------------

local function mace_smash_effects(attacker, target, stack, fall)
	-- Attacker: vertical velocity set to 0.01 b/t, fall distance reset.
	local v = attacker:get_velocity()
	attacker:add_velocity(vector.new(0, 0.2 - v.y, 0))
	if jp.reset_fall then jp.reset_fall(attacker) end

	-- Knock back living entities near the target.
	local tpos = target:get_pos()
	local mult = fall > 5 and 2 or 1
	for obj in core.objects_inside_radius(tpos, 3.5) do
		if obj ~= attacker and obj ~= target and jp.is_living(obj) then
			local d = vector.subtract(obj:get_pos(), tpos)
			local len = vector.length(d)
			local power = (3.5 - len) * 0.7 * mult * (1 - jp.knockback_resistance(obj))
			if power > 0 and len > 1e-6 then
				push_any(obj, d.x / len * power, 0.7, d.z / len * power)
			end
		end
	end
	play("tnt_explode", tpos, 0.3, 0.6)

	-- Wind Burst: wind explosion at the attacker launching them upwards.
	local wind = mcl_enchanting.get_enchantment(stack, "wind_burst")
	if wind > 0 then
		local kb = ({ 1.2, 1.75, 2.2 })[wind] or (1.5 + 0.35 * (wind - 1))
		jp.push(attacker, 0, kb, 0)
		local apos = attacker:get_pos()
		play("tnt_explode", apos, 0.4, 2.5)
		if mcl_charges and mcl_charges.wind_burst_spawner then
			core.add_particlespawner(table.merge(mcl_charges.wind_burst_spawner, {
				minpos = vector.offset(apos, -0.8, 0.6, -0.8),
				maxpos = vector.offset(apos, 0.8, 0.8, 0.8),
			}))
		end
	end
end

------------------------------------------------------------------------
-- The attack
------------------------------------------------------------------------

local pvp_enabled = core.settings:get_bool("enable_pvp", true)

function jp.player_attack(attacker, victim)
	if not pvp_enabled then return end
	if victim:get_hp() <= 0 or attacker:get_hp() <= 0 then return end
	local st = jp.player_state(attacker)
	-- Can't attack while using an item (eating, drawing a bow, blocking).
	if st.using_item then return end

	-- Reach: 3 blocks (5 in creative) from the eyes to the target's hitbox.
	local reach = jp.is_creative(attacker) and jp.ENTITY_REACH_CREATIVE or jp.ENTITY_REACH
	if jp.dist_to_box(jp.eye_pos(attacker), jp.object_box(victim)) > reach + jp.REACH_TOLERANCE then
		return
	end

	local stack = attacker:get_wielded_item()
	local base, _, kind = jp.weapon_stats(stack)
	base = base + 3 * jp.effect_level(attacker, "strength") - 4 * jp.effect_level(attacker, "weakness")
	base = math.max(0, base)
	local enchant = sharpness_bonus(stack)
	local c = jp.attack_strength(attacker)
	base = base * (0.2 + c * c * 0.8)
	enchant = enchant * c
	reset_cooldown(attacker)
	if base <= 0 and enchant <= 0 then return end

	local strong = c > 0.9
	local sprinting = jp.is_sprinting(attacker)
	local sprint_hit = sprinting and strong
	local apos = attacker:get_pos()
	local vpos = victim:get_pos()
	local yaw = attacker:get_look_horizontal()
	-- Direction "towards the source" for a push along the attacker's facing.
	local fdx, fdz = math.sin(yaw), -math.cos(yaw)

	-- Mace smash.
	local fall = st.fall_distance or 0
	local smash = kind == "mace" and fall > 1.5 and not fall_flying(attacker)
	if smash then
		base = base + jp.mace_bonus(fall, mcl_enchanting.get_enchantment(stack, "density"))
	end

	local crit = strong and fall > 0 and not st.on_ground and not st.climbing
		and not in_water(attacker) and not mcl_potions.has_effect(attacker, "blindness")
		and not attacker:get_attach() and not sprinting
	if crit then
		base = base * 1.5
	end
	local total = base + enchant

	local vel = attacker:get_velocity()
	local hspeed = math.sqrt(vel.x * vel.x + vel.z * vel.z)
	-- Java: walkDist delta (0.6 x distance per tick) < movement speed (0.1).
	local sweep = strong and not crit and not sprint_hit and st.on_ground
		and kind == "sword" and hspeed * jp.TICK * 0.6 < 0.1

	local reason = {
		type = "player",
		direct = attacker,
		source = attacker,
		jp_weapon = stack,
	}
	mcl_damage.finish_reason(reason)

	if sprint_hit then
		play("mcl_criticals_hit", apos, 0.5, 0.8)
	end

	local applied, fresh = hurt(victim, total, reason)
	if not applied then
		return
	end

	-- Knockback: base 0.4 away from the attacker (fresh hits only), then
	-- the Knockback enchantment / sprint bonus along the attacker's facing.
	if fresh then
		jp.knockback(victim, 0.4, apos.x - vpos.x, apos.z - vpos.z)
	end
	local extra = mcl_enchanting.get_enchantment(stack, "knockback") + (sprint_hit and 1 or 0)
	if extra > 0 then
		jp.knockback(victim, extra * 0.5, fdx, fdz)
		attacker:add_velocity(vector.new(-0.4 * vel.x, 0, -0.4 * vel.z))
		if jp.stop_sprint then jp.stop_sprint(attacker, 0.1) end
	end

	local fire = mcl_enchanting.get_enchantment(stack, "fire_aspect")

	-- Sweep attack.
	if sweep then
		local ratio = 0
		local se = mcl_enchanting.get_enchantment(stack, "sweeping_edge")
		if se > 0 then ratio = se / (se + 1) end
		local sweep_damage = (1 + ratio * base + sharpness_bonus(stack)) * c
		local box = jp.object_box(victim)
		for obj in core.objects_inside_radius(vpos, 4) do
			if obj ~= attacker and obj ~= victim and obj:is_valid() and jp.is_living(obj)
					and vector.distance(obj:get_pos(), apos) < 3 then
				local ob = jp.object_box(obj)
				-- Target box inflated by (1, 0.25, 1) must intersect.
				if ob[1] <= box[4] + 1 and ob[4] >= box[1] - 1
						and ob[2] <= box[5] + 0.25 and ob[5] >= box[2] - 0.25
						and ob[3] <= box[6] + 1 and ob[6] >= box[3] - 1 then
					knockback_any(obj, 0.4, fdx, fdz)
					local r = { type = "player", direct = attacker, source = attacker, jp_weapon = stack }
					mcl_damage.finish_reason(r)
					local ok = hurt(obj, sweep_damage, r)
					if ok and fire > 0 then
						mcl_burning.set_on_fire(obj, fire * 4)
					end
				end
			end
		end
		sweep_particles(apos, yaw)
	end

	-- Effects, sounds, durability, exhaustion.
	local center = vector.offset(vpos, 0, 1, 0)
	if crit then
		crit_particles(center)
		play("mcl_criticals_hit", vpos)
	end
	if enchant > 0 then
		crit_particles(center, true)
	end
	if fire > 0 and victim:is_valid() then
		mcl_burning.set_on_fire(victim, fire * 4)
	end
	if smash and victim:is_valid() then
		mace_smash_effects(attacker, victim, stack, fall)
	end

	if not jp.is_creative(attacker) and kind and jp.ATTACK_DURABILITY[kind] then
		local def = stack:get_definition()
		mcl_util.use_item_durability(stack, jp.ATTACK_DURABILITY[kind])
		if stack:is_empty() and def and def.sound and def.sound.breaks then
			play(def.sound.breaks, apos, 0.5)
		end
		attacker:set_wielded_item(stack)
	end
	mcl_hunger.exhaust(attacker:get_player_name(), mcl_hunger.EXHAUST_ATTACK)
end

-- Player-vs-mob hits still use Mineclonia's mob combat; give them Java
-- critical hits (x1.5 under the Java conditions) in place of the removed
-- random mcl_criticals bonus.
mcl_damage.register_modifier(function(obj, damage, reason)
	if obj:is_player() or reason.type ~= "player" or reason.jp_weapon then return end
	local hitter = reason.direct
	if not (hitter and hitter:is_player() and hitter == reason.source) then return end
	local st = jp.player_state(hitter)
	if (st.fall_distance or 0) > 0 and not st.on_ground and not st.climbing
			and not st.in_water and not hitter:get_attach()
			and not mcl_potions.has_effect(hitter, "blindness")
			and not jp.is_sprinting(hitter) and damage > 0 then
		crit_particles(vector.offset(obj:get_pos(), 0, 0.5, 0))
		play("mcl_criticals_hit", obj:get_pos())
		return damage * 1.5
	end
end, -100)

core.register_on_punchplayer(function(player, hitter)
	if is_pvp(player, hitter) then
		jp.player_attack(hitter, player)
		return true
	end
end)

-- The mace's on_use replaced engine punches (and its own smash formula);
-- route player targets through the Java attack, keep it for mobs.
do
	local def = core.registered_items["mcl_tools:mace"]
	if def and def.on_use then
		local orig_on_use = def.on_use
		core.override_item("mcl_tools:mace", {
			on_use = function(itemstack, user, pointed_thing)
				if pointed_thing.type == "object" and pointed_thing.ref
						and is_pvp(pointed_thing.ref, user) then
					jp.player_attack(user, pointed_thing.ref)
					return user:get_wielded_item()
				end
				return orig_on_use(itemstack, user, pointed_thing)
			end,
		})
	end
end

------------------------------------------------------------------------
-- Knockback from non-player sources (mobs, arrows, tridents ...)
------------------------------------------------------------------------
-- Mineclonia: one push of 0.5 * (1 + Knockback) * 0.546 in m/s with half
-- the Java vertical, on every damaging punch, and for snowballs/eggs.
-- Java: 0.4 hurt knockback only on fresh (non-i-frame) hits, from the
-- source position (projectiles: along their motion), plus the mob's attack
-- knockback along its facing; nothing for snowballs/eggs or blocked hits.

local orig_player_knockback = mcl_player.player_knockback

function mcl_player.player_knockback(player, hitter, dir, tool_capabilities, damage)
	if not player:is_player() then
		return orig_player_knockback(player, hitter, dir, tool_capabilities, damage)
	end
	if tool_capabilities and tool_capabilities.damage_groups
			and (tool_capabilities.damage_groups.snowball_vulnerable
				or tool_capabilities.damage_groups.egg_vulnerable) then
		return
	end
	local lh = jp.last_hurt[player]
	if not lh or not lh.applied or jp.now() - lh.time > 0.05 then return end

	local ent = hitter and hitter:is_valid() and hitter:get_luaentity()
	local dx, dz
	if ent and (ent._is_arrow or ent.name == "mcl_tridents:trident") and dir then
		dx, dz = -dir.x, -dir.z
	elseif hitter and hitter:is_valid() then
		local hp, pp = hitter:get_pos(), player:get_pos()
		dx, dz = hp.x - pp.x, hp.z - pp.z
	elseif dir then
		dx, dz = -dir.x, -dir.z
	end
	if lh.fresh and dx then
		jp.knockback(player, 0.4, dx, dz)
	end

	-- Mob attack knockback (attack_knockback attribute + Knockback enchant).
	if ent and ent.is_mob then
		local extra = (mcl_util.get_additional_knockback(hitter) or 0)
			+ mcl_enchanting.get_enchantment(mcl_util.get_wielditem(hitter), "knockback")
		if extra > 0 then
			local yaw = hitter:get_yaw()
			jp.knockback(player, extra * 0.5, math.sin(yaw), -math.cos(yaw))
		end
	end
end

------------------------------------------------------------------------
-- Cooldown resets on item switch and air swings; cooldown indicator
------------------------------------------------------------------------

local indicator = jp.enabled("cooldown_indicator")
local huds = jp.player_table()
local INDICATOR_W = 32

local function update_indicator(player, strength)
	local h = huds[player]
	if not h then
		h = {
			bg = player:hud_add({
				type = "image",
				position = { x = 0.5, y = 0.5 },
				offset = { x = 0, y = 22 },
				text = "[fill:1x1:#00000000",
				scale = { x = INDICATOR_W, y = 4 },
				alignment = { x = 0, y = 0 },
				z_index = 100,
			}),
			fg = player:hud_add({
				type = "image",
				position = { x = 0.5, y = 0.5 },
				offset = { x = -INDICATOR_W / 2, y = 22 },
				text = "[fill:1x1:#00000000",
				scale = { x = 0, y = 4 },
				alignment = { x = 1, y = 0 },
				z_index = 101,
			}),
			shown = false,
		}
		huds[player] = h
	end
	local show = strength < 1
	if show then
		player:hud_change(h.bg, "text", "[fill:1x1:#40404099")
		player:hud_change(h.fg, "text", "[fill:1x1:#ffffffcc")
		player:hud_change(h.fg, "scale", { x = math.floor(INDICATOR_W * strength + 0.5), y = 4 })
		h.shown = true
	elseif h.shown then
		player:hud_change(h.bg, "text", "[fill:1x1:#00000000")
		player:hud_change(h.fg, "text", "[fill:1x1:#00000000")
		h.shown = false
	end
end

local miss_reset = jp.enabled("miss_resets_cooldown")
local prev_dig = jp.player_table()

local function swing_missed(player)
	local eye = jp.eye_pos(player)
	local dir = player:get_look_dir()
	local ray = core.raycast(eye, vector.add(eye, vector.multiply(dir, 4.5)), true, false)
	for pointed in ray do
		if pointed.type == "object" then
			if pointed.ref ~= player then return false end
		elseif pointed.type == "node" then
			return false
		end
	end
	return true
end

core.register_globalstep(function()
	for player in mcl_util.connected_players() do
		local c = cooldown[player]
		if not c then
			cooldown[player] = { reset = jp.now(), item = player:get_wielded_item():get_name() }
			c = cooldown[player]
		end
		-- Java resets the attack timer when the main-hand item type changes.
		local name = player:get_wielded_item():get_name()
		if name ~= c.item then
			c.item = name
			c.reset = jp.now()
		end
		-- Swinging at nothing resets the timer too.
		local dig = player:get_player_control().dig
		if miss_reset and dig and not prev_dig[player] and swing_missed(player) then
			c.reset = jp.now()
		end
		prev_dig[player] = dig
		if indicator then
			update_indicator(player, jp.attack_strength(player))
		end
	end
end)
