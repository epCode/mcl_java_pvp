-- Shields (Java 1.21).
--
--  * Blocking arc: the damage source must be in front of the player,
--    measured horizontally (dot(source->player, horizontal view) < 0).
--    Mineclonia's SHIELD_BLOCK_COSINE passed degrees to math.cos, giving a
--    ~233 degree arc that also depended on pitch.
--  * A raised shield only blocks after 5 ticks (0.25 s).
--  * Blockable: any damage with a source position except the types Java
--    tags bypasses_shield (all bypasses_armor types, fire, lava, cactus,
--    berry bush, falling anvils...).  Mineclonia blocked "generic" damage
--    and did not block fireballs, wither skulls, thorns or wind charges.
--  * Durability: 1 + floor(damage) when damage >= 3 (Mineclonia ceil(d)),
--    computed from the damage before armor/Resistance.
--  * Axes disable the shield for 5 s (100 ticks) - unchanged.

local jp = mcl_java_pvp

jp.SHIELD_DELAY = 0.25

mcl_shields.types = {
	mob = true,
	player = true,
	arrow = true,
	trident = true,
	explosion = true,
	fireball = true,
	wither_skull = true,
	spit = true,
	thorns = true,
	fireworks = true,
	wind_charge = true,
	mace_smash = true,
}

-- Track when each player raised their shield.
local raised_at = jp.player_table()

core.register_globalstep(function()
	local now = jp.now()
	for player in mcl_util.connected_players() do
		local st = mcl_shields.players[player]
		local blocking = st and st.blocking or 0
		if blocking > 0 then
			raised_at[player] = raised_at[player] or now
		else
			raised_at[player] = nil
		end
	end
end)

local orig_is_blocking = mcl_shields.is_blocking

-- Shield raised long enough to block?
function mcl_shields.is_blocking(obj)
	local hand, stack = orig_is_blocking(obj)
	if not hand then return end
	if not jp.is_csm(obj) then
		local t = raised_at[obj]
		if not t or jp.now() - t < jp.SHIELD_DELAY then return end
	end
	return hand, stack
end

-- Horizontal dot product of (attacker -> player) with the player's
-- horizontal view direction.  Negative = attacker in front.
function mcl_shields.find_angle(attack_pos, obj)
	if not attack_pos then return end
	local pos = obj:get_pos()
	local dx, dz = pos.x - attack_pos.x, pos.z - attack_pos.z
	local len = math.sqrt(dx * dx + dz * dz)
	if len < 1e-6 then return -1 end
	local yaw = obj:get_look_horizontal()
	local vx, vz = -math.sin(yaw), math.cos(yaw)
	return (dx * vx + dz * vz) / len
end

local function source_position(reason)
	if reason.pos then return reason.pos end
	if reason.explosion_pos then return reason.explosion_pos end
	local damager = reason.direct
	local entity = damager and damager:get_luaentity()
	if entity then
		if entity._saved_shooter_pos then
			-- Java uses the projectile's own position for the angle; Mineclonia
			-- projectiles may already be removed, fall back to the shooter.
			local p = damager:get_pos()
			return p or entity._saved_shooter_pos
		end
	end
	if damager and damager.is_valid and damager:is_valid() then
		return damager:get_pos()
	end
	local source = reason.source
	if source and source.is_valid and source:is_valid() then
		return source:get_pos()
	end
end

function mcl_shields.can_block(obj, dpos_or_dot, reason)
	if not obj or not obj:is_player() then return false, "non-player" end
	local blocking, shieldstack = mcl_shields.is_blocking(obj)
	if not blocking then return false, "no-shield" end

	if reason then
		if not mcl_shields.types[reason.type] then return false, "non-blockable" end
		if reason.flags and reason.flags.bypasses_armor then return false, "non-blockable" end
		if not dpos_or_dot then
			dpos_or_dot = source_position(reason)
		end
	end

	if dpos_or_dot then
		local dot
		if type(dpos_or_dot) == "number" then
			dot = dpos_or_dot
		else
			dot = mcl_shields.find_angle(dpos_or_dot, obj)
		end
		if dot >= 0 then return false, "non-frontal" end
	end

	return true, { blocking, shieldstack }, dpos_or_dot
end

-- Java: if damage >= 3, the shield loses 1 + floor(damage).
function mcl_shields.add_wear(obj, damage, blockstack, n)
	if not obj or not obj:is_player() then return false, "non-player" end
	if core.is_creative_enabled(obj:get_player_name()) then return false, "creative" end
	if damage and damage < 3 then return false, "threshold" end
	if n and n <= 0 then return false, "use-count" end

	local blocking, shieldstack
	if blockstack then
		blocking, shieldstack = blockstack[1], blockstack[2]
	else
		blocking, shieldstack = mcl_shields.is_blocking(obj)
	end
	if not blocking then return false, "no-shield" end

	local uses = n or (damage and (1 + math.floor(damage))) or 1
	mcl_util.use_item_durability(shieldstack, uses)
	if blocking == 2 then
		obj:set_wielded_item(shieldstack)
	else
		obj:get_inventory():set_stack("offhand", 1, shieldstack)
		mcl_inventory.update_inventory_formspec(obj)
	end
	return true
end

-- Replace Mineclonia's shield damage modifier (priority 0, i.e. in an
-- undefined order relative to armor; -20 in newer Mineclonia) with one
-- that runs before invulnerability and armor, like Java.  Both versions
-- block with Mineclonia's own arc and raise rules, so keeping it would
-- block hits this one lets through.
jp.remove_modifier_from("mcl_shields/init.lua", { 0, -20 })

mcl_damage.register_modifier(function(obj, damage, reason)
	if not obj:is_player() or damage <= 0 then return end
	local can_block, stack, dpos = mcl_shields.can_block(obj, nil, reason)
	if not (can_block and dpos) then return end

	local direct = reason.direct
	-- Axes disable the shield (melee hits only: the direct attacker wields it).
	if direct and direct:is_valid() and (reason.type == "player" or reason.type == "mob") then
		local wielded = mcl_util.get_wielditem(direct)
		if core.get_item_group(wielded:get_name(), "axe") > 0 then
			mcl_shields.disable_player_shield(obj)
		end
	end
	mcl_shields.add_wear(obj, damage, stack)
	if direct and direct:is_valid() then
		local entity = direct:get_luaentity()
		if entity and entity.is_mob and obj:is_valid() then
			entity:shield_impact(obj, reason)
		end
	end
	core.sound_play({ name = "mcl_block" }, { pos = obj:get_pos(), max_hear_distance = 16 }, true)
	jp.register_blocked_hit(obj)
	reason.jp_blocked = true
	return 0
end, -45)
