-- mcl_java_pvp: ranged weapons, projectiles and explosions.
--
-- Bows, crossbows, tridents, snowballs/eggs/ender pearls, wind charges,
-- explosions (TNT, crystals, beds...) and splash/lingering/tipped potions
-- are changed to behave like Minecraft Java Edition 1.21.
--
-- Units: Java velocities are blocks/tick (b/t), 1 b/t = 20 m/s.  Java
-- accelerations are b/t^2, 1 b/t^2 = 400 m/s^2.  Java air drag is a
-- per-tick multiplier (0.99 for projectiles), applied here as
-- 0.99^(dtime*20).
--
-- Nothing in Mineclonia is edited: item definitions are overridden,
-- entity prototypes in core.registered_entities are patched, public
-- functions of mcl_bows/mcl_tridents/mcl_throwing/mcl_charges/
-- mcl_explosions/mcl_potions are wrapped or replaced, and a few
-- `controls` callbacks of mcl_bows are replaced.
--
-- Expected from other files of this mod (all optional, checked at runtime):
--   jp.last_hurt[player] = {fresh = bool, applied = bool}   (damage.lua)
--   jp.reset_fall(player, y)                                 (movement.lua)
--   jp.state[player].on_ground                               (movement.lua)
--   mcl_player.player_knockback replaced by a Java version   (melee.lua)

local jp = mcl_java_pvp

local function warn(msg)
	core.log("warning", "[mcl_java_pvp] ranged: " .. msg)
end

local function has_mod(name)
	return core.get_modpath(name) ~= nil
end

------------------------------------------------------------------------
-- Constants (Java values converted to Luanti units)
------------------------------------------------------------------------

local TICKS = 20                     -- ticks per second
local DRAG = 0.99                    -- projectile air drag per tick
local ARROW_GRAVITY = 20             -- 0.05 b/t^2 (arrows, tridents, potions)
local THROWABLE_GRAVITY = 12         -- 0.03 b/t^2 (snowball, egg, pearl)
local ARROW_WATER_DRAG = 0.6         -- arrow inertia in water per tick
local BOW_SPEED = 3.0 * 20           -- full charge bow arrow speed (m/s)
local CROSSBOW_SPEED = 3.15 * 20     -- crossbow arrow speed (m/s)
local THROW_SPEED = 1.5 * 20         -- snowball/egg/pearl/wind charge (m/s)
local POTION_SPEED = 0.5 * 20        -- splash/lingering potions (m/s)
local POTION_PITCH_OFFSET = -20      -- degrees (aim 20 degrees higher)
local INACCURACY = 1.0               -- player projectile inaccuracy
local HIT_MARGIN = 0.3               -- Java ProjectileUtil entity box inflation
local PEARL_COOLDOWN = 1.0           -- 20 ticks
local PEARL_KEY = "mcl_throwing:ender_pearl"
local WIND_CHARGE_COOLDOWN = 0.5     -- 10 ticks
local WIND_CHARGE_KEY = "mcl_charges:wind_charge"
local BOW_USES = 384
local CROSSBOW_USES = 465
local CROSSBOW_CHARGE = 1.25         -- seconds, -0.25 per Quick Charge level

------------------------------------------------------------------------
-- Generic helpers
------------------------------------------------------------------------

-- Java Random.triangle(mode, deviation).
local function triangle(mode, deviation)
	return mode + deviation * (math.random() - math.random())
end

-- Java Projectile.shoot direction spread (1.21 uses a triangle
-- distribution of 0.0172275 * inaccuracy per component).
local function add_inaccuracy(dir, inaccuracy)
	local d = vector.normalize(dir)
	if not inaccuracy or inaccuracy == 0 then return d end
	local s = 0.0172275 * inaccuracy
	return vector.new(d.x + triangle(0, s), d.y + triangle(0, s), d.z + triangle(0, s))
end

-- Velocity a shooter imparts to its projectile (Java
-- Projectile.shootFromRotation): horizontal always, vertical only when
-- the shooter is airborne.
local function shooter_velocity(obj)
	if not obj or not obj:is_valid() then return vector.zero() end
	local v
	local parent = obj:get_attach()
	if parent then
		v = parent:get_velocity()
	else
		v = obj:get_velocity()
	end
	if not v then return vector.zero() end
	v = vector.copy(v)
	local on_ground
	if obj:is_player() then
		on_ground = jp.on_ground(obj)
	else
		on_ground = math.abs(v.y) < 0.2
	end
	if on_ground then v.y = 0 end
	return v
end

-- Direction from a player's view rotation with an optional extra pitch
-- (degrees) applied to the vertical component only, like Java
-- shootFromRotation(shooter, xRot, yRot, roll_offset, ...).
local function rotation_dir(player, pitch_offset_deg)
	local yaw = player:get_look_horizontal()
	local pitch = player:get_look_vertical()
	local off = math.rad(pitch_offset_deg or 0)
	return vector.normalize(vector.new(
		-math.sin(yaw) * math.cos(pitch),
		-math.sin(pitch + off),
		math.cos(yaw) * math.cos(pitch)))
end

-- Full Java shootFromRotation: direction + inaccuracy, scaled, plus the
-- shooter's velocity.  speed in m/s.
local function shoot_velocity(player, pitch_offset_deg, speed, inaccuracy)
	local dir = add_inaccuracy(rotation_dir(player, pitch_offset_deg), inaccuracy)
	return vector.add(vector.multiply(dir, speed), shooter_velocity(player))
end

-- Java projectile spawn point: eye height - 0.1.
local function shoot_pos(player)
	local pos = jp.eye_pos(player)
	pos.y = pos.y - 0.1
	return pos
end

local function ensure_acceleration(obj, ay)
	local a = obj:get_acceleration()
	if not a or a.x ~= 0 or a.z ~= 0 or math.abs(a.y - ay) > 1e-3 then
		obj:set_acceleration(vector.new(0, ay, 0))
	end
end

-- Apply per-tick drag factor `f` over dtime.
local function apply_drag(obj, f, dtime)
	local v = obj:get_velocity()
	if not v then return end
	obj:set_velocity(vector.multiply(v, math.pow(f, dtime * TICKS)))
end

-- Projectiles fired by mobs keep Mineclonia's flight physics: the mobs'
-- aim compensation (e.g. +0.12*distance for skeletons) is tuned for it.
local function fired_by_mob(shooter)
	return shooter ~= nil and type(shooter) ~= "string" and type(shooter.is_player) == "function"
		and not shooter:is_player()
end

-- Cached per entity on its first step.
local function java_physics(self, shooter)
	if self._jp_java == nil then
		self._jp_java = not fired_by_mob(shooter)
	end
	return self._jp_java
end

local function node_def_at(pos)
	local node = core.get_node(pos)
	return node, core.registered_nodes[node.name]
end

local function in_water(pos)
	local node = core.get_node(pos)
	return core.get_item_group(node.name, "water") > 0
end

local function is_creative(player)
	return player and player:is_player() and core.is_creative_enabled(player:get_player_name())
end

local function resolve_player(p)
	if type(p) == "string" then
		return core.get_player_by_name(p)
	end
	if p and p.is_valid and p:is_valid() then return p end
	return nil
end

-- Wrap a method of a table: t[key] = wrapper(original, ...).
local function wrap(t, key, wrapper, what)
	local orig = t and t[key]
	if type(orig) ~= "function" then
		warn("cannot wrap missing function " .. (what or tostring(key)))
		return false
	end
	t[key] = function(...)
		return wrapper(orig, ...)
	end
	return true
end

-- Intersection parameter t in [0,1] of segment p0->p1 with box
-- {x1,y1,z1,x2,y2,z2}, or nil.
local AXES = { "x", "y", "z" }
local function segment_box(p0, p1, box)
	local tmin, tmax = 0, 1
	for i = 1, 3 do
		local a = AXES[i]
		local lo, hi = box[i], box[i + 3]
		local o, d = p0[a], p1[a] - p0[a]
		if math.abs(d) < 1e-9 then
			if o < lo or o > hi then return nil end
		else
			local t1, t2 = (lo - o) / d, (hi - o) / d
			if t1 > t2 then t1, t2 = t2, t1 end
			if t1 > tmin then tmin = t1 end
			if t2 < tmax then tmax = t2 end
			if tmin > tmax then return nil end
		end
	end
	return tmin
end

local function inflate(box, m)
	return { box[1] - m, box[2] - m, box[3] - m, box[4] + m, box[5] + m, box[6] + m }
end

-- Can a thrown projectile hit this object?
local function is_projectile_target(obj, self_obj)
	if obj == self_obj or not obj:is_valid() then return false end
	if obj:is_player() then
		return obj:get_hp() > 0
	end
	local ent = obj:get_luaentity()
	if not ent then return false end
	if self_obj and ent.name == (self_obj:get_luaentity() or {}).name then return false end
	return (ent.is_mob or ent._hittable_by_projectile) and true or false
end

-- Trace a projectile's movement from p0 to p1.  Returns the first hit:
--   {type = "node", pos, normal, under, node}  or
--   {type = "object", ref, pos}
-- opts.exclude: object to ignore (the owner before it has been left)
-- opts.node_hit(node, def): optional predicate for extra nodes that stop
--   the projectile (default: walkable nodes and unknown nodes/ignore).
local function trace_projectile(self_obj, p0, p1, opts)
	opts = opts or {}
	local len = vector.distance(p0, p1)
	local best_t, best = math.huge, nil
	if len > 1e-6 then
		for pt in core.raycast(p0, p1, false, false) do
			if pt.type == "node" then
				local node = core.get_node(pt.under)
				local def = core.registered_nodes[node.name]
				local stops = node.name == "ignore" or not def or def.walkable ~= false
				if not stops and opts.node_hit then
					stops = opts.node_hit(node, def)
				end
				if stops then
					local ip = pt.intersection_point or p0
					best_t = vector.distance(p0, ip) / len
					best = {
						type = "node", pos = ip, under = pt.under, node = node,
						normal = pt.intersection_normal or vector.zero(),
					}
					break
				end
			end
		end
	end
	local mid = vector.multiply(vector.add(p0, p1), 0.5)
	for obj in core.objects_inside_radius(mid, len / 2 + 3) do
		if obj ~= opts.exclude and is_projectile_target(obj, self_obj) then
			local ok, box = pcall(jp.object_box, obj)
			if ok and box then
				local t = segment_box(p0, p1, inflate(box, opts.margin or HIT_MARGIN))
				if t and t < best_t then
					best_t = t
					best = {
						type = "object", ref = obj,
						pos = vector.add(p0, vector.multiply(vector.subtract(p1, p0), t)),
					}
				end
			end
		end
	end
	return best
end

-- Owner bookkeeping for thrown projectiles: the owner cannot be hit until
-- the projectile has left it (Java Projectile.checkLeftOwner: no longer
-- within 1 block of the owner's box).
local function update_left_owner(self, pos, owner)
	if self._jp_left_owner or not owner or not owner:is_valid() then
		self._jp_left_owner = true
		return
	end
	local ok, box = pcall(jp.object_box, owner)
	if not ok or jp.dist_to_box(pos, box) > 1.0 then
		self._jp_left_owner = true
	end
end

------------------------------------------------------------------------
-- Damage types (item 13, 18)
------------------------------------------------------------------------

mcl_damage.types.trident = mcl_damage.types.trident or {}
mcl_damage.types.trident.is_projectile = true

if not mcl_damage.types.wind_charge then
	mcl_damage.register_type("wind_charge", { is_projectile = true })
else
	mcl_damage.types.wind_charge.is_projectile = true
end

------------------------------------------------------------------------
-- Shields vs. projectiles whose _shooter is a player NAME (tridents)
------------------------------------------------------------------------
-- mcl_shields.can_block resolves the attacker position from
-- reason.direct:get_luaentity()._shooter, which for player-thrown tridents
-- is a string, so the angle can never be computed and the shield modifier
-- never blocks.  Resolve the name here.

if mcl_shields and mcl_shields.can_block then
	wrap(mcl_shields, "can_block", function(orig, obj, dpos_or_dot, reason)
		if dpos_or_dot == nil and reason and reason.direct then
			local direct = reason.direct
			local ent = direct.get_luaentity and direct:get_luaentity()
			-- Fallback only: when _saved_shooter_pos is set (the trident
			-- on_step below does that) shields.lua resolves the position
			-- itself (from the projectile, like Java).
			if ent and type(ent._shooter) == "string" and not ent._saved_shooter_pos then
				local shooter = core.get_player_by_name(ent._shooter)
				if shooter then
					dpos_or_dot = shooter:get_pos()
				end
			end
		end
		return orig(obj, dpos_or_dot, reason)
	end, "mcl_shields.can_block")
end

------------------------------------------------------------------------
-- Arrows (items 2, 3, 4, 11, 22)
------------------------------------------------------------------------

-- Java AbstractArrow damage: ceil(speed_bt * base); crit adds
-- nextInt(i/2 + 2).
local function java_arrow_damage(self, v)
	if not v then v = self.object:get_velocity() end
	local speed_bt = vector.length(v or vector.zero()) / 20
	local i = math.ceil(jp.clamp(speed_bt * (self._damage or 2), 0, 2147483647))
	if self._is_critical then
		i = i + math.random(0, math.floor(i / 2) + 1)
	end
	return i
end

-- Base knockback (via mcl_player.player_knockback, Java version in
-- melee.lua) and Punch.  Skipped entirely when the arrow did not actually
-- damage the target (shield block path of on_hit_player).
local function java_arrow_knockback(self, object, damage)
	if self._jp_hit_obj ~= object then
		return -- shield-blocked: Java applies no knockback/Punch
	end
	local entity = object:get_luaentity()
	local v = self.object:get_velocity() or vector.zero()
	v.y = 0
	local dir = vector.normalize(v)

	if entity and entity.is_mob then
		if entity.projectile_knockback then
			entity:projectile_knockback(1, dir)
		end
	elseif object:is_player() then
		mcl_player.player_knockback(object, self.object, dir, nil, damage)
	end

	local punch = self._knockback or 0
	if punch <= 0 or vector.length(v) < 1e-6 then return end

	if object:is_player() then
		-- Only when the hurt actually went through (not absorbed by i-frames).
		local lh = jp.last_hurt and jp.last_hurt[object]
		if lh and lh.applied == false then return end
		-- Java AbstractArrow.doKnockback: push(dir * punch*0.6*(1-KBR), 0.1)
		local e = math.max(0, 1 - jp.knockback_resistance(object))
		local s = punch * 0.6 * e
		jp.push(object, dir.x * s, 0.1, dir.z * s)
	elseif entity then
		-- Mobs: keep Mineclonia's formula (mob physics are Mineclonia's).
		local resistance = entity.knockback_resistance or 0
		local total = punch * (1.0 - resistance) * 12 * 0.546
		local kv = vector.multiply(dir, total)
		kv.y = kv.y + 2.0 * 0.91 * (1.0 - resistance)
		object:add_velocity(kv)
	end
end

-- Tipped arrows: use the arrow item's real potency/extension (item 22).
local function tipped_extra_hit(self, obj)
	local stack = ItemStack(self._itemstring or "")
	local name = stack:get_name()
	local idef = core.registered_items[name]
	if not idef or not idef._effect_list then
		name = (self.name or ""):gsub("_entity$", "")
		idef = core.registered_items[name]
	end
	if not idef then return end
	local meta = stack:get_meta()
	local potency = meta:get_int("mcl_potions:potion_potent")
	local plus = meta:get_int("mcl_potions:potion_plus")
	for ename, details in pairs(idef._effect_list or {}) do
		local level = mcl_potions.level_from_details(details, potency)
		local dur = mcl_potions.duration_from_details(details, potency, plus,
			mcl_potions.TIPPED_FACTOR or 0.125)
		mcl_potions.give_effect_by_level(ename, obj, level, dur)
	end
	local base = name:gsub("_arrow$", "")
	local pdef = mcl_potions.registered_potions and mcl_potions.registered_potions[base]
	if pdef and pdef.custom_effect then
		pdef.custom_effect(obj, potency + 1, plus, self._shooter)
	end
end

local function patch_arrow_entity(name, def)
	-- Damage formula (item 3, 12)
	def.calculate_damage = java_arrow_damage
	-- Knockback + Punch (item 4)
	def.arrow_knockback = java_arrow_knockback
	-- Water drag is applied per tick in on_step instead of per node.
	def.on_liquid_passthrough = function() end

	-- Remember which object actually took damage, so arrow_knockback
	-- can tell the shield-block path apart.
	wrap(def, "apply_effects", function(orig, self, obj)
		self._jp_hit_obj = obj
		local r = orig(self, obj)
		self._jp_hit_obj = nil
		return r
	end, name .. ".apply_effects")

	-- Piercing: Java hits level+1 entities, Mineclonia hits `level`.
	wrap(def, "on_intersect", function(orig, self, ray_hit)
		if not self._jp_pierce_fixed then
			self._jp_pierce_fixed = true
			if (self._piercing or 0) > 0 then
				self._piercing = self._piercing + 1
			end
		end
		return orig(self, ray_hit)
	end, name .. ".on_intersect")

	wrap(def, "on_activate", function(orig, self, staticdata, ...)
		local r = orig(self, staticdata, ...)
		-- Reloaded arrows already have the corrected piercing count.
		if staticdata and staticdata ~= "" then
			self._jp_pierce_fixed = true
		end
		return r
	end, name .. ".on_activate")

	-- Gravity 20 m/s^2 and Java water inertia.
	wrap(def, "on_step", function(orig, self, dtime, moveresult)
		local obj = self.object
		if obj and obj:get_pos() and not self._stuck and not self._in_player
				and not obj:get_attach() and java_physics(self, self._shooter) then
			ensure_acceleration(obj, -ARROW_GRAVITY)
			if in_water(obj:get_pos()) then
				-- Mineclonia already applies 0.99/tick; replace it by 0.6/tick.
				apply_drag(obj, ARROW_WATER_DRAG / DRAG, dtime)
			end
		end
		return orig(self, dtime, moveresult)
	end, name .. ".on_step")

	if name:find("^mcl_potions:") and def._extra_hit_func then
		def._extra_hit_func = tipped_extra_hit
	end
end

if has_mod("mcl_bows") and mcl_bows then
	local base = core.registered_entities["mcl_bows:arrow_entity"]
	if base then
		-- The tipped arrow entities are table.copy()s of the base arrow,
		-- so find every entity sharing its original methods.
		local orig_calc = base.calculate_damage
		local count = 0
		for name, def in pairs(core.registered_entities) do
			if def._is_arrow and def.calculate_damage == orig_calc then
				patch_arrow_entity(name, def)
				count = count + 1
			end
		end
		core.log("info", "[mcl_java_pvp] patched " .. count .. " arrow entities")
	else
		warn("mcl_bows:arrow_entity not found")
	end
end

------------------------------------------------------------------------
-- Bow (items 1, 2, 6)
------------------------------------------------------------------------

if has_mod("mcl_bows") and mcl_bows and mcl_bows.shoot_arrow then
	local BOW_NAMES = { ["mcl_bows:bow"] = true, ["mcl_bows:bow_enchanted"] = true }
	local function is_drawing_bow(name)
		return name:find("^mcl_bows:bow_[012]$") ~= nil
			or name:find("^mcl_bows:bow_[012]_enchanted$") ~= nil
	end

	-- Durability 384 (item 6).  Done before mcl_enchanting copies the
	-- definitions into *_enchanted variants (on_mods_loaded).
	for _, n in ipairs({ "mcl_bows:bow", "mcl_bows:bow_0", "mcl_bows:bow_1", "mcl_bows:bow_2" }) do
		if core.registered_items[n] then
			core.override_item(n, { _mcl_uses = BOW_USES, _doc_items_durability = BOW_USES })
		end
	end

	-- Java BowItem.getPowerForTime.
	local function bow_power(seconds)
		local f = seconds -- = ticks / 20
		f = (f * f + 2 * f) / 3
		if f > 1 then f = 1 end
		return f
	end

	local function bow_shoot_arrow(player, bow_stack, power, is_critical)
		local arrow_stack, arrow_index = mcl_bows.get_arrow_stack_for_bow(player)
		local infinity = mcl_enchanting.has_enchantment(bow_stack, "infinity")
		local itemstring
		if is_creative(player) then
			itemstring = arrow_stack and arrow_stack:to_string() or "mcl_bows:arrow"
		else
			if not arrow_stack then return false end
			itemstring = arrow_stack:to_string()
			if not (infinity and core.get_item_group(arrow_stack:get_name(), "ammo_bow_regular") > 0) then
				arrow_stack:take_item()
				player:get_inventory():set_stack("main", arrow_index, arrow_stack)
			end
		end
		local one = ItemStack(itemstring)
		one:set_count(1)
		itemstring = one:to_string()

		local obj = mcl_bows.shoot_arrow(itemstring, shoot_pos(player), player:get_look_dir(),
			player:get_look_horizontal(), player, power, nil, is_critical, bow_stack, not infinity)
		if obj and obj:get_pos() then
			-- Java adds the shooter's motion (item 2).
			obj:set_velocity(vector.add(obj:get_velocity(), shooter_velocity(player)))
			ensure_acceleration(obj, -ARROW_GRAVITY)
		end
		return true
	end

	-- Replaces Mineclonia's version (used by the CSM path too).
	function mcl_bows.player_shoot(player, wielditem, usetime_us)
		local seconds = math.max(0, (usetime_us or 0) / 1e6)
		local f = bow_power(seconds)
		local enchanted = mcl_enchanting.is_enchanted(wielditem:get_name())
		local has_shot = false
		-- Java: no shot (and no arrow used) below 0.1 power (~3 ticks).
		if f >= 0.1 then
			has_shot = bow_shoot_arrow(player, wielditem, f, f >= 1)
		end
		wielditem:set_name(enchanted and "mcl_bows:bow_enchanted" or "mcl_bows:bow")
		wielditem:get_meta():set_string("active", "")
		if has_shot and not is_creative(player) then
			mcl_util.use_item_durability(wielditem, 1)
		end
		player:set_wielded_item(wielditem)
	end

	-- CSM bow info (charge timings shown/simulated by the client mod).
	local function patch_bow_info(name, half, full)
		local info = mcl_serverplayer and mcl_serverplayer.bow_info
			and mcl_serverplayer.bow_info[name]
		if info then
			info.charge_time_half = half
			info.charge_time_full = full
		end
	end
	patch_bow_info("mcl_bows:bow", 0.65, 1.0)
	patch_bow_info("mcl_bows:bow_enchanted", 0.65, 1.0)

	-- Non-CSM drawing: replace Mineclonia's bow controls so that the
	-- drawing stages follow Java's pull model predicate (pulling_1 at
	-- 0.65 s, pulling_2 at 0.9 s, full power at 1.0 s).
	if controls and controls.registered_on_hold then
		jp.remove_callbacks(controls.registered_on_hold, "mcl_bows/bow.lua")
		jp.remove_callbacks(controls.registered_on_release, "mcl_bows/bow.lua")

		local draw = jp.player_table() -- player -> {start, index, stage, enchanted, key}

		local function reset_bows(player)
			local inv = player:get_inventory()
			local list = inv:get_list("main")
			if not list then return end
			for i, stack in ipairs(list) do
				local n = stack:get_name()
				if BOW_NAMES[n] then
					stack:get_meta():set_string("active", "")
				elseif is_drawing_bow(n) then
					stack:set_name(mcl_enchanting.is_enchanted(n) and "mcl_bows:bow_enchanted" or "mcl_bows:bow")
					stack:get_meta():set_string("active", "")
				end
				list[i] = stack
			end
			inv:set_list("main", list)
		end

		local function reset_state(player, reset_items)
			draw[player] = nil
			playerphysics.remove_physics_factor(player, "fov", "mcl_bows:bow_zoom")
			playerphysics.remove_physics_factor(player, "speed", "mcl_bows:use_bow")
			if reset_items then reset_bows(player) end
		end

		local function stage_name(enchanted, stage)
			return "mcl_bows:bow_" .. stage .. (enchanted and "_enchanted" or "")
		end

		local PLAYER_USE_BOW_SPEED = (tonumber(core.settings:get("movement_speed_crouch")) or 1.35)
			/ (tonumber(core.settings:get("movement_speed_walk")) or 4)

		controls.register_on_hold(function(player, key)
			if jp.is_csm(player) then return end
			if key ~= "RMB" and key ~= "zoom" then return end
			local wielditem = player:get_wielded_item()
			local name = wielditem:get_name()
			local st = draw[player]
			if not st then
				if BOW_NAMES[name] and (wielditem:get_meta():get("active") or key == "zoom")
						and (is_creative(player) or mcl_bows.get_arrow_stack_for_bow(player)) then
					local enchanted = mcl_enchanting.is_enchanted(name)
					wielditem:set_name(stage_name(enchanted, 0))
					player:set_wielded_item(wielditem)
					playerphysics.add_physics_factor(player, "speed", "mcl_bows:use_bow", PLAYER_USE_BOW_SPEED)
					playerphysics.add_physics_factor(player, "fov", "mcl_bows:bow_zoom", 0.85)
					draw[player] = {
						start = core.get_us_time(), index = player:get_wield_index(),
						stage = 0, enchanted = enchanted, key = key,
					}
				end
				return
			end
			if player:get_wield_index() ~= st.index or not is_drawing_bow(name) then
				reset_state(player, true)
				return
			end
			local t = (core.get_us_time() - st.start) / 1e6
			local stage = (t >= 0.9 and 2) or (t >= 0.65 and 1) or 0
			if stage ~= st.stage then
				st.stage = stage
				wielditem:set_name(stage_name(st.enchanted, stage))
				player:set_wielded_item(wielditem)
			end
		end)

		controls.register_on_release(function(player, key)
			if jp.is_csm(player) then return end
			local st = draw[player]
			if not st or key ~= st.key then return end
			local wielditem = player:get_wielded_item()
			if player:get_wield_index() == st.index and is_drawing_bow(wielditem:get_name()) then
				mcl_bows.player_shoot(player, wielditem, core.get_us_time() - st.start)
			end
			reset_state(player, true)
		end)

		core.register_globalstep(function()
			for player, st in pairs(draw) do
				if not player:is_valid() then
					draw[player] = nil
				elseif player:get_wield_index() ~= st.index
						or not is_drawing_bow(player:get_wielded_item():get_name()) then
					reset_state(player, true)
				end
			end
		end)
	else
		warn("controls mod not found; bow drawing stages unchanged")
	end
end

------------------------------------------------------------------------
-- Crossbow (items 7, 8, 9, 10, 11)
------------------------------------------------------------------------

if has_mod("mcl_bows") and mcl_bows and mcl_bows.shoot_arrow_crossbow then
	local UNLOADED = { ["mcl_bows:crossbow"] = true, ["mcl_bows:crossbow_enchanted"] = true }
	local LOADED = { ["mcl_bows:crossbow_loaded"] = true, ["mcl_bows:crossbow_loaded_enchanted"] = true }
	local function is_drawing_crossbow(name)
		return name:find("^mcl_bows:crossbow_[012]$") ~= nil
			or name:find("^mcl_bows:crossbow_[012]_enchanted$") ~= nil
	end

	local function charge_time(stack)
		local qc = mcl_enchanting.get_enchantment(stack, "quick_charge")
		return math.max(0, CROSSBOW_CHARGE - 0.25 * qc)
	end

	-- CSM: multiplier of the client's charge_time_full.
	function mcl_bows.crossbow_charge_time_multiplier(quick_charge)
		return math.max(0, (CROSSBOW_CHARGE - 0.25 * (quick_charge or 0)) / CROSSBOW_CHARGE)
	end
	mcl_bows.CROSSBOW_CHARGE_TIME_HALF = CROSSBOW_CHARGE * 0.58
	mcl_bows.CROSSBOW_CHARGE_TIME_FULL = CROSSBOW_CHARGE
	for _, n in ipairs({ "mcl_bows:crossbow", "mcl_bows:crossbow_enchanted" }) do
		local info = mcl_serverplayer and mcl_serverplayer.bow_info and mcl_serverplayer.bow_info[n]
		if info then
			info.charge_time_half = CROSSBOW_CHARGE * 0.58
			info.charge_time_full = CROSSBOW_CHARGE
		end
	end

	local function play_load_sound(id, object)
		core.sound_play({ name = "mcl_bows_crossbow_drawback_" .. id, gain = 0.3 },
			{ object = object, max_hear_distance = 16 }, true)
	end

	-- Load an arrow into `stack` (consumes one arrow; Multishot does not
	-- use extra arrows in Java).  Returns true on success.
	local function crossbow_load(player, stack)
		local arrow_stack, arrow_index = mcl_bows.get_arrow_stack_for_crossbow(player)
		local creative = is_creative(player)
		if not arrow_stack and not creative then return false end
		local itemstring = "mcl_bows:arrow"
		if arrow_stack then
			local one = ItemStack(arrow_stack)
			one:set_count(1)
			itemstring = one:to_string() -- keep tipped arrow metadata
			if not creative then
				arrow_stack:take_item()
				player:get_inventory():set_stack("main", arrow_index, arrow_stack)
			end
		end
		local meta = stack:get_meta()
		meta:set_string("arrow", itemstring)
		meta:set_string("active", "")
		stack:set_name(mcl_enchanting.is_enchanted(stack:get_name())
			and "mcl_bows:crossbow_loaded_enchanted" or "mcl_bows:crossbow_loaded")
		core.sound_play({ name = "mcl_bows_crossbow_load", gain = 0.3 },
			{ object = player, max_hear_distance = 16 }, true)
		return true
	end

	-- CSM release path.
	function mcl_bows.load_crossbow(player, wielditem, usetime_us)
		if (usetime_us or 0) / 1e6 < charge_time(wielditem) then return end
		if crossbow_load(player, wielditem) then
			player:set_wielded_item(wielditem)
		end
	end

	-- Rotate dir by `angle` around the shooter's local up axis (Java
	-- multishot spread of +-10 degrees).
	local function spread_dir(dir, angle)
		local right = vector.cross(dir, vector.new(0, 1, 0))
		if vector.length(right) < 1e-6 then right = vector.new(1, 0, 0) end
		right = vector.normalize(right)
		return vector.add(vector.multiply(dir, math.cos(angle)), vector.multiply(right, math.sin(angle)))
	end

	-- Fire a loaded crossbow; returns the modified stack.
	local function crossbow_fire(player, stack)
		local meta = stack:get_meta()
		local arrow = meta:get("arrow")
		local enchanted = mcl_enchanting.is_enchanted(stack:get_name())
		meta:set_string("arrow", "")
		meta:set_string("active", "")
		stack:set_name(enchanted and "mcl_bows:crossbow_enchanted" or "mcl_bows:crossbow")
		if not arrow or core.get_item_group(ItemStack(arrow):get_name(), "ammo_crossbow") == 0 then
			return stack
		end

		-- A copy without Multishot, so Mineclonia fires exactly one
		-- projectile per call (Piercing etc. are kept).
		local single = ItemStack(stack)
		local ench = mcl_enchanting.get_enchantments(single)
		local multishot = (ench.multishot or 0) > 0
		ench.multishot = nil
		single:get_meta():set_string("mcl_enchanting:enchantments", core.serialize(ench))

		local pos = shoot_pos(player)
		local dir = player:get_look_dir()
		local yaw = player:get_look_horizontal()
		local creative = is_creative(player)
		-- Centre arrow: pickupable (Java: unless creative).
		mcl_bows.shoot_arrow_crossbow(arrow, pos, dir, yaw, player, CROSSBOW_SPEED, nil, true, single, not creative)
		local count = 1
		if multishot then
			-- Side arrows: never pickupable (item 9).
			local a = math.rad(10)
			mcl_bows.shoot_arrow_crossbow(arrow, pos, spread_dir(dir, a), yaw, player, CROSSBOW_SPEED, nil, true, single, false)
			mcl_bows.shoot_arrow_crossbow(arrow, pos, spread_dir(dir, -a), yaw, player, CROSSBOW_SPEED, nil, true, single, false)
			count = 3
		end
		-- 1 durability per projectile (item 10).
		if not creative then
			mcl_util.use_item_durability(stack, count)
		end
		return stack
	end

	-- Durability 465 and right-click firing (item 8), applied before
	-- mcl_enchanting copies definitions into *_enchanted variants.
	for _, n in ipairs({ "mcl_bows:crossbow", "mcl_bows:crossbow_0", "mcl_bows:crossbow_1",
			"mcl_bows:crossbow_2", "mcl_bows:crossbow_loaded" }) do
		if core.registered_items[n] then
			core.override_item(n, { _mcl_uses = CROSSBOW_USES, _doc_items_durability = CROSSBOW_USES })
		end
	end
	if core.registered_items["mcl_bows:crossbow_loaded"] then
		local function fire_on_use(itemstack, player, pointed_thing)
			local rc = mcl_util.call_on_rightclick(itemstack, player, pointed_thing)
			if rc then return rc end
			if not player or not player:is_player() then return itemstack end
			return crossbow_fire(player, itemstack)
		end
		core.override_item("mcl_bows:crossbow_loaded", {
			on_place = fire_on_use,
			on_secondary_use = fire_on_use,
			_doc_items_usagehelp = "Hold the place key to load an arrow, release when fully charged, then press place again to shoot.",
		})
	end

	if controls and controls.registered_on_hold then
		-- Mineclonia's non-CSM charging (0.9 s) and the LMB fire callback.
		jp.remove_callbacks(controls.registered_on_hold, "mcl_bows/crossbow.lua")
		jp.remove_callbacks(controls.registered_on_release, "mcl_bows/crossbow.lua")
		jp.remove_callbacks(controls.registered_on_press, "mcl_bows/crossbow.lua")

		local draw = jp.player_table() -- player -> {start, index, stage, enchanted, charge, key}

		local function reset_crossbows(player)
			local inv = player:get_inventory()
			local list = inv:get_list("main")
			if not list then return end
			for i, stack in ipairs(list) do
				local n = stack:get_name()
				if UNLOADED[n] then
					stack:get_meta():set_string("active", "")
				elseif is_drawing_crossbow(n) then
					stack:set_name(mcl_enchanting.is_enchanted(n) and "mcl_bows:crossbow_enchanted" or "mcl_bows:crossbow")
					stack:get_meta():set_string("active", "")
				end
				list[i] = stack
			end
			inv:set_list("main", list)
		end

		local function reset_state(player, reset_items)
			draw[player] = nil
			playerphysics.remove_physics_factor(player, "speed", "mcl_bows:use_crossbow")
			if reset_items then reset_crossbows(player) end
		end

		local function stage_name(enchanted, stage)
			return "mcl_bows:crossbow_" .. stage .. (enchanted and "_enchanted" or "")
		end

		local PLAYER_USE_CROSSBOW_SPEED = (tonumber(core.settings:get("movement_speed_crouch")) or 1.35)
			/ (tonumber(core.settings:get("movement_speed_walk")) or 4)

		controls.register_on_hold(function(player, key)
			if jp.is_csm(player) then return end
			if key ~= "RMB" and key ~= "zoom" then return end
			local wielditem = player:get_wielded_item()
			local name = wielditem:get_name()
			local st = draw[player]
			if not st then
				if UNLOADED[name] and (wielditem:get_meta():get("active") or key == "zoom")
						and (is_creative(player) or mcl_bows.get_arrow_stack_for_crossbow(player)) then
					local enchanted = mcl_enchanting.is_enchanted(name)
					local charge = charge_time(wielditem)
					wielditem:set_name(stage_name(enchanted, 0))
					player:set_wielded_item(wielditem)
					play_load_sound(0, player)
					playerphysics.add_physics_factor(player, "speed", "mcl_bows:use_crossbow", PLAYER_USE_CROSSBOW_SPEED)
					draw[player] = {
						start = core.get_us_time(), index = player:get_wield_index(),
						stage = 0, enchanted = enchanted, charge = charge, key = key,
					}
				end
				return
			end
			if player:get_wield_index() ~= st.index or not is_drawing_crossbow(name) then
				reset_state(player, true)
				return
			end
			local t = (core.get_us_time() - st.start) / 1e6
			local p = st.charge > 0 and t / st.charge or math.huge
			-- Java crossbow model predicate: pulling_1 at 0.58, pulling_2 at 1.0.
			local stage = (p >= 1 and 2) or (p >= 0.58 and 1) or 0
			if stage ~= st.stage then
				st.stage = stage
				wielditem:set_name(stage_name(st.enchanted, stage))
				player:set_wielded_item(wielditem)
				play_load_sound(stage, player)
			end
		end)

		controls.register_on_release(function(player, key)
			if jp.is_csm(player) then return end
			local st = draw[player]
			if not st or key ~= st.key then return end
			local wielditem = player:get_wielded_item()
			local t = (core.get_us_time() - st.start) / 1e6
			if player:get_wield_index() == st.index and is_drawing_crossbow(wielditem:get_name())
					and t >= st.charge then
				draw[player] = nil
				playerphysics.remove_physics_factor(player, "speed", "mcl_bows:use_crossbow")
				if crossbow_load(player, wielditem) then
					player:set_wielded_item(wielditem)
					return
				end
			end
			reset_state(player, true)
		end)

		-- CSM clients fire loaded crossbows with LMB (Mineclonia behaviour).
		controls.register_on_press(function(player, key)
			if key ~= "LMB" or not jp.is_csm(player) then return end
			local wielditem = player:get_wielded_item()
			if LOADED[wielditem:get_name()] then
				player:set_wielded_item(crossbow_fire(player, wielditem))
			end
		end)

		core.register_globalstep(function()
			for player, st in pairs(draw) do
				if not player:is_valid() then
					draw[player] = nil
				elseif player:get_wield_index() ~= st.index
						or not is_drawing_crossbow(player:get_wielded_item():get_name()) then
					reset_state(player, true)
				end
			end
		end)
	else
		warn("controls mod not found; crossbow controls unchanged")
	end
end

------------------------------------------------------------------------
-- Trident (item 13)
------------------------------------------------------------------------

if has_mod("mcl_tridents") and mcl_tridents then
	local tdef = core.registered_entities["mcl_tridents:trident"]
	if tdef then
		-- Gravity 0.05 b/t^2 and drag 0.99/tick while flying (player- and
		-- dispenser-thrown tridents; drowned keep Mineclonia's physics).
		wrap(tdef, "on_step", function(orig, self, dtime, moveresult)
			local obj = self.object
			if obj:get_pos() and not self._in_block and not self._riptide_player
					and java_physics(self, self._shooter) then
				ensure_acceleration(obj, -ARROW_GRAVITY)
				apply_drag(obj, DRAG, dtime)
			end
			-- Keep the shooter position available for shields if the
			-- thrower logs off.
			if type(self._shooter) == "string" then
				local p = core.get_player_by_name(self._shooter)
				if p then self._saved_shooter_pos = p:get_pos() end
			end
			return orig(self, dtime, moveresult)
		end, "trident.on_step")
	else
		warn("mcl_tridents:trident entity not found")
	end

	-- Riptide spin attack state: player -> {until_t, hit = {}}
	local spin = jp.player_table()

	local function space_free(pos)
		for _, dy in ipairs({ 0.1, 1.0, 1.75 }) do
			local _, def = node_def_at(vector.offset(pos, 0, dy, 0))
			if not def or def.walkable ~= false then return false end
		end
		return true
	end

	-- Java TridentItem.releaseUsing (riptide): push the player by
	-- 1.5 + 0.75*(level-1) b/t along the look direction, lift 1.2 blocks
	-- when on the ground, start a 20 tick spin attack (8 damage).
	local function java_riptide(player, dir, level)
		local strength = 1.5 + 0.75 * (level - 1)
		local d = vector.normalize(dir)
		if jp.on_ground(player) then
			local pos = player:get_pos()
			local up = vector.offset(pos, 0, 1.2, 0)
			if space_free(up) then
				player:set_pos(up)
			end
		end
		jp.push(player, d.x * strength, d.y * strength, d.z * strength)
		core.sound_play("mcl_tridents_riptide", { pos = player:get_pos(), gain = 1, max_hear_distance = 16 }, true)
		spin[player] = { until_t = jp.now() + 1.0, hit = {} }
	end

	wrap(mcl_tridents, "shoot_trident", function(orig, stack, obj, pos, yaw, pitch, dir,
			collectable, riptide_level, inaccuracy, speed)
		riptide_level = riptide_level or 0
		if obj and obj:is_player() and riptide_level > 0 and not jp.is_csm(obj) then
			local d = dir
			if not d then
				local c = math.cos(pitch)
				d = vector.new(-math.sin(yaw) * c, -math.sin(pitch), math.cos(yaw) * c)
			end
			java_riptide(obj, d, riptide_level)
			-- No durability here: player_shoot already uses 1 for riptide
			-- (Mineclonia used 2).
			return true
		end
		if obj and obj:is_player() and riptide_level <= 0 then
			-- Java adds the thrower's motion: fold it into dir/speed.
			local d = dir
			if not d then
				local c = math.cos(pitch)
				d = vector.new(-math.sin(yaw) * c, -math.sin(pitch), math.cos(yaw) * c)
			end
			local base = 50.0 * (speed or 1.0)
			local v = vector.add(vector.multiply(vector.normalize(d), base), shooter_velocity(obj))
			local len = vector.length(v)
			if len > 1e-3 then
				return orig(stack, obj, pos, yaw, pitch, vector.divide(v, len), collectable, 0,
					(inaccuracy or 1.0) * base / len, len / 50.0)
			end
		end
		return orig(stack, obj, pos, yaw, pitch, dir, collectable, riptide_level, inaccuracy, speed)
	end, "mcl_tridents.shoot_trident")

	core.register_globalstep(function()
		local now = jp.now()
		for player, st in pairs(spin) do
			if not player:is_valid() or now > st.until_t then
				spin[player] = nil
			else
				local ok, pbox = pcall(jp.object_box, player)
				if ok then
					for obj in core.objects_inside_radius(player:get_pos(), 4) do
						if obj ~= player and not st.hit[obj] and jp.is_living(obj) and obj:get_hp() > 0 then
							local ok2, box = pcall(jp.object_box, obj)
							if ok2 and pbox[1] <= box[4] and pbox[4] >= box[1] and pbox[2] <= box[5]
									and pbox[5] >= box[2] and pbox[3] <= box[6] and pbox[6] >= box[3] then
								st.hit[obj] = true
								local dmg = mcl_util.deal_damage(obj, 8, { type = "player", source = player, direct = player })
								if obj:is_player() then
									local dir = vector.direction(player:get_pos(), obj:get_pos())
									mcl_player.player_knockback(obj, player, dir, nil, dmg or 8)
								end
								-- Java: bounce back (velocity * -0.2) and stop spinning.
								local v = player:get_velocity()
								if v then player:add_velocity(vector.multiply(v, -1.2)) end
								spin[player] = nil
								break
							end
						end
					end
				end
			end
		end
	end)
end

------------------------------------------------------------------------
-- Snowballs, eggs, ender pearls (items 15, 16, 17)
------------------------------------------------------------------------

if has_mod("mcl_throwing") and mcl_throwing then
	local THROWN = {
		["mcl_throwing:snowball"] = "mcl_throwing:snowball_entity",
		["mcl_throwing:egg"] = "mcl_throwing:egg_entity",
		["mcl_throwing:ender_pearl"] = "mcl_throwing:ender_pearl_entity",
	}
	local THROWN_ENTITY = {}
	for _, e in pairs(THROWN) do THROWN_ENTITY[e] = true end

	-- Player throw (Java ThrowableItem.use: speed 1.5 b/t, inaccuracy 1,
	-- spawned at eye-0.1, shooter motion added).  Holding the use key
	-- throws repeatedly like Java (no place_was_held check).
	local function make_throw(itemname, entname)
		return function(item, player, pointed_thing)
			local rc = mcl_util.call_on_rightclick(item, player, pointed_thing)
			if rc then return rc end
			if not player or not player:is_player() then return end
			local is_pearl = itemname == "mcl_throwing:ender_pearl"
			if is_pearl and jp.item_cooldown(player, PEARL_KEY) > 0 then
				return item
			end
			local pos = shoot_pos(player)
			core.sound_play("mcl_throwing_throw", { pos = pos, gain = 0.4, max_hear_distance = 16 }, true)
			local obj = core.add_entity(pos, entname)
			if not obj or not obj:get_pos() then return end
			obj:set_velocity(shoot_velocity(player, 0, THROW_SPEED, INACCURACY))
			obj:set_acceleration(vector.new(0, -THROWABLE_GRAVITY, 0))
			local ent = obj:get_luaentity()
			ent._thrower = player:get_player_name()
			ent._jp_owner = player
			ent._jp_last = pos
			if is_pearl then
				jp.set_item_cooldown(player, PEARL_KEY, PEARL_COOLDOWN)
			end
			if not is_creative(player) then
				item:take_item()
			end
			return item
		end
	end

	for itemname, entname in pairs(THROWN) do
		if core.registered_items[itemname] and core.registered_entities[entname] then
			local f = make_throw(itemname, entname)
			core.override_item(itemname, { on_place = f, on_secondary_use = f })
		else
			warn("throwable " .. itemname .. " not found")
		end
	end

	-- Dispensers and other callers: Java gravity for the thrown entity.
	wrap(mcl_throwing, "throw", function(orig, throw_item, pos, dir, velocity, thrower)
		local obj = orig(throw_item, pos, dir, velocity, thrower)
		if obj and obj:get_pos() then
			local ent = obj:get_luaentity()
			if ent and THROWN_ENTITY[ent.name] then
				ent._jp_last = vector.copy(pos)
				if not fired_by_mob(thrower) then
					obj:set_acceleration(vector.new(0, -THROWABLE_GRAVITY, 0))
				end
			end
		end
		return obj
	end, "mcl_throwing.throw")

	local function owner_of(self)
		local o = self._jp_owner
		if o and o:is_valid() then return o end
		o = resolve_player(self._thrower)
		self._jp_owner = o
		return o
	end

	-- Common movement + collision for thrown items.  Returns the hit or nil.
	local function throwable_step(self, dtime, node_hit)
		local obj = self.object
		local pos = obj:get_pos()
		if not pos then return nil end
		if java_physics(self, self._thrower) then
			ensure_acceleration(obj, -THROWABLE_GRAVITY)
			apply_drag(obj, DRAG, dtime)
		end
		local last = self._jp_last or pos
		self._jp_last = pos
		local owner = owner_of(self)
		local exclude = (not self._jp_left_owner) and owner or nil
		local hit = trace_projectile(obj, last, pos, { exclude = exclude, node_hit = node_hit })
		update_left_owner(self, pos, owner)
		return hit
	end

	local function target_hit(hit)
		if hit and hit.type == "node" and hit.node and hit.node.name == "mcl_target:target_off"
				and mcl_target and mcl_target.hit then
			mcl_target.hit(vector.copy(hit.under))
		end
	end

	-- Mobs are punched by the thrower like Mineclonia did (blazes take 3
	-- from snowballs etc).  Players: Java deals 0 damage, and
	-- Player.hurt(0) does nothing at all - no knockback, no Fire Aspect.
	local function hit_mob(self, obj, groups)
		if obj:is_player() then return end
		local thrower = owner_of(self)
		if thrower then
			obj:punch(thrower, 1.0, { full_punch_interval = 1.0, damage_groups = groups }, nil)
		end
	end

	local function snowball_particles(pos, vel)
		local v = vector.normalize(vector.multiply(vel or vector.zero(), -1))
		core.add_particlespawner({
			amount = 20, time = 0.001,
			minpos = pos, maxpos = pos,
			minvel = vector.add({ x = -2, y = 3, z = -2 }, v),
			maxvel = vector.add({ x = 2, y = 5, z = 2 }, v),
			minacc = { x = 0, y = -9.81, z = 0 }, maxacc = { x = 0, y = -9.81, z = 0 },
			minexptime = 1, maxexptime = 3, minsize = 0.7, maxsize = 0.7,
			collisiondetection = true, collision_removal = true, object_collision = false,
			texture = "weather_pack_snow_snowflake" .. math.random(1, 2) .. ".png",
		})
	end

	local sdef = core.registered_entities["mcl_throwing:snowball_entity"]
	if sdef then
		sdef.on_step = function(self, dtime)
			local hit = throwable_step(self, dtime)
			if not hit then return end
			local vel = self.object:get_velocity()
			if hit.type == "object" then
				hit_mob(self, hit.ref, { snowball_vulnerable = 3 })
				core.sound_play("mcl_throwing_snowball_impact_soft", { pos = hit.pos, max_hear_distance = 16, gain = 0.7 }, true)
			else
				core.sound_play("mcl_throwing_snowball_impact_hard", { pos = hit.pos, max_hear_distance = 16, gain = 0.7 }, true)
				target_hit(hit)
			end
			snowball_particles(hit.pos, vel)
			self.object:remove()
		end
	end

	local edef = core.registered_entities["mcl_throwing:egg_entity"]
	if edef then
		edef.on_step = function(self, dtime)
			local hit = throwable_step(self, dtime)
			if not hit then return end
			if hit.type == "object" then
				hit_mob(self, hit.ref, { egg_vulnerable = 0 })
			else
				target_hit(hit)
			end
			-- Java Egg.onHit: 1/8 chance of a chick (1/32 of those: 4), on any hit.
			local spawn_pos = vector.copy(hit.pos)
			if hit.type == "node" then
				spawn_pos = vector.add(spawn_pos, vector.multiply(hit.normal, 0.3))
			end
			if math.random(1, 8) == 1 and mcl_mobs and mcl_mobs.spawn_child then
				local n = (math.random(1, 32) == 1) and 4 or 1
				for _ = 1, n do
					mcl_mobs.spawn_child(spawn_pos, "mobs_mc:chicken")
				end
			end
			core.sound_play("mcl_throwing_egg_impact", { pos = hit.pos, max_hear_distance = 10, gain = 0.5 }, true)
			self.object:remove()
		end
	end

	-- Ender pearl -----------------------------------------------------

	local function player_space_free(p)
		for _, dy in ipairs({ 0.05, 0.9, 1.75 }) do
			local node, def = node_def_at(vector.offset(p, 0, dy, 0))
			if node.name == "ignore" or not def or def.walkable ~= false then return false end
		end
		return true
	end

	-- Where the thrower ends up.  Java teleports to the pearl's position;
	-- here the pearl's hit point is moved out of the struck face so the
	-- player fits.
	local function pearl_destination(hit, vel)
		local dest = vector.copy(hit.pos)
		if hit.type == "node" then
			local n = hit.normal
			if n.y > 0 then
				dest.y = dest.y + 0.01
			elseif n.y < 0 then
				dest.y = dest.y - 1.81
			else
				dest.x = dest.x + n.x * 0.31
				dest.z = dest.z + n.z * 0.31
			end
		end
		if player_space_free(dest) then return dest end
		-- Search backwards along the trajectory, then up/down.
		local back = vector.normalize(vector.multiply(vel or vector.new(0, -1, 0), -1))
		for i = 1, 8 do
			local p = vector.add(dest, vector.multiply(back, 0.25 * i))
			if player_space_free(p) then return p end
		end
		for _, dy in ipairs({ 0.5, 1, -1, 1.5, -1.5, 2 }) do
			local p = vector.offset(dest, 0, dy, 0)
			if player_space_free(p) then return p end
		end
		return dest
	end

	local function pearl_teleport(player, dest)
		local function tp(p)
			if not p or not p:is_valid() then return end
			p:set_pos(dest)
			if jp.reset_fall then jp.reset_fall(p, dest.y) end
			mcl_damage.damage_player(p, 5, { type = "fall" })
		end
		if player:get_attach() and mcl_util.detach_object then
			mcl_util.detach_object(player, false, tp)
		else
			tp(player)
		end
	end

	local function is_gateway(node)
		return node.name == "mcl_portals:portal_gateway"
	end

	local pdef = core.registered_entities["mcl_throwing:ender_pearl_entity"]
	if pdef then
		pdef.on_step = function(self, dtime)
			local hit = throwable_step(self, dtime, is_gateway)
			if not hit then return end
			local vel = self.object:get_velocity()
			local player = self._thrower and core.get_player_by_name(self._thrower)
			if hit.type == "node" and hit.node.name == "ignore" then
				-- Unloaded area: no teleport (Mineclonia behaviour).
				self.object:remove()
				return
			end
			if hit.type == "node" and is_gateway(hit.node) then
				if player and mcl_portals and mcl_portals.gateway_teleport then
					mcl_portals.gateway_teleport(hit.under, player)
				end
				self.object:remove()
				return
			end
			if player and player:get_hp() > 0 then
				local oldpos = player:get_pos()
				pearl_teleport(player, pearl_destination(hit, vel))
				-- Java: 5% endermite chance at the thrower's old position.
				if math.random() < 0.05 and core.registered_entities["mobs_mc:endermite"] then
					core.add_entity(oldpos, "mobs_mc:endermite")
				end
			end
			target_hit(hit)
			self.object:remove()
		end
	end
end

------------------------------------------------------------------------
-- Explosions (item 19) and wind bursts (item 18)
------------------------------------------------------------------------

-- Total Blast Protection => explosion knockback resistance 0.15/level.
local function explosion_kb_resistance(obj)
	if not obj:is_player() then return 0 end
	local total = 0
	local inv = obj:get_inventory()
	for _, stack in ipairs(inv and inv:get_list("armor") or {}) do
		if not stack:is_empty() then
			total = total + mcl_enchanting.get_enchantment(stack, "blast_protection")
		end
	end
	return math.min(1, 0.15 * total)
end

-- Is the line from `a` to the explosion centre `b` blocked by a
-- collidable node?  Hits touching the centre itself are ignored (the
-- centre may lie on a block face, e.g. end crystals on obsidian).
local function ray_blocked(a, b)
	for pt in core.raycast(a, b, false, false) do
		if pt.type == "node" then
			local node = core.get_node(pt.under)
			local def = core.registered_nodes[node.name]
			if not def or def.walkable ~= false then
				local ip = pt.intersection_point
				if not ip or vector.distance(ip, b) > 1e-3 then
					return true
				end
			end
		end
	end
	return false
end

-- Java Explosion.getSeenPercent.
local function seen_percent(center, obj)
	local pos = obj:get_pos()
	local cb = obj:get_properties().collisionbox
	if not pos or not cb then return 0 end
	local x1, y1, z1 = pos.x + cb[1], pos.y + cb[2], pos.z + cb[3]
	local wx, wy, wz = cb[4] - cb[1], cb[5] - cb[2], cb[6] - cb[3]
	local dx, dy, dz = 1 / (wx * 2 + 1), 1 / (wy * 2 + 1), 1 / (wz * 2 + 1)
	if dx < 0 or dy < 0 or dz < 0 then return 0 end
	local gx = (1 - math.floor(1 / dx) * dx) / 2
	local gz = (1 - math.floor(1 / dz) * dz) / 2
	local seen, total = 0, 0
	local i = 0
	while i * dx <= 1 + 1e-9 do
		local k = i * dx
		local j = 0
		while j * dy <= 1 + 1e-9 do
			local l = j * dy
			local m_i = 0
			while m_i * dz <= 1 + 1e-9 do
				local m = m_i * dz
				local sample = vector.new(x1 + k * wx + gx, y1 + l * wy + 1e-3, z1 + m * wz + gz)
				if not ray_blocked(sample, center) then
					seen = seen + 1
				end
				total = total + 1
				m_i = m_i + 1
			end
			j = j + 1
		end
		i = i + 1
	end
	if total == 0 then return 0 end
	return seen / total
end

-- Captured before any temporary suppression in mcl_explosions.explode.
local engine_objects_inside_radius = core.objects_inside_radius

-- Java Explosion entity handling.
-- opts.damage (bool), opts.damage_type, opts.direct, opts.source,
-- opts.knockback_multiplier, opts.wind (wind charge: no damage, pushes
-- mobs/items, resets fall start height).
local function explosion_affect_entities(pos, power, opts)
	local diameter = power * 2
	if diameter <= 0 then return end
	local center_e = vector.offset(pos, 0, 1e-3, 0)
	local crystals = {}
	for obj in engine_objects_inside_radius(pos, diameter) do
		if obj ~= opts.direct and obj:is_valid() then
			local ent = obj:get_luaentity()
			local is_player = obj:is_player()
			if ent and ent.name == "mcl_end:crystal" then
				-- Java: an end crystal damaged by an explosion disappears
				-- without exploding (no chain reaction).
				if opts.damage and not ent._exploded then
					ent._exploded = true
					table.insert(crystals, obj)
				end
			else
				local immortal = tonumber(obj:get_armor_groups().immortal) or 0
				local eligible
				if is_player then
					eligible = obj:get_hp() > 0
				elseif ent then
					eligible = ent.is_mob or ent.tnt_knockback
						or (opts.damage and immortal == 0 and obj:get_hp() > 0)
						or (opts.wind and ent.name == "__builtin:item")
				end
				local feet = obj:get_pos()
				if eligible and feet then
					local dist = vector.distance(feet, pos) / diameter
					if dist <= 1 then
						local eye = vector.copy(feet)
						if is_player then
							eye.y = eye.y + (obj:get_properties().eye_height or 1.62)
						elseif ent and ent.is_mob and ent.get_eye_height then
							local ok, h = pcall(ent.get_eye_height, ent)
							if ok and h then eye.y = eye.y + h end
						end
						local dir = vector.subtract(eye, pos)
						local len = vector.length(dir)
						if len > 1e-6 then
							local exposure = seen_percent(center_e, obj)
							local impact = (1 - dist) * exposure
							if opts.damage then
								-- Not floored (Mineclonia floored it).
								local damage = (impact * impact + impact) / 2 * 7 * diameter + 1
								mcl_util.deal_damage(obj, damage, {
									type = opts.damage_type or "explosion",
									direct = opts.direct, source = opts.source,
									pos = vector.copy(pos), explosion_pos = vector.copy(pos),
								})
							end
							local kb = impact * (opts.knockback_multiplier or 1)
							if is_player or (ent and ent.is_mob) then
								kb = kb * (1 - explosion_kb_resistance(obj))
							end
							if kb > 0 and obj:is_valid() then
								local v = vector.multiply(dir, kb / len) -- b/t
								if is_player then
									jp.push(obj, v.x, v.y, v.z)
									if opts.wind and jp.reset_fall then
										jp.reset_fall(obj)
									end
								elseif ent and (ent.tnt_knockback or opts.wind) then
									obj:add_velocity(vector.multiply(v, 20))
								end
							end
						end
					end
				end
			end
		end
	end
	for _, c in ipairs(crystals) do
		core.after(0, function()
			if c:is_valid() then c:remove() end
		end)
	end
end
jp.explosion_affect_entities = explosion_affect_entities

if has_mod("mcl_explosions") and mcl_explosions and mcl_explosions.explode then
	-- Entities are handled by explosion_affect_entities (before blocks are
	-- removed, like Java).  Mineclonia's own entity pass (inside the local
	-- trace_explode) is suppressed by temporarily filtering
	-- core.objects_inside_radius for exactly (pos, 2*strength).
	wrap(mcl_explosions, "explode", function(orig, pos, strength, info, direct, source)
		info = info or {}
		if not pos or not strength then
			return orig(pos, strength, info, direct, source)
		end
		explosion_affect_entities(pos, strength, {
			damage = true, damage_type = info.damage_type,
			direct = direct, source = source,
		})
		local punch_radius = 2 * strength
		local px, py, pz = pos.x, pos.y, pos.z
		local saved = core.objects_inside_radius
		core.objects_inside_radius = function(p, r)
			if r == punch_radius and p and p.x == px and p.y == py and p.z == pz then
				return function() return nil end
			end
			return saved(p, r)
		end
		local ok, err = pcall(orig, pos, strength, info, direct, source)
		core.objects_inside_radius = saved
		if not ok then error(err, 0) end
	end, "mcl_explosions.explode")
end

-- End crystal: always power 6 at the crystal's base (Java), also when
-- punched without a puncher.
if has_mod("mcl_end") and mcl_explosions then
	local cdef = core.registered_entities["mcl_end:crystal"]
	if cdef then
		cdef.on_punch = function(self, puncher)
			if self._exploded then return true end
			self._exploded = true
			self._puncher = puncher
			local source
			if puncher and puncher:is_valid() then
				local reason = {}
				mcl_damage.from_punch(reason, puncher)
				mcl_damage.finish_reason(reason)
				source = reason.source
			end
			local obj = self.object
			local pos = obj:get_pos()
			-- Deferred removal lets the dragon notice the explosion.
			core.after(0.1, function()
				if obj:is_valid() then obj:remove() end
			end)
			if pos then
				-- Entity position = obsidian node centre; Java's centre is
				-- the crystal's bottom = top face of the block.
				mcl_explosions.explode(vector.offset(pos, 0, 0.5, 0), 6, {}, obj, source)
			end
			return true
		end
	else
		warn("mcl_end:crystal entity not found")
	end
end

------------------------------------------------------------------------
-- Wind charge (item 18)
------------------------------------------------------------------------

if has_mod("mcl_charges") and mcl_charges then
	-- Java: player/dispenser wind charges = explosion power 1.2 with a
	-- 1.22 knockback multiplier and no damage.  Other callers (e.g. the
	-- Wind Charged effect, radius 6) use power radius/2.
	function mcl_charges.wind_burst(pos, radius)
		local power, mult = 1.2, 1.22
		if radius and radius ~= 4 then
			power, mult = radius / 2, 1.0
		end
		explosion_affect_entities(pos, power, { damage = false, wind = true, knockback_multiplier = mult })
	end

	local function burst_effects(pos, node)
		local spawner = mcl_charges.wind_burst_spawner
		if spawner then
			local pr = PcgRandom(math.ceil(os.time() / 60 / 10))
			local v = vector.new(pr:next(-2, 2) / 10, 0, pr:next(-2, 2) / 10)
			v.y = pr:next(-9, -4) / 10
			local def = table.copy(spawner)
			def.minacc, def.maxacc = v, v
			def.minpos = vector.offset(pos, -0.8, 0.6, -0.8)
			def.maxpos = vector.offset(pos, 0.8, 0.8, 0.8)
			core.add_particlespawner(def)
		end
		core.sound_play("tnt_explode", { pos = pos, gain = 0.5, max_hear_distance = 30, pitch = 2.5 }, true)
		-- Block interactions of Mineclonia's hit_node.
		if node then
			local npos = vector.round(pos)
			if core.get_item_group(node.name, "bell") >= 1 and mcl_bells and mcl_bells.ring_once then
				mcl_bells.ring_once(npos)
			end
			if node.name == "mcl_end:chorus_flower" then
				core.dig_node(npos)
				if mcl_charges.chorus_flower_effects then mcl_charges.chorus_flower_effects(npos, 2) end
			elseif node.name == "mcl_end:chorus_flower_dead" then
				core.swap_node(npos, { name = "air" })
				core.add_item(npos, { name = "mcl_end:chorus_flower" })
				if mcl_charges.chorus_flower_effects then mcl_charges.chorus_flower_effects(npos, 2) end
			elseif node.name == "mcl_pottery_sherds:pot" then
				core.swap_node(npos, { name = "air" })
				for _ = 1, 4 do core.add_item(npos, { name = "mcl_core:brick" }) end
				if mcl_charges.pot_effects then mcl_charges.pot_effects(npos, 2) end
			end
		end
	end

	local function wind_hit_node_callback(self, npos)
		local node = core.get_node(npos)
		local bdef = core.registered_nodes[node.name]
		if bdef and bdef._on_wind_charge_hit then
			local h = core.hash_node_position(npos)
			self._jp_triggered = self._jp_triggered or {}
			if not self._jp_triggered[h] then
				self._jp_triggered[h] = true
				bdef._on_wind_charge_hit(npos, self)
			end
		end
	end

	local wdef = core.registered_entities["mcl_charges:wind_charge_flying"]
	if wdef then
		wdef.on_step = function(self, dtime)
			local obj = self.object
			local pos = obj:get_pos()
			if not pos then return end
			ensure_acceleration(obj, 0)
			local last = self._jp_last or pos
			self._jp_last = pos
			local owner = self._jp_owner
			if owner and not owner:is_valid() then owner = nil end
			local exclude = (not self._jp_left_owner) and owner or nil
			local hit = trace_projectile(obj, last, pos, { exclude = exclude })
			update_left_owner(self, pos, owner)
			-- Doors/buttons/etc. the charge flies through (Mineclonia behaviour).
			wind_hit_node_callback(self, vector.round(pos))
			if not hit then return end

			local burst_pos
			if hit.type == "node" then
				wind_hit_node_callback(self, hit.under)
				burst_pos = vector.add(hit.pos, vector.multiply(hit.normal, 0.05))
			else
				local target = hit.ref
				burst_pos = hit.pos
				-- Direct hit: 1 damage (Java), own damage type.
				local dmg = mcl_util.deal_damage(target, 1, {
					type = "wind_charge", direct = obj, source = owner,
				})
				if target:is_player() and target:is_valid() then
					local v = obj:get_velocity() or vector.zero()
					v.y = 0
					mcl_player.player_knockback(target, obj, vector.normalize(v), nil, dmg or 1)
				end
			end
			mcl_charges.wind_burst(burst_pos, 4)
			burst_effects(burst_pos, hit.type == "node" and hit.node or nil)
			obj:remove()
		end
	else
		warn("mcl_charges:wind_charge_flying entity not found")
	end

	if core.registered_items["mcl_charges:wind_charge"] then
		local function throw_charge(itemstack, placer, pointed_thing)
			if pointed_thing and pointed_thing.type == "node" then
				local rc = mcl_util.call_on_rightclick(itemstack, placer, pointed_thing)
				if rc then return rc end
			end
			if not placer or not placer:is_player() then return end
			if jp.item_cooldown(placer, WIND_CHARGE_KEY) > 0 then return itemstack end
			jp.set_item_cooldown(placer, WIND_CHARGE_KEY, WIND_CHARGE_COOLDOWN)
			-- Java: spawned at the eye, 1.5 b/t, inaccuracy 1, shooter motion.
			local pos = jp.eye_pos(placer)
			local obj = core.add_entity(pos, "mcl_charges:wind_charge_flying")
			if not obj or not obj:get_pos() then return end
			obj:set_velocity(shoot_velocity(placer, 0, THROW_SPEED, INACCURACY))
			obj:set_acceleration(vector.zero())
			local ent = obj:get_luaentity()
			ent.posthrow = placer:get_pos()
			ent._jp_owner = placer
			ent._jp_last = pos
			core.sound_play("mcl_throwing_throw", { pos = pos, gain = 0.4, max_hear_distance = 16 }, true)
			if not is_creative(placer) then
				itemstack:take_item()
			end
			return itemstack
		end
		core.override_item("mcl_charges:wind_charge", {
			on_place = throw_charge,
			on_secondary_use = throw_charge,
		})
	end
end

------------------------------------------------------------------------
-- Splash and lingering potions (items 20, 21 partially)
------------------------------------------------------------------------

if mcl_potions and mcl_potions.detect_hit then
	local function potion_color(idef)
		local img = idef and idef.inventory_image or ""
		return img:match("%[multiply:(#%x+)") or "#ffffff"
	end

	-- Physics shared by splash and lingering bottles thrown by players
	-- (witches and dispensers keep Mineclonia's physics).
	local function potion_physics(self, dtime)
		local obj = self.object
		if not obj:get_pos() then return end
		if self._jp_java == nil then
			self._jp_java = type(self._thrower) == "string"
		end
		if self._jp_java then
			ensure_acceleration(obj, -ARROW_GRAVITY)
			apply_drag(obj, DRAG, dtime)
		end
	end

	-- Java ThrownPotion throw: 0.5 b/t, pitch -20 degrees, inaccuracy 1.
	local function spawn_potion(player, entname)
		local pos = shoot_pos(player)
		local obj = core.add_entity(pos, entname)
		if not obj or not obj:get_pos() then return nil end
		obj:set_velocity(shoot_velocity(player, POTION_PITCH_OFFSET, POTION_SPEED, INACCURACY))
		obj:set_acceleration(vector.new(0, -ARROW_GRAVITY, 0))
		core.sound_play("mcl_throwing_throw", { pos = pos, gain = 0.4, max_hear_distance = 16 }, true)
		obj:get_luaentity()._jp_java = true
		return obj
	end

	if mcl_potions.throw_splash then
		wrap(mcl_potions, "throw_splash", function(orig, potionname, dir, pos, thrower, potency, plus)
			local player = resolve_player(thrower)
			if not player or not player:is_player() or not core.registered_items[potionname] then
				return orig(potionname, dir, pos, thrower, potency, plus) -- witches etc.
			end
			local obj = spawn_potion(player, potionname .. "_flying")
			if not obj then return end
			local ent = obj:get_luaentity()
			ent._thrower = thrower
			ent._potency = potency
			ent._plus = plus
			ent._effect_list = core.registered_items[potionname]._effect_list
		end, "mcl_potions.throw_splash")
	end

	-- Direct hit target of a splash potion (Java: proximity 1).
	local function direct_hit_target(obj, pos, vel)
		local ent = obj:get_luaentity()
		local thrower = ent and resolve_player(ent._thrower)
		local dst = vector.add(pos, vector.multiply(vel, 0.05))
		local raycast = (mcl_attachments and mcl_attachments.raycast)
			and mcl_attachments.raycast(pos, dst, true, false) or core.raycast(pos, dst, true, false)
		for pt in raycast do
			if pt.type == "object" and pt.ref ~= obj and jp.is_living(pt.ref) then
				if not (thrower and pt.ref == thrower and ent and not ent._exited_thrower) then
					return pt.ref
				end
			elseif pt.type == "node" then
				break
			end
		end
		return nil
	end

	-- Java ThrownPotion.applySplash.
	local function apply_splash(pos, itemname, potency, plus, thrower, direct, effect_list)
		local idef = core.registered_items[itemname]
		if not idef then return end
		effect_list = effect_list or idef._effect_list or {}
		local base = idef._base_potion
		local pdef = base and mcl_potions.registered_potions and mcl_potions.registered_potions[base]
		local custom = pdef and pdef.custom_effect
		local power = potency + 1
		for obj in core.objects_inside_radius(pos, 4) do
			if obj:is_valid() and jp.is_living(obj) and obj:get_hp() > 0 then
				local feet = obj:get_pos()
				local d = vector.distance(feet, pos)
				-- Java: box inflated 4 horizontally / 2 vertically, dist < 4.
				local cb = obj:get_properties().collisionbox or { 0, 0, 0, 0, 0, 0 }
				local in_y = pos.y >= feet.y + cb[2] - 2.1 and pos.y <= feet.y + cb[5] + 2.1
				if (d < 4 and in_y) or obj == direct then
					local p = (obj == direct) and 1 or (1 - d / 4)
					for ename, details in pairs(effect_list) do
						local level = mcl_potions.level_from_details(details, potency)
						local dur = mcl_potions.duration_from_details(details, potency, plus)
						local ticks = math.floor(p * dur * TICKS + 0.5)
						if ticks > 20 then
							mcl_potions.give_effect_by_level(ename, obj, level, ticks / TICKS)
						end
					end
					if custom then
						local amp_mult = math.pow(2, power - 1)
						if base == "mcl_potions:healing" then
							local hp = math.floor(p * 4 * amp_mult + 0.5)
							if hp >= 1 then mcl_potions.healing_func(obj, hp, thrower) end
						elseif base == "mcl_potions:harming" then
							local hp = math.floor(p * 6 * amp_mult + 0.5)
							if hp >= 1 then mcl_potions.healing_func(obj, -hp, thrower) end
						else
							custom(obj, p * power, plus, thrower)
						end
					end
				end
			end
		end
	end

	local function make_splash_step(itemname)
		local idef = core.registered_items[itemname]
		local color = potion_color(idef)
		local instant = idef and (not idef._effect_list or next(idef._effect_list) == nil)
		local texture = instant and "mcl_particles_instant_effect.png" or "mcl_particles_effect.png"
		return function(self, dtime, moveresult)
			local obj = self.object
			local pos = obj:get_pos()
			if not pos then return end
			potion_physics(self, dtime)
			local velocity = obj:get_velocity()
			local val = mcl_potions.detect_hit(obj, pos, moveresult, velocity)
			if not val then return end
			local direct = direct_hit_target(obj, pos, velocity)
			if val.target and mcl_target and mcl_target.hit then
				mcl_target.hit(val.target)
			end
			core.sound_play("mcl_potions_breaking_glass", { pos = pos, max_hear_distance = 16, gain = 1 })
			local d = 0.1
			core.add_particlespawner({
				amount = 50, time = 0.1,
				minpos = { x = pos.x - d, y = pos.y, z = pos.z - d },
				maxpos = { x = pos.x + d, y = pos.y + d, z = pos.z + d },
				minvel = { x = -2, y = 0, z = -2 }, maxvel = { x = 2, y = 2, z = 2 },
				minacc = { x = 0, y = 0, z = 0 }, maxacc = { x = 0, y = 0, z = 0 },
				minexptime = 0.5, maxexptime = 1.25, minsize = 1, maxsize = 2,
				collisiondetection = true, vertical = false,
				texture = texture .. "^[colorize:" .. color .. ":127",
			})
			apply_splash(pos, itemname, self._potency or 0, self._plus or 0,
				resolve_player(self._thrower), direct, self._effect_list)
			obj:remove()
		end
	end

	local splash_count, ling_count = 0, 0
	-- Collect first: core.override_item must not run while iterating
	-- core.registered_items.
	local potion_items = {}
	for itemname, idef in pairs(core.registered_items) do
		if core.get_item_group(itemname, "splash_potion") > 0
				or core.get_item_group(itemname, "ling_potion") > 0 then
			potion_items[itemname] = idef
		end
	end
	for itemname, idef in pairs(potion_items) do
		local entname = itemname .. "_flying"
		local edef = core.registered_entities[entname]
		if edef and core.get_item_group(itemname, "splash_potion") > 0 then
			if itemname == "mcl_potions:water_splash" then
				-- Keep Mineclonia's water logic; only fix the physics.
				wrap(edef, "on_step", function(orig, self, dtime, moveresult)
					potion_physics(self, dtime)
					return orig(self, dtime, moveresult)
				end, entname .. ".on_step")
			else
				edef.on_step = make_splash_step(itemname)
			end
			splash_count = splash_count + 1
		elseif edef and core.get_item_group(itemname, "ling_potion") > 0 then
			-- Lingering: Java throw and flight physics; the cloud itself is
			-- Mineclonia's (item 21 not changed, see report).
			wrap(edef, "on_step", function(orig, self, dtime, moveresult)
				potion_physics(self, dtime)
				return orig(self, dtime, moveresult)
			end, entname .. ".on_step")
			local function throw_lingering(item, placer, pointed_thing)
				local rc = mcl_util.call_on_rightclick(item, placer, pointed_thing)
				if rc then return rc end
				if not placer or not placer:is_player() then return end
				local obj = spawn_potion(placer, entname)
				if not obj then return end
				local ent = obj:get_luaentity()
				local meta = item:get_meta()
				ent._thrower = placer:get_player_name()
				ent._potency = meta:get_int("mcl_potions:potion_potent")
				ent._plus = meta:get_int("mcl_potions:potion_plus")
				ent._effect_list = idef._effect_list
				if not is_creative(placer) then
					item:take_item()
				end
				return item
			end
			core.override_item(itemname, { on_place = throw_lingering, on_secondary_use = throw_lingering })
			ling_count = ling_count + 1
		end
	end
	core.log("info", "[mcl_java_pvp] patched " .. splash_count .. " splash and "
		.. ling_count .. " lingering potions")
end
