-- Status effects and potions (Java Edition 1.21).
--
-- Java reference: MobEffectInstance (update/hidden effects/tick),
-- PoisonMobEffect, RegenerationMobEffect, WitherMobEffect,
-- SaturationMobEffect, AbsorptionMobEffect, HealOrHarmMobEffect and
-- Potions.java (durations).
--
-- What this file changes:
--   * potion durations: Poison 0:45/1:30/II 0:21.6, Regeneration
--     0:45/1:30/II 0:22.5, Weakness 1:30/4:00, Slow Falling 1:30/4:00,
--     Turtle Master 0:20/0:40/II 0:20, Luck 5:00;
--   * no Weakness II, Luck II/+ and Decay II brewing (not in Java);
--   * effect stacking: a stronger effect uses its own duration and the
--     weaker one is kept as a hidden effect that resumes afterwards; a
--     weaker but longer effect is stored as hidden too;
--   * Poison/Regeneration/Wither intervals 25>>amp, 50>>amp, 40>>amp ticks
--     and tick phase (Java fires when remaining duration % interval == 0,
--     e.g. a 45 s Regeneration heals immediately);
--   * Absorption ends when its pool is used up;
--   * Saturation: +(amp+1) food and +2*(amp+1) saturation every tick;
--   * Instant Health/Harming 4<<amp / 6<<amp at level III+;
--   * Wither effect damage uses the "wither" damage type;
--   * Strength/Weakness tooltips show Java's +3/-4 attack damage per level
--     (the damage itself is done by melee.lua).

local jp = mcl_java_pvp
local TICK = jp.TICK
local S = core.get_translator("mcl_java_pvp")

local function warn(msg)
	core.log("warning", "[mcl_java_pvp] effects.lua: " .. msg)
end

if not mcl_potions or not mcl_potions.registered_effects then
	warn("mcl_potions not found, effect changes disabled")
	return
end

local reg = mcl_potions.registered_effects

------------------------------------------------------------------------
-- 10. Potion durations
------------------------------------------------------------------------

-- Java durations in seconds: {base, long (redstone), strong (glowstone)}.
local JAVA_DURATIONS = {
	["mcl_potions:poison"]        = { poison = { 45, 90, 21.6 } },
	["mcl_potions:regeneration"]  = { regeneration = { 45, 90, 22.5 } },
	["mcl_potions:weakness"]      = { weakness = { 90, 240 } },
	["mcl_potions:slow_falling"]  = { slow_falling = { 90, 240 } },
	["mcl_potions:turtle_master"] = { resistance = { 20, 40, 20 }, slowness = { 20, 40, 20 } },
	["mcl_potions:luck"]          = { luck = { 300 } },
}

-- Potions without a level II variant in Java (glowstone does nothing).
local NO_POTENT = {
	["mcl_potions:weakness"] = true,
	["mcl_potions:luck"] = true,
	["mcl_potions:withering"] = true, -- Decay is Bedrock-only; no Decay II at least
}
-- Potions without a long variant in Java.
local NO_PLUS = {
	["mcl_potions:luck"] = true,
}

local function base_potion_of(name, def)
	return def._base_potion or name
end

-- The _effect_list of a drinkable potion is shared with its splash,
-- lingering and tipped arrow items; mcl_potions.registered_potions holds a
-- deep copy.  Annotate both.
local function annotate_effect_list(list, durs)
	if type(list) ~= "table" then return end
	for effect, d in pairs(durs) do
		local details = list[effect]
		if type(details) == "table" then
			details._jp_durs = d
		end
	end
end

local registered_potions = mcl_potions.registered_potions or {}
for name, def in pairs(core.registered_items) do
	if def._effect_list then
		local base = base_potion_of(name, def)
		if JAVA_DURATIONS[base] then
			annotate_effect_list(def._effect_list, JAVA_DURATIONS[base])
		end
	end
end
for name, pdef in pairs(registered_potions) do
	if JAVA_DURATIONS[name] then
		annotate_effect_list(pdef._effect_list, JAVA_DURATIONS[name])
	end
	-- Brewing (glowstone / redstone) consults registered_potions.
	if NO_POTENT[name] then pdef.has_potent = false end
	if NO_PLUS[name] then pdef.has_plus = false end
end

-- Creative inventory "virtual items": drop the variants Java does not have.
for name, def in pairs(core.registered_items) do
	local base = base_potion_of(name, def)
	if (NO_POTENT[base] or NO_PLUS[base]) and type(def._get_all_virtual_items) == "function" then
		local old = def._get_all_virtual_items
		rawset(def, "_get_all_virtual_items", function(...)
			local res = old(...)
			if type(res) ~= "table" then return res end
			for cat, list in pairs(res) do
				local kept = {}
				for _, s in ipairs(list) do
					local meta = ItemStack(s):get_meta()
					local bad = (NO_POTENT[base] and meta:get_int("mcl_potions:potion_potent") > 0)
						or (NO_PLUS[base] and meta:get_int("mcl_potions:potion_plus") > 0)
					if not bad then table.insert(kept, s) end
				end
				res[cat] = kept
			end
			return res
		end)
		if def.has_potent ~= nil and NO_POTENT[base] then rawset(def, "has_potent", false) end
		if def.has_plus ~= nil and NO_PLUS[base] then rawset(def, "has_plus", false) end
	end
end

-- Mineclonia: dur * (8/3)^plus / 2^potency.  Java durations are not a
-- fixed ratio, so annotated effects use the table above.
do
	local orig = mcl_potions.duration_from_details
	function mcl_potions.duration_from_details(details, potency, plus, attenuation)
		local j = details and details._jp_durs
		if not j or not details.dur_variable then
			return orig(details, potency, plus, attenuation)
		end
		potency, plus = potency or 0, plus or 0
		local dur
		if potency > 0 and details.uses_level and j[3] then
			-- Level III+ only exist via commands; extrapolate geometrically.
			dur = j[3] / math.pow(j[1] / j[3], potency - 1)
		elseif plus > 0 and j[2] then
			dur = j[2] * math.pow(mcl_potions.PLUS_FACTOR or 8 / 3, plus - 1)
		else
			dur = j[1]
		end
		return dur * (attenuation or 1)
	end
end

------------------------------------------------------------------------
-- 13. Poison / Regeneration / Wither interval and phase
------------------------------------------------------------------------

-- Java: shouldApplyEffectTickThisTick(duration, amp) =
--   k = base >> amp; k > 0 ? duration % k == 0 : true
local INTERVAL_BASE = { poison = 25, regeneration = 50, withering = 40 }

local function level_of(name, factor)
	local def = reg[name]
	if not def or not def.uses_factor or type(factor) ~= "number" then return 1 end
	local ok, l = pcall(def.factor_to_level, factor)
	l = ok and tonumber(l) or 1
	if l ~= l or l < 1 then l = 1 end -- NaN / bogus factor
	if l > 255 then l = 255 end
	return l
end

local function remaining(vals)
	if vals.dur == math.huge then return math.huge end
	return (tonumber(vals.dur) or 0) - (vals.timer or 0)
end

-- Set the hit step to Java's interval and phase the hit timer so that the
-- effect fires on ticks where (remaining ticks) % k == 0.
local function align_timer(name, vals)
	local base = INTERVAL_BASE[name]
	if not base or not vals then return end
	local level = level_of(name, vals.factor)
	local k = math.max(1, math.floor(base / math.pow(2, level - 1)))
	vals.step = k * TICK
	if vals.dur == math.huge then
		-- Java uses entity.tickCount for infinite effects; any phase will do.
		vals.hit_timer = vals.hit_timer or 0
		return
	end
	local d = math.floor(remaining(vals) / TICK + 0.5)
	local t0 = d % k
	-- mcl_potions adds dtime before testing hit_timer >= step, so the first
	-- hit happens t0 ticks after this one.
	vals.hit_timer = vals.step - (t0 + 1) * TICK + 1e-6
end

-- Wither effect damage type (Java "wither", not "magic").
if reg.withering then
	reg.withering.on_hit_timer = function(object)
		if object:is_player() or object:get_luaentity() then
			mcl_util.deal_damage(object, 1, { type = "wither" })
		end
	end
end

------------------------------------------------------------------------
-- 11. Effect stacking with hidden effects (MobEffectInstance.update)
------------------------------------------------------------------------

-- A hidden effect is a plain table {factor, level, rem (seconds), hidden}
-- stored in the active effect's data as _jp_hidden (it is serialized with
-- the effect by mcl_potions).  Hidden effects tick down concurrently.

-- Effects excluded from hidden-effect handling: Absorption has its own
-- pool semantics (on_reject).
local NO_HIDDEN = { absorption = true }
-- Effects whose on_end/on_start pair is not idempotent within a step
-- (Health Boost: on_end would clamp HP to 20 before the hidden level's
-- max health is applied) are swapped one step early instead.
local PREEMPTIVE = { health_boost = true }

local orig_give = mcl_potions.give_effect
local tracked = {} -- vals table -> {object = obj, name = effect}

local function track(object, name, vals)
	if vals and vals._jp_hidden then
		tracked[vals] = { object = object, name = name }
	end
end

local function copy_inst(i)
	return { factor = i.factor, level = i.level, rem = i.rem, hidden = i.hidden }
end

-- MobEffectInstance.update(other) on plain tables.
local function java_update(inst, other)
	if other.level > inst.level then
		if other.rem < inst.rem then
			inst.hidden = copy_inst(inst)
		end
		inst.factor, inst.level, inst.rem = other.factor, other.level, other.rem
	elseif inst.rem < other.rem then
		if other.level == inst.level then
			inst.rem = other.rem
		elseif not inst.hidden then
			inst.hidden = { factor = other.factor, level = other.level, rem = other.rem }
		else
			java_update(inst.hidden, other)
		end
	end
end

local function dur_arg(rem)
	return rem == math.huge and "INF" or rem
end

local function after_apply(name, object, hidden)
	local vals = mcl_potions.get_effect(object, name)
	if not vals then return nil end
	if hidden ~= nil then
		vals._jp_hidden = hidden or nil
	end
	align_timer(name, vals)
	track(object, name, vals)
	return vals
end

function mcl_potions.give_effect(name, object, factor, duration, no_particles)
	local def = reg[name]
	if not def or not object then
		return orig_give(name, object, factor, duration, no_particles)
	end
	local present = mcl_potions.get_effect(object, name)
	if not present or not def.uses_factor or NO_HIDDEN[name] or type(factor) ~= "number" then
		local r = orig_give(name, object, factor, duration, no_particles)
		if r then after_apply(name, object) end
		return r
	end

	local new_dur = duration == "INF" and math.huge or tonumber(duration) or 0
	local cur = {
		factor = present.factor,
		level = level_of(name, present.factor),
		rem = remaining(present),
		hidden = present._jp_hidden,
	}
	local new = { factor = factor, level = level_of(name, factor), rem = new_dur }

	if new.level > cur.level then
		-- Stronger: uses its own duration; the old one is hidden only if it
		-- would have outlasted the new one (otherwise discarded, but its
		-- own hidden chain is kept).
		local hidden = cur.hidden
		if new.rem < cur.rem then
			hidden = copy_inst(cur)
		end
		local r = orig_give(name, object, factor, duration, no_particles)
		local vals = mcl_potions.get_effect(object, name)
		if r and vals then
			vals.dur = new_dur
			vals.timer = 0
			after_apply(name, object, hidden or false)
		end
		return r
	elseif cur.rem < new.rem then
		if new.level == cur.level then
			-- Same level, longer: refresh (Mineclonia does the same).
			local r = orig_give(name, object, factor, duration, no_particles)
			if r then after_apply(name, object) end
			return r
		end
		-- Weaker but longer: remember it as a hidden effect.
		if not cur.hidden then
			present._jp_hidden = { factor = new.factor, level = new.level, rem = new.rem }
		else
			java_update(cur.hidden, new)
		end
		track(object, name, present)
		return true
	end
	-- Not stronger and not longer: Java changes nothing.  Same level goes
	-- through Mineclonia for its side effects (remaining time unchanged).
	local r = orig_give(name, object, factor, duration, no_particles)
	if r then after_apply(name, object) end
	return r
end

-- Advance a hidden chain by dtime and drop expired links.
local function tick_chain(h, dtime)
	local first, prev = h, nil
	local node = h
	while node do
		if node.rem ~= math.huge then node.rem = node.rem - dtime end
		if node.rem <= 0 then
			if prev then prev.hidden = node.hidden else first = node.hidden end
		else
			prev = node
		end
		node = node.hidden
	end
	return first
end

-- Make hidden instance h the active effect (Java: setDetailsFrom(hidden)).
local function activate_hidden(object, name, h, no_particles, vals)
	if vals then
		-- Preemptive swap: make the current effect weaker than h and
		-- expired so mcl_potions replaces it in place (on_start with the
		-- new factor, HUD and CSM status update) without on_end.
		local old_factor, old_dur = vals.factor, vals.dur
		vals.factor = reg[name].inv_factor and math.huge or -math.huge
		vals.dur = vals.timer
		local r = orig_give(name, object, h.factor, dur_arg(h.rem), no_particles)
		if not r then
			vals.factor, vals.dur = old_factor, old_dur
			return
		end
	else
		if not orig_give(name, object, h.factor, dur_arg(h.rem), no_particles) then
			return
		end
	end
	local nv = mcl_potions.get_effect(object, name)
	if nv then
		nv.dur = h.rem
		nv.timer = 0
		after_apply(name, object, h.hidden or false)
	end
end

core.register_globalstep(function(dtime)
	for vals, t in pairs(tracked) do
		local obj, name = t.object, t.name
		if not obj or not obj:get_pos() then
			tracked[vals] = nil
		else
			local cur = mcl_potions.get_effect(obj, name)
			if cur == vals then
				if vals._jp_hidden then
					vals._jp_hidden = tick_chain(vals._jp_hidden, dtime)
				end
				if not vals._jp_hidden then
					tracked[vals] = nil
				elseif PREEMPTIVE[name] and remaining(vals) <= dtime + 1e-6 then
					tracked[vals] = nil
					activate_hidden(obj, name, vals._jp_hidden, vals.no_particles, vals)
				end
			else
				tracked[vals] = nil
				-- The effect ran out this step (not cleared by milk/death/
				-- commands): the hidden effect takes over.
				local h = vals._jp_hidden and tick_chain(vals._jp_hidden, dtime)
				if not cur and h and (vals.timer or 0) >= (tonumber(vals.dur) or 0) - 1e-9
						and mcl_util.get_hp(obj) > 0 then
					activate_hidden(obj, name, h, vals.no_particles, nil)
				end
			end
		end
	end
end)

-- Re-track hidden effects restored from saved data.
local function retrack(object)
	if not object then return end
	for name in pairs(reg) do
		local v = mcl_potions.get_effect(object, name)
		if v and v._jp_hidden then track(object, name, v) end
	end
end

for _, fname in ipairs({ "_load_player_effects", "_load_entity_effects" }) do
	local orig = mcl_potions[fname]
	if type(orig) == "function" then
		mcl_potions[fname] = function(x, ...)
			local r = orig(x, ...)
			local obj = x
			if type(x) == "table" and x.object then obj = x.object end
			pcall(retrack, obj)
			return r
		end
	else
		warn("mcl_potions." .. fname .. " not found")
	end
end

------------------------------------------------------------------------
-- 14. Absorption ends when the pool is used up (Java >= 1.20.2)
-- 15. Saturation: FoodData.eat(amp + 1, 1.0) every tick
------------------------------------------------------------------------

local function food_eat(player, n, sat)
	if jp.food_eat then return jp.food_eat(player, n, sat) end
	if not (mcl_hunger and mcl_hunger.active) then return end
	local food = math.min(20, mcl_hunger.get_hunger(player) + n)
	mcl_hunger.set_hunger(player, food, true)
	mcl_hunger.set_saturation(player, math.min(mcl_hunger.get_saturation(player) + sat, food))
end

if reg.saturation then
	reg.saturation.on_step = function(dtime, object, factor)
		if not object:is_player() then return end
		local vals = mcl_potions.get_effect(object, "saturation")
		if not vals then return end
		local n = level_of("saturation", factor)
		vals._jp_acc = (vals._jp_acc or 0) + dtime
		local count = 0
		while vals._jp_acc >= TICK - 1e-6 and count < 10 do
			vals._jp_acc = vals._jp_acc - TICK
			count = count + 1
			food_eat(object, n, n * 2)
		end
		if count >= 10 then vals._jp_acc = 0 end
	end
	reg.saturation.get_tt = function(factor)
		local n = level_of("saturation", factor)
		return S("+@1 food and +@2 saturation per tick", n, 2 * n)
	end
end

core.register_globalstep(function()
	for _, player in ipairs(core.get_connected_players()) do
		local a = mcl_potions.get_effect(player, "absorption")
		if a and type(a.absorb) == "number" and a.absorb <= 0 then
			mcl_potions.clear_effect(player, "absorption")
		end
	end
end)

------------------------------------------------------------------------
-- 12. Instant Health / Harming: 4 << amp and 6 << amp
------------------------------------------------------------------------

do
	local orig_heal = mcl_potions.healing_func
	local function is_int(x) return x == math.floor(x) end
	if type(orig_heal) == "function" then
		function mcl_potions.healing_func(object, hp, source)
			-- Only potion effects (potions.lua passes 4*level / -6*level);
			-- leave /effect heal and other callers alone.
			local info = debug.getinfo(2, "S")
			if type(hp) == "number" and info and info.source
					and info.source:sub(-#"mcl_potions/potions.lua") == "mcl_potions/potions.lua" then
				if hp > 0 and is_int(hp / 4) and hp / 4 >= 3 then
					hp = 4 * math.pow(2, hp / 4 - 1)
				elseif hp < 0 and is_int(-hp / 6) and -hp / 6 >= 3 then
					hp = -6 * math.pow(2, -hp / 6 - 1)
				end
			end
			return orig_heal(object, hp, source)
		end
	end

	local function tt(mult, sign)
		return function(level)
			local amount
			if is_int(level) and level >= 1 then
				amount = mult * math.pow(2, level - 1)
			else
				amount = mult * level -- attenuated (lingering/tipped) display
			end
			return S(sign .. "@1 HP", amount)
		end
	end
	for name, def in pairs(core.registered_items) do
		local base = def._base_potion or name
		if def._dynamic_tt and base == "mcl_potions:healing" then
			rawset(def, "_dynamic_tt", tt(4, "+"))
		elseif def._dynamic_tt and base == "mcl_potions:harming" then
			rawset(def, "_dynamic_tt", tt(6, "-"))
		end
	end
end

------------------------------------------------------------------------
-- Strength / Weakness tooltips (Java attack damage modifiers)
------------------------------------------------------------------------

if reg.strength then
	reg.strength.get_tt = function(factor)
		return S("+@1 attack damage", 3 * level_of("strength", factor))
	end
end
if reg.weakness then
	reg.weakness.get_tt = function(factor)
		return S("-@1 attack damage", 4 * level_of("weakness", factor))
	end
end
