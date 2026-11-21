# mcl_java_pvp — Java Edition 1.21 PvP for Mineclonia

A separate mod that overrides Mineclonia (tested against Mineclonia commit
`a40455bd5`, Luanti 5.16-dev) so that everything that affects
player-versus-player fighting behaves like **Minecraft Java Edition 1.21**.
Mineclonia itself is not modified. The mod replaces Mineclonia callbacks and
damage modifiers at load time, overrides item definitions, and wraps public
functions.

## Installing

1. The mod lives in `minetest/mods/mcl_java_pvp`.
2. Enable it for a world: tick it in *Select Mods*, or add
   `load_mod_mcl_java_pvp = true` to the world's `world.mt`.
3. Optional settings go in `minetest.conf`. All of them default to on or to the Java value.

| Setting | Default | Effect |
|---|---|---|
| `mcl_java_pvp_ranged` | true | Bows, crossbows, tridents, throwables, wind charges, explosions, splash potions |
| `mcl_java_pvp_hunger` | true | Exhaustion, regeneration, eating, food values, chorus fruit, death XP |
| `mcl_java_pvp_effects` | true | Potion durations, effect stacking, effect formulas |
| `mcl_java_pvp_physics` | true | Gravity/jump, acceleration, sprint-jump boost, Jump Boost, Slow Falling, water speeds |
| `mcl_java_pvp_cooldown_indicator` | true | Attack-cooldown bar under the crosshair |
| `mcl_java_pvp_miss_resets_cooldown` | true | Swinging at nothing resets the attack cooldown |
| `mcl_java_pvp_natural_regeneration` | true | The `naturalRegeneration` game rule |
| `mcl_java_pvp_entity_reach` | 3.0 | Entity attack reach (creative 5) |
| `mcl_java_pvp_reach_tolerance` | 0.5 | Extra reach allowed for network lag |
| `mcl_java_pvp_spawn_invulnerability` | 3.0 | Seconds of invulnerability after (re)spawning |

On a PvP server, also don't give players the `fast` privilege. In Luanti,
fast mode lets you run at 25 m/s while holding the sprint key.

## Files

| File | Contents |
|---|---|
| `core.lua` | Helpers: finding/replacing Mineclonia callbacks, Java→Luanti trajectory conversion, Java knockback, item cooldowns |
| `items.lua` | Java attack damage / attack speed for every weapon and tool; reach |
| `damage.lua` | Java damage order, hurt-invulnerability, armor/toughness/Breach, Resistance, EPF, Thorns, damage-type tags, fire/campfire damage, netherite durability, Fire Protection |
| `shields.lua` | Shield arc, raise delay, blockable types, durability |
| `movement.lua` | Gravity/jump, acceleration, sprint rules, use-item slowdown, hitboxes, Jump Boost, Slow Falling, fall damage, water, elytra damage |
| `melee.lua` | Java `Player.attack`: cooldown, crits, sprint knockback, sweep, mace smash, Fire Aspect, Sweeping Edge, reach, cooldown indicator, mob-source knockback |
| `ranged.lua` | Bow, crossbow, trident, snowball/egg/pearl, wind charge, explosions, splash/lingering/tipped potions |
| `hunger.lua` | Exhaustion, natural regeneration/starvation, eating, food values, chorus fruit, suspicious stew, death XP |
| `effects.lua` | Potion durations, brewable variants, hidden-effect stacking, instant effects, effect tick intervals, absorption, saturation |
| `respawn.lua` | 3 s respawn invulnerability |

## Differences between Mineclonia and Java 1.21, and what this mod does

The table below was compiled from five audits of the Mineclonia source,
each compared against minecraft.wiki, Mojang's 1.21 data files and the
decompiled game code.

Status key:
- **Fixed**: now behaves like Java.
- **Approx.**: as close as Luanti allows.
- **Engine**: blocked by a Luanti engine limitation.
- **Not changed**: left alone; the reason is given.

### 1. Melee attack

| # | Mechanic | Mineclonia | Java 1.21 | Status |
|---|---|---|---|---|
| 1 | Damage formula | Engine: `fleshy × min(1, t/interval)`, truncated to an integer | `damage × (0.2 + 0.8c²)`, floats | Fixed |
| 2 | Minimum damage of a spam click | 0 (and then no knockback) | 20% of damage, full base knockback | Fixed |
| 3 | Enchantment damage scaling | Same linear factor, truncated | × c (linear) | Fixed |
| 4 | Cooldown reset on item switch | Never (wait with one item, hit with another) | Reset when the main-hand item type changes | Fixed |
| 5 | Cooldown reset on swing at air / block break | Never | Reset | Fixed (air swing detected by a server-side raycast) |
| 6 | Cooldown indicator | None | Crosshair indicator | Fixed (bar under the crosshair) |
| 7 | Netherite sword | 9 | 8 | Fixed |
| 8 | Wooden axe | 2 | 7 | Fixed |
| 9 | Netherite hoe | 4 | 1 | Fixed |
| 10 | Shovels | 2/3/3/4/2/5/6 (integers) | 2.5/3.5/3.5/4.5/2.5/5.5/6.5 | Fixed (exact floats) |
| 11 | Trident melee cooldown | 1.1 s (speed used as interval) | 0.909 s (speed 1.1) | Fixed |
| 12 | Shears | 0 damage, 0 knockback | 1 damage, speed 4 | Fixed |
| 13 | All other weapons' damage/speed | Swords, axes, picks and hoes matched Java | — | Kept (now exact floats) |
| 14 | Critical hit formula | `d + random(0, 1.5d+2)` (d…2.5d+2) | × 1.5, before enchantment damage | Fixed |
| 15 | Critical hit conditions | Attacker vy < 0 only | c > 0.9, falling, not on ground/ladder/vine, not in water, not blind, not riding, not sprinting | Fixed |
| 16 | Crits vs mobs | Random formula | × 1.5 under the Java conditions | Fixed |
| 17 | Base knockback | 0.5 × 0.546 m/s-ish, half the Java vertical: ~1.2 blocks | `knockback(0.4)`: about 3 blocks, about 1.1 high | Fixed (Java velocity converted so the distance and height match under Luanti physics) |
| 18 | Sprint hit | Victim gets the attacker's whole velocity, sprint continues | Extra `knockback(0.5)` along the attacker's facing, needs c > 0.9, attacker × 0.6 and sprint dropped | Fixed |
| 19 | Knockback enchantment | Merged into one push from the attacker's position | Extra `0.5 × level` push along the attacker's facing | Fixed |
| 20 | Knockback during invulnerability | Every hit | No base knockback on non-fresh hits | Fixed |
| 21 | Sprint bonus bypassed shields | Yes | No | Fixed |
| 22 | Netherite knockback resistance | 0.1 per piece | 0.1 per piece | Kept |
| 23 | Sweep attack | Not implemented | Sword, c > 0.9, on ground, not crit/sprint, slow: hits entities within the target box +1/+0.25 for `1 + ratio × damage`, knockback 0.4 | Fixed |
| 24 | Sweeping Edge enchantment | Missing (commented out) | Ratio `L/(L+1)` | Fixed (registered) |
| 25 | Sharpness | `+0.5 × level`, truncated (I = +0) | `0.5 × level + 0.5` | Fixed |
| 26 | Sharpness lost while Haste is active | Bug | — | Fixed (damage no longer read from tool caps) |
| 27 | Fire Aspect | Ignites on any punch (0 damage, blocked) | Only on a successful hit, 4 s/level; also sweep targets | Fixed |
| 28 | Strength / Weakness | × 1.3 / × 1.6, × 0.8 / × 0.6 at the victim (order vs armor undefined) | +3 / −4 attack damage per level, before cooldown and crit | Fixed |
| 29 | Haste / Mining Fatigue attack speed | Linear interval change; not for swords/mace/trident; Conduit Power counted | Attack speed × (1 + 0.1H) × (1 − 0.1F); no Conduit | Fixed |
| 30 | Entity reach | 4.5 (creative 10) | 3.0 (creative 5.0); blocks 4.5 | Fixed (server-side check, +0.5 lag tolerance) |
| 31 | Attacking while eating, drawing a bow or blocking | Partly possible | Not possible | Fixed |
| 32 | Durability per hit | Scaled down by the partial-cooldown factor | Swords/mace/trident 1, tools 2, always | Fixed |
| 33 | Trident melee durability | None | 1 | Fixed |
| 34 | Attack exhaustion | 0.1 on every punch, even blocked or 0-damage ones | 0.1 on a successful hit | Fixed |
| 35 | Attack sounds | Crit sound only | strong/weak/sweep/knockback/crit sounds | Approx. (crit and knockback sounds; Mineclonia has no other sound files) |
| 36 | Client punch rate | Engine limits damaging punches to one per 0.2 s | No limit | Engine (irrelevant: no one clicks > 5 CPS usefully under Java cooldowns) |
| 37 | Spears (1.21.11) | None | Jab/charge weapon | Not changed (new item) |

### 2. Mace

| # | Mechanic | Mineclonia | Java 1.21 | Status |
|---|---|---|---|---|
| 1 | Cooldown | Hard 1–2 s gate (integer game time), clicks do nothing | Normal attack cooldown (speed 0.6) | Fixed |
| 2 | Fall distance | Estimated from v²/40 with the wrong gravity (≈0.5× real) | Real fall distance | Fixed (tracked per player) |
| 3 | Smash damage | 9 for falls under 1.5; +3/+6/+3 too high | `4/block (≤3), +2/block (≤8), +1/block`, needs > 1.5 blocks | Fixed |
| 4 | Density | Applied to the wrong distance | +0.5 × level per block | Fixed |
| 5 | Breach | +15% damage per level after protection, within 2 s of any mace hit | Armor effectiveness −15% per level | Fixed |
| 6 | Fall damage after smash | Negated for 2 s after any mace hit | Fall distance reset only after a real smash | Fixed |
| 7 | AoE knockback | None | Living entities within 3.5: `(3.5 − d) × 0.7 (×2 if falling > 5)`, 0.7 up | Fixed |
| 8 | Wind Burst | Fixed 8 m/s × level | Wind explosion, knockback 1.2/1.75/2.2 | Fixed |
| 9 | Unbreaking | Ignored | Applies | Fixed |

### 3. Damage pipeline and invulnerability

| # | Mechanic | Mineclonia | Java 1.21 | Status |
|---|---|---|---|---|
| 1 | Hurt invulnerability | None at all | 10 ticks; a later hit deals only the excess over the last one, with no knockback | Fixed (all damage types) |
| 2 | Order | difficulty → fall → crit → Resistance → {Strength, shield, armor, mace} (unstable sort) → absorption → totem | difficulty → Fire Resistance → shield → i-frames → armor → Resistance → EPF → absorption → totem | Fixed |
| 3 | Resistance | Before armor; level ≥ 6 heals | After armor, clamped to 0 | Fixed |
| 4 | Armor durability | From post-crit, post-Resistance damage | From the damage before armor | Fixed |
| 5 | Netherite armor wear from fire | Yes | No (fire-resistant) | Fixed |
| 6 | Multiple damage sources in the same 0.5 s | All stack (several arrows, lava + burning, multishot, TNT) | Only the strongest | Fixed |
| 7 | Respawn invulnerability | None | 60 ticks (not fall damage) | Fixed |
| 8 | Melee damage resolution | Integer | Float | Fixed |
| 9 | Difficulty scaling | Mobs + explosions | Same | Kept |

### 4. Armor, enchantments, totem

| # | Mechanic | Mineclonia | Java 1.21 | Status |
|---|---|---|---|---|
| 1 | Armor points/toughness | All materials match | — | Kept |
| 2 | Armor formula | Algebraically identical | — | Kept (re-implemented with Breach) |
| 3 | Netherite durability | 381/556/521/451 | 407/592/555/481 | Fixed |
| 4 | Turtle shell | Missing | 2 armor, Water Breathing | Not changed (new item and textures) |
| 5 | EPF values, cap 20, no randomness | Match | — | Kept |
| 6 | Projectile Protection vs tridents | No (`trident` not a projectile type) | Yes | Fixed |
| 7 | Wither skull | Explosion-tagged, not projectile | Projectile | Fixed |
| 8 | `fly_into_wall` | Reduced by armor | Bypasses armor | Fixed |
| 9 | Campfire damage | "generic": bypasses armor, Fire Protection and Fire Resistance | `campfire`: is_fire, armor applies, Fire Resistance immune | Fixed |
| 10 | Fire Protection burn time | Highest single piece | Sum of all pieces (7+ levels = no burning) | Fixed |
| 11 | Blast Protection knockback | None | −15% explosion knockback per level, summed | Fixed (see ranged) |
| 12 | Thorns | Integer 1–4, total capped at 4, legacy level > 10 rule, 2 wear on one random piece | Each piece 15%/level, float [1, 5), max of the rolls counts, 2 wear on each triggering piece | Fixed |
| 13 | Totem | Matches (plus a breath refill) | — | Kept |
| 14 | Unbreaking on armor | Deterministic average | Random per point | Not changed (same average) |
| 15 | Respiration | Negates drown damage by chance | Saves air by chance | Not changed (no PvP impact) |

### 5. Shields

| # | Mechanic | Mineclonia | Java 1.21 | Status |
|---|---|---|---|---|
| 1 | Blocking arc | ~233°, including pitch (degrees passed to `math.cos`) | 180°, horizontal | Fixed |
| 2 | Raise delay | ~0.05–0.1 s | 0.25 s (5 ticks) | Fixed |
| 3 | Blockable damage | Blocked "generic"; didn't block fireballs, wither skulls, thorns, wind charges | Everything with a source position except bypasses_armor types, fire, lava, cactus, berry bush, anvils | Fixed |
| 4 | Durability | ceil(d) if d ≥ 3 | 1 + floor(d) if d ≥ 3 | Fixed |
| 5 | Durability damage basis | Post-crit/Resistance | Raw damage | Fixed |
| 6 | Order vs armor | Same priority (undefined) | Before armor | Fixed |
| 7 | Movement while blocking | × 0.5, sprinting allowed | × 0.2, can't start sprinting | Fixed |
| 8 | Axe disabling | 5 s | 5 s | Kept |
| 9 | Player-thrown tridents | Never blocked (shooter stored as a name string) | Blocked | Fixed (see ranged) |
| 10 | Bed/anchor explosions | Not blockable (no position) | Blockable facing the blast | Fixed (see ranged) |
| 11 | Fully blocked hit and i-frames | — | Starts the invulnerability window with lastHurt 0 | Fixed |

### 6. Movement and physics

| # | Mechanic | Mineclonia | Java 1.21 | Status |
|---|---|---|---|---|
| 1 | Jump | 6.6 m/s at 20.8 m/s²: 1.05 blocks, 0.63 s | 1.2522 blocks, 0.6 s | Fixed (27.8 m/s², 8.35 m/s: same apex and air time) |
| 2 | Air drag / terminal velocity | None | 0.98/tick vertical, about 78 m/s | Engine (fall damage no longer depends on speed) |
| 3 | Ground acceleration / stopping | Stop slide 0.66 blocks from a sprint | about 0.34 blocks | Fixed (36 m/s²) |
| 4 | Sprint-jump boost | None (≈ 5.6 m/s sprint-jumping) | +0.2 b/t per jump (≈ 7.1 m/s average) | Fixed (server-applied, about one ping late) |
| 5 | Air acceleration | 12 m/s² | Tuned so the boost decays like Java | Approx. |
| 6 | Item-use slowdown | Eat/drink/bow/crossbow × 0.3, shield × 0.5, trident and spyglass none | × 0.2 for all | Fixed |
| 7 | Sprinting while using items | Allowed to start | Can't start (continues if already sprinting) | Fixed |
| 8 | Sprinting while blind | Allowed | Blocked/stopped | Fixed |
| 9 | Sprint stop on wall collision | No | Yes (but resumes next tick if the key is held) | Not changed (no practical difference with the sprint key held) |
| 10 | Double-tap W to sprint | No | Yes | Not changed (Luanti uses the Aux1 key as the sprint key) |
| 11 | Hitbox | 0.624 × 1.795 (sneak 1.495, elytra 0.7 × 0.8) | 0.6 × 1.8 (sneak 1.5, swim/elytra 0.6 × 0.6) | Fixed |
| 12 | Fall damage | Engine: `round(v − 14)`, none below ≈ 5 blocks (≈ 9 at old gravity) | `ceil(distance − 3 − JumpBoost)` | Fixed |
| 13 | Fall-damage blocks | Engine scaled the speed; slime negated even when sneaking | Hay/honey × 0.2, bed half distance, slime 0 unless sneaking, dripstone (d+2) × 2 | Fixed |
| 14 | Fall reset | Water, cobweb, vine, powder snow | Water, climbables, cobweb, powder snow, berry bush, Slow Falling, mace smash, wind charge | Fixed |
| 15 | Jump Boost | Jump velocity × 1.5 / × 2.0 (2.36 / 4.19 blocks) | +0.1 b/t per level (1.83 / 2.5 blocks) | Fixed |
| 16 | Slow Falling | Half gravity even while rising | Gravity 0.01 b/t² only while descending, terminal 9.8 m/s, no fall damage | Fixed |
| 17 | Water speeds | Walk 2.7, sprint 3.5, swim up 2.7, idle sink 2.5 m/s | 2.2 / 3.9 / 2.2 / 0.5 | Approx. (equilibrium speeds tuned per state) |
| 18 | Swimming direction | Doesn't follow pitch | Follows look direction | Engine (players can enable `pitch_move` client-side) |
| 19 | Elytra fall damage | Whole distance (+3 too much) | ceil(d − 3) | Fixed |
| 20 | Elytra wall damage | 0.5 × Δv (+3 too much) | 0.5 × Δv − 3 | Fixed |
| 21 | Ladders | Idle hold, sneak descends at 2.35, Speed affects climbing | Down 3.0, sneak holds | Engine |
| 22 | Ice momentum | Only lower acceleration | Friction 0.98 builds momentum | Engine |
| 23 | Player pushing | Server-side impulses | Small per-tick pushes | Not changed |
| 24 | Latency | Sprint/use/pose/knockback are server→client | Client-predicted | Engine (the optional Mineclonia CSM, `mcl_enable_csm`, has Java client physics; this mod leaves those players' physics to it) |
| 25 | Slowness ≥ VII | Negative speed | Clamped to 0 | Not changed (unobtainable) |

### 7. Ranged and explosives

| # | Mechanic | Mineclonia | Java 1.21 | Status |
|---|---|---|---|---|
| 1 | Bow full draw | 0.5 s, linear power | 1.0 s, `f = (t² + 2t)/3` | Fixed |
| 2 | Bow minimum charge | Any release fires and uses an arrow | No shot below 0.1 | Fixed |
| 3 | Arrow gravity | 9.81 m/s² (flat, long shots) | 0.05 b/t² = 20 m/s², drag 0.99/tick | Fixed (player arrows; mob arrows kept because mob aim is tuned to the old gravity) |
| 4 | Arrow water drag | × 0.74 per node entered | × 0.6 per tick | Fixed |
| 5 | Shooter velocity | Not inherited | Added (vertical only if airborne) | Fixed (bow, crossbow, trident, throwables) |
| 6 | Arrow damage / crit | `d + random(1, d/2+2)`, crit always ≥ +1 | `ceil(v·base)` + `random(0, i/2+1)` | Fixed |
| 7 | Punch vs players | × 0.25 horizontal (≈ 1.6 m/s per level) | 0.6 b/t per level + 0.1 up | Fixed |
| 8 | Arrow knockback when blocked | Applied, then cancelled | None | Fixed |
| 9 | Bow durability | 385 | 384 | Fixed |
| 10 | Crossbow charge | 0.9 s, −0.13 s per Quick Charge level | 1.25 s, −0.25 s per level | Fixed |
| 11 | Crossbow fire key | Left click | Right click (use) | Fixed for non-CSM players |
| 12 | Multishot side arrows | Can be picked up (duplication) | Can't | Fixed |
| 13 | Crossbow wear | Always 3× (truthy-0 bug), durability 385 | 1 per arrow (3 with Multishot), 465 | Fixed |
| 14 | Piercing | Hits N entities | N + 1 | Fixed |
| 15 | Crossbow fireworks / firework star damage | Not implemented | 5 + 2 per star | Not changed (rockets have no stars in Mineclonia) |
| 16 | Trident flight | Gravity 24, no drag | 20 m/s², drag 0.99 | Fixed |
| 17 | Trident vs shields | Player throws never blocked | Blockable | Fixed |
| 18 | Trident vs Projectile Protection | Not a projectile | Projectile | Fixed |
| 19 | Riptide | Rides a projectile at 20/30/40 m/s, 2 durability | Push of 1.5/2.25/3.0 b/t, 1.2 lift, 20-tick spin attack (8), 1 durability | Fixed (non-CSM) |
| 20 | Snowball/egg/pearl throw | 22 m/s, 10.4 gravity + fake drag, no inaccuracy, 1.5-block hit radius | 30 m/s, 12 m/s², drag 0.99, inaccuracy 1, hitbox + 0.3 | Fixed |
| 21 | Snowballs/eggs vs players | Knockback from the thrower, plus the thrower's Fire Aspect | Nothing (Java 1.21) | Fixed |
| 22 | Holding right click with snowballs/eggs | Single throw | Repeats every 4 ticks | Fixed |
| 23 | Ender pearl cooldown | None | 20 ticks | Fixed |
| 24 | Endermite chance | 10% | 5% | Fixed |
| 25 | Pearls hitting entities | Pass through | Teleport on hit | Fixed |
| 26 | Pearl damage | 5 "fall" (zeroed by water at the landing spot) | 5 ender_pearl (Feather Falling applies) | Fixed (fall distance reset first) |
| 27 | Fishing rod hooking players | Impossible | Pulls players | Not changed |
| 28 | Wind charge cooldown | 1–2 s (integer game time) | 10 ticks | Fixed |
| 29 | Wind charge direct hit | 0 to players (often missed players entirely) | 1 damage, own damage type | Fixed |
| 30 | Wind burst | 1/distance push, max ≈ 8 m/s, radius 4 | Explosion power 1.2, × 1.22 knockback, exposure, Blast Protection | Fixed |
| 31 | Fall damage after a wind burst | Full | Only below the burst height | Fixed |
| 32 | Explosion damage | Floored, random-ray exposure | Float, Java exposure grid | Fixed |
| 33 | Explosion knockback | No Blast Protection, aimed at box centre | × (1 − 0.15 × total Blast Protection), aimed at the eyes | Fixed |
| 34 | End crystal | Blast 1 block too high; chained crystals exploded at power 1 or full | Power 6 at its base; crystals destroyed by explosions don't explode | Fixed |
| 35 | Explosion source position for shields | Missing for beds/anchors | Explosion centre | Fixed |
| 36 | Splash potion falloff | Steps (1, 7/8, 1/2, 1/4) | Linear `1 − d/4`, direct hit 1, ≤ 1 s dropped | Fixed |
| 37 | Splash potion throw | 12 m/s, 9.8 gravity | 10 m/s, −20° pitch offset, 20 m/s², drag 0.99 | Fixed (player throws; witches unchanged) |
| 38 | Tipped arrows | Always level I, base duration | Real potency/duration (1/8) | Fixed |
| 39 | Lingering cloud | Radius 4, instant effects × 0.25 | Radius 3, × 0.5 | Not changed (needs a rewrite of the cloud; throw physics fixed) |
| 40 | Arrows bouncing off during i-frames, deflection speed | — | — | Not changed (minor) |

### 8. Hunger, health and food

| # | Mechanic | Mineclonia | Java 1.21 | Status |
|---|---|---|---|---|
| 1 | Exhaustion step | −1.5 saturation, excess lost, clamp 4.0 | −1 saturation (or food), remainder kept, cap 40 | Fixed |
| 2 | Saturated regeneration | Flat 1 HP every ~0.55 s | min(sat, 6)/6 HP every 10 ticks, costs the same exhaustion | Fixed |
| 3 | Slow regeneration / starvation | Every ~4.05 s | Every 80 ticks, difficulty limits | Fixed |
| 4 | Peaceful | No saturation refill | +1 HP/20 ticks, +1 food/10 ticks, saturation | Fixed |
| 5 | naturalRegeneration gamerule | None | Exists | Fixed (setting) |
| 6 | Damage exhaustion | 0.1 on any HP loss | Per damage type (0 for fall, fire, magic, starve…), only if damage gets through absorption | Fixed |
| 7 | Saturation when eating | Capped at the pre-meal food level | Capped at the post-meal food level | Fixed |
| 8 | Eating times | 1.61 s (34 server steps), honey 1.61 s | 32 ticks, honey 40, dried kelp 16 | Fixed |
| 9 | Eating speed | × 0.3 | × 0.2 | Fixed |
| 10 | Honey bottle | Doesn't cure Poison | Cures Poison | Fixed |
| 11 | Sweet berries | 1 food | 2 food | Fixed |
| 12 | Glow berries | 1.2 saturation | 0.4 | Fixed |
| 13 | Pufferfish | Poison III, Nausea II | Poison II, Nausea I | Fixed |
| 14 | Golden apples, steak, golden carrots… | Match | — | Kept |
| 15 | Chorus fruit | No cooldown; refuses fire/magma/cactus; fall distance kept | 1 s cooldown, only avoids liquids, resets fall | Fixed |
| 16 | Suspicious stew | Old durations; effect levels wrong (Regeneration III etc.) | 1.21.4 durations, level I | Fixed |
| 17 | Death XP | All XP dropped | min(7 × level, 100) | Fixed |
| 18 | Float health / display | ceil() display, dies at 0 | Same | Kept |

### 9. Potions and effects

| # | Mechanic | Mineclonia | Java 1.21 | Status |
|---|---|---|---|---|
| 1 | Poison | 0:45 / 2:00 / II 22.5 s | 0:45 / 1:30 / II 21.6 s | Fixed |
| 2 | Regeneration | 0:45 / 2:00 / II 22.5 s | 0:45 / 1:30 / II 22.5 s | Fixed |
| 3 | Weakness | 3:00 / 8:00, has II | 1:30 / 4:00, no II | Fixed |
| 4 | Slow Falling | 3:00 / 8:00 | 1:30 / 4:00 | Fixed |
| 5 | Turtle Master | long 53 s, II 10 s | long 40 s, II 20 s | Fixed |
| 6 | Luck | 3:00, II and long versions | 5:00 only | Fixed |
| 7 | Decay (Bedrock-only) II | Brewable | — | Fixed (II removed) |
| 8 | Effect stacking | A stronger effect inherits the longer old duration | Own duration; the weaker one is hidden and resumes | Fixed |
| 9 | Instant Health/Harming III+ | 4×L / 6×L | 4≪amp / 6≪amp | Fixed |
| 10 | Regeneration/Poison/Wither III+ intervals | Rational fit | 50≫amp / 25≫amp / 40≫amp ticks, phase on duration | Fixed |
| 11 | Wither damage type | magic | wither | Fixed |
| 12 | Absorption at 0 | Effect stays | Effect ends | Fixed |
| 13 | Saturation effect | +L/s fractional | +(amp+1) food, +2(amp+1) saturation per tick | Fixed |
| 14 | Strength/Weakness tooltips | "+30% melee" | "+3 attack damage" | Fixed |
| 15 | Glowing range | 30 nodes | Unlimited | Not changed |
| 16 | Beacon | Sphere, 16 s every 3 s | Column box, (9+2L) s every 4 s | Not changed (rarely PvP-relevant) |
| 17 | Conduit | 2× range | Java range | Not changed |
| 18 | Turtle Master recipe | Not brewable (no turtle shell) | Brewable | Not changed (item missing) |

## Testing done

The mod has been load-tested and unit-tested only. It has not been played
with real clients.

- **Headless server load:** no errors or warnings.
- **Formula checks:** armor/toughness/Breach and mace bonus, plus the knockback conversion.
- **Mock-player combat simulation** through the real damage chain:
  - full sword hit 7;
  - spam hit inside i-frames 0;
  - crit 10.5;
  - netherite sword vs full diamond 2.24;
  - Sharpness V 10;
  - diamond axe 9;
  - wooden shovel 2.5;
  - sprint hit knockback 0.7/0.4 b/t, with the attacker slowed to 60%;
  - out of reach 0.
- **hunger/effects:** 37 load-time assertions (durations, food values, effect intervals, hidden-effect stacking).
- **ranged:** In an isolated test, arrows/tridents/potions fall at 20 m/s² and snowballs at 12. Bow damage is 6 at full charge with crits 6–10; crossbow 7. Quick Charge III gives 0.5 s. TNT damage is unfloored (37.2 on a pig, matching the formula), and crystals explode at power 6 from their base. Bow/crossbow controls, pearl teleport, the wind-charge launch and riptide were reviewed but need a real client to verify.
