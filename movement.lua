-- Movement and physics (Java 1.21) for the default (non-CSM) client.
--
--  * Jump/gravity: Java jumps 1.2522 blocks high and spends 12 ticks
--    (0.6 s) in the air.  Luanti has no air drag, so the constant-gravity
--    fit with the same apex and air time is g = 27.8 m/s^2, v = 8.35 m/s.
--    Mineclonia: g = 20.8, v = 6.6 -> 1.05 blocks, 0.63 s.
--  * Ground acceleration 36 m/s^2 (walk stops in 0.26 blocks, sprint in
--    0.34, like Java's 0.546 friction); air acceleration tuned so the
--    sprint-jump boost decays like Java (average ~7.1 m/s sprint-jumping).
--  * Sprint-jump boost: +0.2 b/t (4 m/s) in the facing direction.
--  * Hitbox 0.6 x 1.8 (sneak 1.5, swim/crawl/elytra 0.6), was 0.624 x 1.795.
--  * Using an item (eat, drink, bow, crossbow, shield, trident, spyglass)
--    multiplies movement by 0.2 (Mineclonia 0.3 / 0.5 / none), and the
--    player slows down to that speed at once (the engine scales its
--    acceleration by the speed factor, which made players coast on).
--  * Sprinting can't start while using an item or while blind.  A sprint
--    that was already running when the player started using an item is
--    kept for its sprint-jump boost ("eat while sprinting"), but the
--    sprint speed does not apply until the item is no longer in use.
--  * Blindness stops sprinting; melee.lua briefly drops sprint after a
--    sprint hit, and it resumes afterwards while the sprint key is held.
--  * Jump Boost: +0.1 b/t jump velocity per level (Mineclonia x1.5/x2.0).
--  * Slow Falling: gravity 0.01 b/t^2 while descending, terminal 0.49 b/t,
--    no fall damage (Mineclonia halved gravity also while rising).
--  * Fall damage: Java ceil(fall distance - 3 - Jump Boost) with block
--    multipliers (hay/honey x0.2, bed/shelf mushroom half distance, slime
--    none unless sneaking, pointed dripstone (d+2)*2).  The engine's
--    speed-based fall damage (none below ~5 blocks) is disabled.
--  * Water: walking ~2.2 m/s, sprint-swimming ~3.9 m/s, swimming up ~2.2
--    m/s, idle sinking ~0.5 m/s (Mineclonia 2.7 / 3.5 / 2.7 / 2.5).
--
-- Mineclonia builds with mcl_movement already drive the player physics
-- like Java (gravity, jump, ground/air acceleration with Java's friction
-- and air drag, sprint-jump boost, water, Slow Falling, Jump Boost).  With
-- it loaded, those are left to mcl_movement and the physics in this file
-- are not applied (they would stack on top of it); this file then only
-- adds hitboxes, the item-use and sprint rules, the Java fall damage
-- formula (on mcl_movement's fall tracking where it offers the hook) and
-- elytra damage.

local jp = mcl_java_pvp
local MOVEMENT = jp.has_mcl_movement and mcl_movement or nil

local ID = "mcl_java_pvp:base"
local ID_WATER = "mcl_java_pvp:water"
local ID_SLOWFALL = "mcl_java_pvp:slow_falling"
local ID_USE = "mcl_java_pvp:use_item"
local ID_USE_ACCEL = "mcl_java_pvp:use_accel"
local SPRINT_ID = "mcl_sprint:sprint"
local SPRINT_SPEED = mcl_sprint.SPEED or 1.3

local function sf(name, default)
	return tonumber(core.settings:get(name)) or default
end

-- Server movement settings (Mineclonia's minetest.conf defaults).
local S_GRAVITY = sf("movement_gravity", 10.4)
local S_JUMP = sf("movement_speed_jump", 6.6)
local S_ACCEL = sf("movement_acceleration_default", 2.4)
local S_ACCEL_AIR = sf("movement_acceleration_air", 1.2)
local S_SINK = sf("movement_liquid_sink", 23)
local S_FLUIDITY = sf("movement_liquid_fluidity", 1.13)

-- Targets (SI units).
local JAVA_G = 27.8         -- effective gravity, m/s^2
local JAVA_JUMP = 8.35      -- jump velocity, m/s
local GROUND_ACCEL = 36     -- m/s^2
local AIR_ACCEL = 6.3       -- m/s^2 (x1.3 while sprinting)
local WATER_WALK = 2.2      -- m/s
local WATER_SPRINT = 3.92   -- m/s
local WATER_SINK = 0.5      -- m/s
local SPRINT_JUMP_BOOST = 4 -- m/s (0.2 b/t)
local SLOWFALL_TERMINAL = 9.8

local F_GRAVITY = (JAVA_G / 2) / S_GRAVITY
local F_JUMP = JAVA_JUMP / S_JUMP
local F_ACCEL = (GROUND_ACCEL / 10) / S_ACCEL
local F_ACCEL_AIR = (AIR_ACCEL / 10) / S_ACCEL_AIR
-- Liquid drag in the engine: 10 / fluidity per m/s (viscosity 1 water).
local WATER_DRAG = 10 / S_FLUIDITY

jp.physics_enabled = jp.enabled("physics")
-- This file's own physics (fallback for Mineclonia without mcl_movement).
local own_physics = jp.physics_enabled and not MOVEMENT

------------------------------------------------------------------------
-- Hitboxes
------------------------------------------------------------------------

local function set_box(props, height, eye)
	if not props then return end
	props.collisionbox = { -0.3, 0, -0.3, 0.3, height, 0.3 }
	if eye then props.eye_height = eye end
end
set_box(mcl_player.player_props_normal, 1.8, 1.62)
set_box(mcl_player.player_props_sneaking, 1.5, 1.27)
set_box(mcl_player.player_props_swimming, 0.6, 0.4)
set_box(mcl_player.player_props_elytra, 0.6, 0.4)
if mcl_player.player_props_riding then
	mcl_player.player_props_riding.collisionbox = { -0.3, 0, -0.3, 0.3, 1.8, 0.3 }
end

------------------------------------------------------------------------
-- Physics factor remapping (wrap playerphysics)
------------------------------------------------------------------------

jp.state = jp.player_table()
local state = jp.state

local function st_of(player)
	local st = state[player]
	if not st then
		local pos = player:get_pos()
		st = {
			on_ground = true, was_on_ground = true, fall_start = pos.y,
			fall_distance = 0, last_pos = pos, sprint_active = false,
			sprint_suppress_until = 0, using_item = false,
		}
		state[player] = st
	end
	return st
end
jp.player_state = st_of

-- Item-use slowdown ids used by Mineclonia.
local USE_IDS = {
	["mcl_bows:use_bow"] = true,
	["mcl_bows:use_crossbow"] = true,
	["mcl_hunger:eat_anim"] = true,
	["shield_speed"] = true,
	[ID_USE] = true,
}
jp.USE_SPEED = 0.2
-- mcl_movement knows Mineclonia's item-use factors; tell it about the
-- trident/spyglass one too (no sprint start, scaled air control).
if MOVEMENT and MOVEMENT.register_item_use_factor then
	MOVEMENT.register_item_use_factor(ID_USE)
end

-- Java jump apex for a jump velocity in b/t.
local function java_apex(v)
	local y, apex = 0, 0
	for _ = 1, 100 do
		y = y + v
		v = (v - 0.08) * 0.98
		if y > apex then apex = y end
		if v <= 0 then break end
	end
	return apex
end
local BASE_APEX = java_apex(0.42)

-- Java can't start sprinting while blind or using an item; melee.lua also
-- drops the sprint for a moment after a sprint hit.
local function sprint_blocked(player, st)
	if mcl_potions.has_effect(player, "blindness") then return true end
	if jp.now() < st.sprint_suppress_until then return true end
	return st.using_item
end

-- Speed factor that mcl_sprint's sprint should have.  A sprint that was
-- running when the player started using an item stays active (it still
-- gives the sprint-jump boost), but the player moves at the item-use
-- speed: no sprint speed while an item is in use.
local function sprint_speed(st)
	if st.sprint_active and not st.using_item then
		return SPRINT_SPEED
	end
	return 1
end

local orig_add = playerphysics.add_physics_factor
local orig_remove = playerphysics.remove_physics_factor

-- st.sprint_factor is the value of mcl_sprint's speed factor, or nil
-- while mcl_sprint (or mcl_movement through it) has the player walking.
-- Called whenever the item use changes and every step: Java re-sprints
-- as soon as nothing blocks it while the sprint key is held.
local function update_sprint(player, st)
	if st.sprint_factor == nil or jp.is_csm(player) then return end
	if not st.sprint_active and not sprint_blocked(player, st) then
		st.sprint_active = true
	end
	local value = sprint_speed(st)
	if value ~= st.sprint_factor then
		st.sprint_factor = value
		orig_add(player, "speed", SPRINT_ID, value)
	end
end

function playerphysics.add_physics_factor(player, attribute, id, value)
	if player and player:is_player() then
		local st = st_of(player)
		if attribute == "speed" then
			if USE_IDS[id] then
				value = jp.USE_SPEED
				if id ~= ID_USE then
					st.use_ids = st.use_ids or {}
					st.use_ids[id] = true
					st.using_item = true
					update_sprint(player, st)
				end
			elseif id == SPRINT_ID then
				-- mcl_sprint starts a sprint.
				st.sprint_active = not sprint_blocked(player, st)
				value = sprint_speed(st)
				st.sprint_factor = value
			end
		elseif attribute == "fov" and id == SPRINT_ID then
			if sprint_blocked(player, st) then value = 1 end
		elseif attribute == "jump" and id == "mcl_potions:leaping" and own_physics then
			-- Mineclonia: 1 + 0.5 * level.  Java: +0.1 b/t per level.
			-- (mcl_movement builds already pass the Java factor.)
			local level = math.floor((value - 1) / 0.5 + 0.5)
			local v = 0.42 + 0.1 * level
			value = v > 0 and math.sqrt(java_apex(v) / BASE_APEX) or 0
		elseif attribute == "gravity" and id == "mcl_potions:slow_falling" and own_physics then
			-- Handled per step below (only while descending).
			value = 1
		end
	end
	return orig_add(player, attribute, id, value)
end

function playerphysics.remove_physics_factor(player, attribute, id)
	if player and player:is_player() then
		local st = st_of(player)
		if attribute == "speed" then
			if id == SPRINT_ID then
				st.sprint_active = false
				st.sprint_factor = nil
			elseif USE_IDS[id] and st.use_ids then
				st.use_ids[id] = nil
				st.using_item = next(st.use_ids) ~= nil
				update_sprint(player, st)
			end
		end
	end
	return orig_remove(player, attribute, id)
end

-- Is the player really sprinting (Mineclonia's state minus Java blocks)?
function jp.is_sprinting(player)
	if not mcl_sprint.is_sprinting(player:get_player_name()) then return false end
	if jp.is_csm(player) then return true end
	return st_of(player).sprint_active
end

-- Drop sprint for `seconds` (update_sprint re-applies it afterwards if the
-- sprint key is still held, like Java's client re-sprinting next tick).
function jp.stop_sprint(player, seconds)
	local st = st_of(player)
	st.sprint_suppress_until = jp.now() + (seconds or 0.1)
	if st.sprint_active then
		st.sprint_active = false
		if st.sprint_factor ~= nil and st.sprint_factor ~= 1 then
			st.sprint_factor = 1
			orig_add(player, "speed", SPRINT_ID, 1)
		end
	end
end

------------------------------------------------------------------------
-- Fall distance tracking and Java fall damage
------------------------------------------------------------------------

-- mcl_movement tracks falls from the client's position updates (skipping
-- stale ones, with teleport, bounce and liquid handling) and lets mods
-- replace its damage formula.  When it can, fall distance comes from it
-- and only the Java formula below is this file's; otherwise this file
-- tracks falls itself.
local MOVEMENT_FALLS = MOVEMENT and MOVEMENT.deal_fall_damage
	and MOVEMENT.get_fall_distance and MOVEMENT.reset_fall_distance and true or false

function jp.reset_fall(player, y)
	local st = st_of(player)
	st.fall_start = y or player:get_pos().y
	st.fall_distance = 0
	if MOVEMENT and MOVEMENT.reset_fall_distance then
		MOVEMENT.reset_fall_distance(player)
	end
end

local function node_at(x, y, z)
	return core.get_node(vector.new(x, y, z))
end

local function ndef(node)
	return core.registered_nodes[node.name]
end

-- Nodes under the player's feet (4 hitbox corners + centre).
local CORNERS = { { 0, 0 }, { -0.29, -0.29 }, { 0.29, -0.29 }, { -0.29, 0.29 }, { 0.29, 0.29 } }

local function ground_nodes(pos)
	local list = {}
	for _, c in ipairs(CORNERS) do
		local n = node_at(pos.x + c[1], pos.y - 0.1, pos.z + c[2])
		local d = ndef(n)
		if d and d.walkable ~= false then
			table.insert(list, n)
		end
	end
	return list
end

local function resets_fall(name)
	local d = core.registered_nodes[name]
	if not d then return false end
	if d.climbable then return true end
	local g = d.groups or {}
	if (g.water or 0) > 0 then return true end
	if name == "mcl_core:cobweb" or name == "mcl_powder_snow:powder_snow" then return true end
	if name:find("^mcl_farming:sweet_berry_bush") then return true end
	return false
end

local function in_resetting_node(pos)
	return resets_fall(node_at(pos.x, pos.y + 0.1, pos.z).name)
		or resets_fall(node_at(pos.x, pos.y + 0.9, pos.z).name)
end

-- Java fall damage (LivingEntity.causeFallDamage and the Block.fallOn
-- overrides) for falling `dist` nodes onto node `name` (nil: unknown).
-- Java takes the block under the middle of the player, like
-- ground_nodes(pos)[1] and mcl_movement's supporting node.
function jp.fall_damage(player, dist, name, sneak)
	if dist <= 0 or jp.is_creative(player) or player:get_hp() <= 0 then return end
	local mult = 1
	local pct = name and core.get_item_group(name, "fall_damage_add_percent") or 0
	if pct == -100 then
		-- Slime block: no damage unless sneaking (no bounce).
		if not sneak then return end
	elseif pct == -50 then
		-- Beds: half the fall distance.
		dist = dist * 0.5
	elseif pct > 0 then
		-- Pointed dripstone, tip up.
		dist = dist + 2
		mult = 2
	elseif pct ~= 0 then
		-- Hay bale, honey block: x0.2.
		mult = 1 + pct / 100
	end
	local safe = 3 + jp.effect_level(player, "leaping")
	local damage = math.ceil((dist - safe) * mult - 1e-6)
	if damage > 0 then
		mcl_util.deal_damage(player, damage, { type = "fall" })
	end
end

local function fall_damage(player, st, pos, ctrl, ground_y, nodes)
	nodes = nodes or ground_nodes(pos)
	local n = nodes[1]
	jp.fall_damage(player, st.fall_start - (ground_y or pos.y), n and n.name, ctrl.sneak)
end

-- The low point between two position updates on which the player went
-- from falling to rising: a bounce off a slime block or bed, or a jump
-- straight after landing with the jump key held.  The server may see
-- neither on the ground.  Returns the ground height and the nodes there.
local function missed_landing(st, pos, vel, ctrl)
	local lv = st.last_vel
	if not (lv and st.last_pos) or lv.y >= -1 or vel.y <= 1 then return end
	local low = math.min(pos.y, st.last_pos.y)
	for _, dy in ipairs({ 0, 0.5, 1, 1.5 }) do
		local nodes = ground_nodes(vector.new(pos.x, low - dy, pos.z))
		local n = nodes[1]
		if n and (ctrl.jump or core.get_item_group(n.name, "bouncy") > 0) then
			-- Top of the node under the feet.
			return math.floor(low - dy - 0.1 + 0.5) + 0.5, nodes
		end
	end
end

-- mcl_movement's fall damage (floor(d - 3), ignoring Jump Boost, beds and
-- sneaking onto slime) gives way to the Java fall damage above.
if MOVEMENT_FALLS then
	function MOVEMENT.deal_fall_damage(player, distance, node_name)
		if jp.is_csm(player) then return end
		jp.fall_damage(player, distance, node_name, player:get_player_control().sneak)
	end
elseif MOVEMENT then
	-- Older mcl_movement without the hook: this file tracks falls, so
	-- drop mcl_movement's damage to count a fall only once.
	local SRC = "mcl_movement/init.lua"
	local damage_player = mcl_damage.damage_player
	function mcl_damage.damage_player(player, amount, reason, ...)
		if reason and reason.type == "fall" and not jp.is_csm(player) then
			local caller = debug.getinfo(2, "S")
			if caller and caller.source:sub(-#SRC) == SRC then
				return
			end
		end
		return damage_player(player, amount, reason, ...)
	end
end

------------------------------------------------------------------------
-- Join: base physics and disabling engine fall damage
------------------------------------------------------------------------

-- Physics factors persist in the player's metadata: drop the ones this
-- file set in an earlier session (in water, slow falling, using an
-- item...) or under a configuration that no longer applies them.
local OWN_FACTORS = {
	{ "gravity", ID }, { "jump", ID },
	{ "acceleration_default", ID }, { "acceleration_air", ID },
	{ "acceleration_default", ID_WATER }, { "liquid_sink", ID_WATER },
	{ "gravity", ID_SLOWFALL }, { "speed", ID_USE },
	{ "acceleration_default", ID_USE_ACCEL },
}

local function apply_base_physics(player)
	for _, f in ipairs(OWN_FACTORS) do
		orig_remove(player, f[1], f[2])
	end
	if jp.is_csm(player) or not own_physics then return end
	orig_add(player, "gravity", ID, F_GRAVITY)
	orig_add(player, "jump", ID, F_JUMP)
	orig_add(player, "acceleration_default", ID, F_ACCEL)
	orig_add(player, "acceleration_air", ID, F_ACCEL_AIR)
end

core.register_on_joinplayer(function(player)
	state[player] = nil
	st_of(player)
	apply_base_physics(player)
	if not jp.is_csm(player) then
		local groups = player:get_armor_groups()
		groups.fall_damage_add_percent = -100
		player:set_armor_groups(groups)
	end
end)

core.register_on_respawnplayer(function(player)
	jp.reset_fall(player)
end)

------------------------------------------------------------------------
-- Per-step update
------------------------------------------------------------------------

local function facing(player)
	local yaw = player:get_look_horizontal()
	return -math.sin(yaw), math.cos(yaw)
end

local function in_water_now(pos)
	local n = node_at(pos.x, pos.y + 0.3, pos.z)
	return core.get_item_group(n.name, "water") > 0, n
end

local function in_liquid_now(pos)
	local d = ndef(node_at(pos.x, pos.y + 0.3, pos.z))
	return d ~= nil and (d.liquidtype or "none") ~= "none"
end

local function update_water_physics(player, st, in_water, sprinting)
	local want = in_water and (sprinting and "sprint" or "walk") or nil
	if want == st.water_mode then return end
	st.water_mode = want
	if not want then
		orig_remove(player, "acceleration_default", ID_WATER)
		orig_remove(player, "liquid_sink", ID_WATER)
		return
	end
	-- Equilibrium speed in water = accel / drag.  Sprint multiplies both
	-- the target speed and the acceleration by 1.3.
	local target = want == "sprint" and WATER_SPRINT / 1.3 or WATER_WALK
	local accel = target * WATER_DRAG -- m/s^2 before the sprint factor
	local f_accel = (accel / 10) / S_ACCEL / F_ACCEL
	orig_add(player, "acceleration_default", ID_WATER, f_accel)
	-- Idle sinking: liquid gravity - upward accel = drag * sink speed.
	local speed_mul = want == "sprint" and 1.3 or 1
	local g_liquid = accel * speed_mul + WATER_DRAG * WATER_SINK
	orig_add(player, "liquid_sink", ID_WATER, g_liquid / (2 * S_SINK))
end

local USE_ITEMS = {
	["mcl_tridents:trident"] = true,
	["mcl_spyglass:spyglass"] = true,
}

-- This file's fall tracking (without mcl_movement's): the fall distance is
-- the drop from the highest point since the player was last on the ground.
local function track_fall(player, st, pos, vel, ctrl, grounded, in_water, now)
	-- Teleport (pearl, chorus, /tp): moved farther than its speed allows.
	local lv = st.last_vel or vel
	local dt = math.max(now - (st.time or now), 0.05)
	if vector.distance(pos, st.last_pos) > (vector.length(vel) + vector.length(lv)) * dt + 2 then
		jp.reset_fall(player, pos.y)
	end

	local ground_y, nodes = missed_landing(st, pos, vel, ctrl)
	if player:get_attach() or in_resetting_node(pos) or in_water then
		st.fall_start = pos.y
	elseif ground_y then
		-- Bounced or jumped again between two position updates.
		fall_damage(player, st, pos, ctrl, ground_y, nodes)
		st.fall_start = pos.y
	elseif grounded then
		if not st.was_on_ground then
			fall_damage(player, st, pos, ctrl)
		end
		st.fall_start = pos.y
	elseif pos.y > st.fall_start then
		st.fall_start = pos.y
	end
	st.fall_distance = grounded and 0 or math.max(0, st.fall_start - pos.y)
end

core.register_globalstep(function()
	local now = jp.now()
	for player in mcl_util.connected_players() do
		local st = st_of(player)
		local pos = player:get_pos()
		local vel = player:get_velocity()
		local ctrl = player:get_player_control()
		local csm = jp.is_csm(player)

		-- Ground / environment state.
		local grounded = vel.y <= 0.5 and #ground_nodes(pos) > 0
		st.was_on_ground = st.on_ground
		st.on_ground = grounded
		local in_water = in_water_now(pos)
		st.in_water = in_water
		local feet = node_at(pos.x, pos.y + 0.1, pos.z)
		local feet_def = ndef(feet)
		st.climbing = feet_def and feet_def.climbable or false

		-- Trident charging / spyglass: Java use slowdown.
		local wield = player:get_wielded_item():get_name()
		local using_special = USE_ITEMS[wield] and ctrl.place or false
		if using_special ~= (st.special_use or false) then
			st.special_use = using_special
			if using_special then
				orig_add(player, "speed", ID_USE, jp.USE_SPEED)
				st.use_ids = st.use_ids or {}
				st.use_ids[ID_USE] = true
			else
				orig_remove(player, "speed", ID_USE)
				if st.use_ids then st.use_ids[ID_USE] = nil end
			end
			st.using_item = st.use_ids and next(st.use_ids) ~= nil or false
		end

		-- Blindness stops an active sprint.
		if st.sprint_active and mcl_potions.has_effect(player, "blindness") then
			jp.stop_sprint(player, 0.05)
		end
		update_sprint(player, st)

		-- Java's ground friction does not depend on the input, so a player
		-- who starts using an item slows down to the item-use speed within
		-- a few ticks.  The engine scales its acceleration by the speed
		-- factor (x0.2), which let a player who started eating at full
		-- sprint keep running for half a second; undo that scaling.  (In
		-- liquids, on ladders and in flight mcl_movement and this file
		-- compute that acceleration themselves.)
		if not csm and jp.physics_enabled then
			local flying = ctrl.flying or (MOVEMENT and MOVEMENT.is_flying(player)) or false
			local want = st.using_item and not st.climbing and not flying
				and not in_liquid_now(pos)
			if want ~= (st.use_accel or false) then
				st.use_accel = want
				if want then
					orig_add(player, "acceleration_default", ID_USE_ACCEL, 1 / jp.USE_SPEED)
				else
					orig_remove(player, "acceleration_default", ID_USE_ACCEL)
				end
			end
		end

		if not csm then
			if MOVEMENT_FALLS then
				-- (mcl_movement's step has already run this server step.)
				st.fall_distance = MOVEMENT.get_fall_distance(player)
			else
				track_fall(player, st, pos, vel, ctrl, grounded, in_water, now)
			end

			-- Slow Falling while descending: no fall damage.
			local slow = vel.y <= 0 and mcl_potions.has_effect(player, "slow_falling") and true or false
			if slow then
				st.fall_start = pos.y
				st.fall_distance = 0
			end

			if own_physics then
				-- Sprint-jump boost.
				if st.was_on_ground and not grounded and vel.y > JAVA_JUMP * 0.5
						and ctrl.jump and st.sprint_active and not in_water then
					local fx, fz = facing(player)
					player:add_velocity(vector.new(fx * SPRINT_JUMP_BOOST, 0, fz * SPRINT_JUMP_BOOST))
				end

				-- Slow Falling: low gravity only while descending.
				if slow ~= (st.slow_falling or false) then
					st.slow_falling = slow
					if slow then
						orig_add(player, "gravity", ID_SLOWFALL, 0.01 / 0.08)
					else
						orig_remove(player, "gravity", ID_SLOWFALL)
					end
				end
				if slow and vel.y < -SLOWFALL_TERMINAL then
					player:add_velocity(vector.new(0, -SLOWFALL_TERMINAL - vel.y, 0))
				end

				update_water_physics(player, st, in_water, st.sprint_active)
			end
		else
			st.fall_distance = grounded and 0 or math.max(0, (st.fall_start or pos.y) - pos.y)
			if grounded or pos.y > (st.fall_start or pos.y) then st.fall_start = pos.y end
		end
		st.last_pos = pos
		st.last_vel = vel
		st.time = now
	end
end)

------------------------------------------------------------------------
-- Elytra damage
------------------------------------------------------------------------
-- Java: landing deals ceil(fall distance - 3) (Mineclonia: the whole
-- distance), hitting a wall deals (speed lost in b/t) * 10 - 3, i.e.
-- 0.5 * m/s - 3 (Mineclonia: no -3).

do
	local elytra = core.registered_entities["mcl_armor:elytra_entity"]
	if elytra and elytra.check_fall_damage then
		function elytra:check_fall_damage(moveresult)
			local self_pos = self.object:get_pos()
			if not self_pos then return end
			local fall_y = self._last_fall_y or self_pos.y
			local d = self._fall_distance + (fall_y - self_pos.y)
			self._fall_distance = math.max(d, 0)
			self._last_fall_y = self_pos.y
			if moveresult.touching_ground then
				local safe = self._safe_fall_distance or 3
				if self.driver and self.driver:is_valid() then
					safe = 3 + jp.effect_level(self.driver, "leaping")
					local amount = math.ceil(self._fall_distance - safe - 1e-6)
					if amount > 0 then
						mcl_damage.damage_player(self.driver, amount, { type = "fall" })
					end
				end
				self._last_fall_y = nil
				self._fall_distance = 0
			end
		end
	end
end

mcl_damage.register_modifier(function(obj, damage, reason)
	if reason.type == "fly_into_wall" and obj:is_player() and not jp.is_csm(obj) then
		return math.max(0, damage - 3)
	end
end, -1001)
