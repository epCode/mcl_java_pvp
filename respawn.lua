-- Respawn invulnerability (Java: 60 ticks after joining or respawning,
-- every damage type except fall damage and bypasses_invulnerability).
-- Mineclonia has none, so players can be spawn-killed.

local jp = mcl_java_pvp

jp.SPAWN_INVULNERABILITY = jp.setting_number("spawn_invulnerability", 3.0)

local spawned = jp.player_table()

local function mark(player)
	spawned[player] = jp.now()
end

core.register_on_joinplayer(mark)
core.register_on_respawnplayer(mark)

function jp.spawn_protected(player)
	local t = spawned[player]
	return t and jp.now() - t < jp.SPAWN_INVULNERABILITY
end

mcl_damage.register_modifier(function(obj, damage, reason)
	if not obj:is_player() or damage <= 0 then return end
	if reason.flags.bypasses_invulnerability or reason.type == "fall" then return end
	if jp.spawn_protected(obj) then
		return 0
	end
end, -60)
