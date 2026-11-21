-- mcl_java_pvp: make Mineclonia PvP behave like Minecraft Java Edition 1.21.
--
-- Nothing in Mineclonia itself is edited.  Every change is made by
-- overriding item definitions, replacing Mineclonia callbacks/damage
-- modifiers at load time, or wrapping public functions.  See README.md
-- for the full list of differences and what each file changes.

mcl_java_pvp = {}
local jp = mcl_java_pvp
jp.modname = core.get_current_modname()
jp.modpath = core.get_modpath(jp.modname)

local function load(file)
	dofile(jp.modpath .. "/" .. file .. ".lua")
end

load("core")       -- shared helpers, unit conversion, knockback, cooldowns
load("items")      -- weapon/tool attack damage and speed, reach
load("damage")     -- damage pipeline order, armor, resistance, EPF, thorns, i-frames
load("shields")    -- shield arc, delay, blockable types, durability
load("movement")   -- gravity/jump, hitbox, sprint rules, use-slowdown, fall damage
load("melee")      -- Java attack: cooldown, crit, sweep, knockback, mace, fire aspect
if jp.enabled("ranged") then
	load("ranged") -- bow, crossbow, trident, throwables, wind charge, explosions, splash potions
end
if jp.enabled("hunger") then
	load("hunger") -- exhaustion, regeneration, eating, food values, chorus/pearl cooldowns
end
if jp.enabled("effects") then
	load("effects") -- potion durations and effect formulas
end
load("respawn")    -- respawn invulnerability, XP drop

core.log("action", "[mcl_java_pvp] Java Edition 1.21 PvP mechanics loaded")
