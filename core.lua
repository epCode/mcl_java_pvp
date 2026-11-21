-- Shared helpers for mcl_java_pvp.
--
-- Units: Java measures velocity in blocks/tick (b/t) and time in ticks
-- (20 per second).  Luanti uses nodes/second (m/s) and seconds.  1 b/t =
-- 20 m/s.  Luanti's client physics do not use Java's per-tick drag, so
-- velocities that must reproduce a Java *trajectory* (knockback, launches)
-- are converted with the trajectory-matching helpers below instead of a
-- plain *20.

local jp = mcl_java_pvp

jp.TICK = 0.05

------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------

local function setting_key(name)
	return "mcl_java_pvp_" .. name
end

-- Feature toggles (all default on).
function jp.enabled(feature)
	return core.settings:get_bool(setting_key(feature), true)
end

function jp.setting_number(name, default)
	return tonumber(core.settings:get(setting_key(name))) or default
end

------------------------------------------------------------------------
-- Function identification (used to find Mineclonia callbacks to replace)
------------------------------------------------------------------------

-- Returns the source path and first line of a Lua function.
function jp.func_origin(f)
	local info = debug.getinfo(f, "S")
	if not info then return "", -1 end
	return info.source or "", info.linedefined or -1
end

-- True if function f was defined in a file whose path ends with suffix
-- (e.g. "mcl_damage/init.lua") and, if line is given, on that line.
function jp.func_is(f, suffix, line)
	local src, linedefined = jp.func_origin(f)
	if src:sub(-#suffix) ~= suffix then return false end
	return line == nil or linedefined == line
end

-- Remove damage modifiers matching predicate(func, priority, src, line).
-- Returns the number removed.
function jp.remove_damage_modifiers(predicate, description)
	local removed = 0
	local mods = mcl_damage.modifiers
	for i = #mods, 1, -1 do
		local src, line = jp.func_origin(mods[i].func)
		if predicate(mods[i].func, mods[i].priority, src, line) then
			table.remove(mods, i)
			removed = removed + 1
		end
	end
	if removed == 0 then
		core.log("warning", "[mcl_java_pvp] Could not find Mineclonia damage modifier: "
			.. (description or "?"))
	end
	return removed
end

-- Remove the damage modifier defined in a given file (and optionally at a
-- given priority).
function jp.remove_modifier_from(suffix, priority, line)
	return jp.remove_damage_modifiers(function(f, prio)
		return jp.func_is(f, suffix, line) and (priority == nil or prio == priority)
	end, suffix .. (priority and (" prio " .. priority) or ""))
end

-- Wrap every function in list `list` (e.g. core.registered_on_punchplayers)
-- that was defined in file `suffix`.  wrapper(original, ...) replaces it.
function jp.wrap_callbacks(list, suffix, wrapper, line)
	local found = 0
	for i, f in ipairs(list) do
		if jp.func_is(f, suffix, line) then
			local original = f
			list[i] = function(...)
				return wrapper(original, ...)
			end
			found = found + 1
		end
	end
	if found == 0 then
		core.log("warning", "[mcl_java_pvp] Could not find callback in " .. suffix)
	end
	return found
end

-- Remove every callback in `list` defined in file `suffix`.
function jp.remove_callbacks(list, suffix, line)
	local found = 0
	for i = #list, 1, -1 do
		if jp.func_is(list[i], suffix, line) then
			table.remove(list, i)
			found = found + 1
		end
	end
	if found == 0 then
		core.log("warning", "[mcl_java_pvp] Could not find callback to remove in " .. suffix)
	end
	return found
end

------------------------------------------------------------------------
-- Generic helpers
------------------------------------------------------------------------

function jp.clamp(x, lo, hi)
	if x < lo then return lo end
	if x > hi then return hi end
	return x
end

function jp.now()
	return core.get_us_time() / 1e6
end

function jp.is_csm(player)
	return mcl_serverplayer.is_csm_capable(player) and true or false
end

function jp.is_creative(player)
	return player:is_player() and core.is_creative_enabled(player:get_player_name())
end

function jp.effect_level(obj, name)
	if not mcl_potions.has_effect(obj, name) then return 0 end
	return mcl_potions.get_effect_level(obj, name) or 0
end

-- Per-player tables that are cleared when the player leaves.
local per_player_tables = {}
function jp.player_table()
	local t = {}
	table.insert(per_player_tables, t)
	return t
end
core.register_on_leaveplayer(function(player)
	for _, t in ipairs(per_player_tables) do
		t[player] = nil
	end
end)

-- Number of netherite armor pieces worn => knockback resistance 0.1 each.
function jp.knockback_resistance(obj)
	if not obj:is_player() then
		local ent = obj:get_luaentity()
		return ent and ent.knockback_resistance or 0
	end
	local kbr = 0
	local inv = obj:get_inventory()
	for _, stack in ipairs(inv:get_list("armor") or {}) do
		if core.get_item_group(stack:get_name(), "armor_netherite") > 0 then
			kbr = kbr + 0.1
		end
	end
	return math.min(1, kbr)
end

------------------------------------------------------------------------
-- Engine physics for a player (effective SI values)
------------------------------------------------------------------------

local function setting_float(name, default)
	return tonumber(core.settings:get(name)) or default
end

-- Effective gravity, accelerations and speed factor the client currently
-- simulates for this player.
function jp.engine_physics(player)
	local o = player:get_physics_override()
	local g = 2 * setting_float("movement_gravity", 9.81) * (o.gravity or 1)
	local speed = o.speed or 1
	local a_ground = 10 * setting_float("movement_acceleration_default", 3) * (o.acceleration_default or 1) * speed
	local a_air = 10 * setting_float("movement_acceleration_air", 2) * (o.acceleration_air or 1) * speed
	return {
		g = math.max(g, 0.01),
		a_ground = math.max(a_ground, 0.01),
		a_air = math.max(a_air, 0.01),
	}
end

------------------------------------------------------------------------
-- Java trajectory simulation and conversion to Luanti
------------------------------------------------------------------------

-- Java player motion per tick: pos += v; v.y = (v.y - 0.08) * 0.98;
-- v.xz *= 0.91 in air, 0.546 on ground (slipperiness 0.6 * 0.91).
-- Returns apex height (blocks), air ticks, horizontal distance travelled
-- in the air and the horizontal speed on landing (b/t).
local function simulate_java(vh, vy)
	local y, h, t, apex = 0, 0, 0, 0
	repeat
		y = y + vy
		h = h + vh
		vy = (vy - 0.08) * 0.98
		vh = vh * 0.91
		t = t + 1
		if y > apex then apex = y end
	until y <= 0 or t > 200
	return apex, t, h, vh
end

local function java_ground_slide(vh)
	-- Geometric series of ground friction 0.546.
	return vh * 0.546 / (1 - 0.546)
end

-- Vertical launch: the Luanti velocity (m/s) that reaches the same apex as
-- a Java vertical velocity vy (b/t).  Negative velocities are passed
-- through unchanged.
function jp.java_vy_to_luanti(vy, player)
	if vy <= 0 then return vy * 20 end
	local phys = jp.engine_physics(player)
	local apex = simulate_java(0, vy)
	return math.sqrt(2 * phys.g * apex)
end

-- Convert a Java velocity set by knockback (horizontal speed vh and
-- vertical vy, both b/t) into Luanti m/s so that the victim travels the
-- same horizontal distance and reaches the same height.
function jp.java_knockback_to_luanti(vh, vy, player)
	local phys = jp.engine_physics(player)
	local apex, ticks, air_dist, land_vh = simulate_java(vh, vy)
	local dist = air_dist + java_ground_slide(land_vh)

	local vy_l, t_air
	if vy > 0 then
		vy_l = math.sqrt(2 * phys.g * apex)
		t_air = 2 * vy_l / phys.g
	else
		vy_l = vy * 20
		t_air = ticks * jp.TICK
	end

	-- Luanti: linear deceleration a_air while airborne, then a_ground.
	local a, ag, t = phys.a_air, phys.a_ground, t_air
	local vh_l
	if dist <= a * t * t / 2 then
		vh_l = math.sqrt(2 * a * dist)
	else
		-- u = landing speed; dist = u*t + a*t^2/2 + u^2/(2*ag)
		local c = dist - a * t * t / 2
		local u = ag * (-t + math.sqrt(t * t + 2 * c / ag))
		vh_l = u + a * t
	end
	return vh_l, vy_l
end

------------------------------------------------------------------------
-- Java knockback (LivingEntity.knockback)
------------------------------------------------------------------------
--
-- jp.knockback(victim, strength, dx, dz, opts)
--   strength: Java knockback strength (0.4 for a normal hurt, 0.5 per
--             level of Knockback/sprint, etc.)
--   dx, dz:   direction FROM THE VICTIM TOWARDS THE SOURCE (Java
--             convention: the victim is pushed the opposite way).
--   opts.ignore_resistance: skip netherite knockback resistance.
--
-- Several knockbacks applied to the same player in one server step
-- compound exactly like consecutive Java calls (each halves the previous
-- velocity), and are sent to the client once at the end of the step.

local pending_kb = {} -- player -> {vx, vy, vz (b/t), on_ground}
jp._pending_kb = pending_kb -- exposed for tests

function jp.on_ground(player)
	local st = jp.state and jp.state[player]
	if st then return st.on_ground end
	local v = player:get_velocity()
	return math.abs(v.y) < 0.2
end

function jp.knockback(victim, strength, dx, dz, opts)
	if not victim or not victim:is_valid() or not victim:is_player() then return end
	opts = opts or {}
	if not opts.ignore_resistance then
		strength = strength * (1 - jp.knockback_resistance(victim))
	end
	if strength <= 0 then return end
	local len = math.sqrt(dx * dx + dz * dz)
	if len < 1e-5 then return end
	local nx, nz = dx / len * strength, dz / len * strength

	local p = pending_kb[victim]
	if not p then
		local v = victim:get_velocity()
		p = { vx = v.x / 20, vy = v.y / 20, vz = v.z / 20, on_ground = jp.on_ground(victim) }
		if p.on_ground then
			-- Java players standing still have vy = -0.0784 (gravity tick).
			p.vy = -0.0784
		end
		pending_kb[victim] = p
	end
	p.vx = p.vx / 2 - nx
	p.vz = p.vz / 2 - nz
	if p.on_ground then
		p.vy = math.min(0.4, p.vy / 2 + strength)
	end
end

-- Push (Entity.push / add to velocity) in Java b/t, compounding with
-- pending knockback.
function jp.push(victim, x, y, z)
	if not victim or not victim:is_valid() or not victim:is_player() then return end
	local p = pending_kb[victim]
	if not p then
		local v = victim:get_velocity()
		p = { vx = v.x / 20, vy = v.y / 20, vz = v.z / 20, on_ground = jp.on_ground(victim) }
		pending_kb[victim] = p
	end
	p.vx, p.vy, p.vz = p.vx + x, p.vy + y, p.vz + z
	if y > 0 then p.on_ground = false end
end

-- Set the velocity of a player to a Java velocity (b/t) immediately.
function jp.set_java_velocity(player, vx, vy, vz)
	if jp.is_csm(player) then
		-- The Mineclonia CSM simulates Java physics; send directly.
		mcl_serverplayer.send_knockback(player, vector.new(vx * 20, vy * 20, vz * 20))
		return
	end
	local vh = math.sqrt(vx * vx + vz * vz)
	local vh_l, vy_l = jp.java_knockback_to_luanti(vh, vy, player)
	local scale = vh > 1e-6 and vh_l / vh or 0
	local target = vector.new(vx * scale, vy_l, vz * scale)
	local cur = player:get_velocity()
	player:add_velocity(vector.subtract(target, cur))
end

function jp.flush_knockback()
	for player, p in pairs(pending_kb) do
		if player:is_valid() then
			jp.set_java_velocity(player, p.vx, p.vy, p.vz)
		end
		pending_kb[player] = nil
	end
end

core.register_globalstep(function()
	jp.flush_knockback()
end)

------------------------------------------------------------------------
-- Item cooldowns (Java ItemCooldowns): ender pearls, chorus fruit,
-- wind charges, shields disabled by axes...
------------------------------------------------------------------------

local cooldowns = jp.player_table()

function jp.set_item_cooldown(player, key, seconds)
	cooldowns[player] = cooldowns[player] or {}
	cooldowns[player][key] = jp.now() + seconds
end

-- Remaining cooldown in seconds (0 if none).
function jp.item_cooldown(player, key)
	local c = cooldowns[player] and cooldowns[player][key]
	if not c then return 0 end
	local left = c - jp.now()
	if left <= 0 then
		cooldowns[player][key] = nil
		return 0
	end
	return left
end

------------------------------------------------------------------------
-- Living entity test
------------------------------------------------------------------------

function jp.is_living(obj)
	if obj:is_player() then return true end
	local ent = obj:get_luaentity()
	return ent and ent.is_mob and true or false
end

-- Axis aligned box of an object in world coordinates.
function jp.object_box(obj)
	local pos = obj:get_pos()
	local cb = obj:get_properties().collisionbox
	return {
		pos.x + cb[1], pos.y + cb[2], pos.z + cb[3],
		pos.x + cb[4], pos.y + cb[5], pos.z + cb[6],
	}
end

-- Distance from a point to the nearest point of a box.
function jp.dist_to_box(p, box)
	local dx = math.max(box[1] - p.x, 0, p.x - box[4])
	local dy = math.max(box[2] - p.y, 0, p.y - box[5])
	local dz = math.max(box[3] - p.z, 0, p.z - box[6])
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function jp.eye_pos(player)
	local pos = player:get_pos()
	pos.y = pos.y + player:get_properties().eye_height
	return pos
end
