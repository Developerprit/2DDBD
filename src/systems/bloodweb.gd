class_name Bloodweb
extends RefCounted
## The Bloodweb — the progression system from Dead by Daylight.
##
## Each character owns a private, deterministic node graph. Every tier lays out
## a ring of nodes (perks, items, add-ons, bloodpoint caches) and the player
## spends bloodpoints to take them. Taking enough of a tier unlocks the next one.
##
## Two properties matter here:
##
##   1. Generation is *seed-driven* from (char_id, tier). Nothing about a tier is
##      stored, so a save file only needs the tier number and the ids taken --
##      which keeps the save tiny and makes the web identical on every machine.
##   2. Costs and tier sizes are pure functions, so the economy can be rebalanced
##      without invalidating anybody's save.


enum Kind { PERK, ITEM, ADDON, BONUS }

## How many nodes a tier contains. Later tiers are wider.
const TIER_SIZES := [4, 5, 6, 6, 7, 8]

## Tier at which a character's three exclusive perks become usable by every other
## character on the same side ("teachables"). Until then they are private.
const TEACHABLE_TIER := 60

## Bloodpoints handed out the first time the game is launched.
const STARTER_BLOODPOINTS := 24000

## Fraction of a tier that must be taken before it can be advanced past.
const ADVANCE_RATIO := 0.6


static func side_of(is_killer: bool) -> String:
	return "killer" if is_killer else "survivor"


# ---------------------------------------------------------------------------
# Generation
# ---------------------------------------------------------------------------
static func nodes_for(char_id: String, is_killer: bool, tier: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(char_id) * 7919 + tier * 104729

	var count: int = TIER_SIZES[mini(maxi(tier - 1, 0), TIER_SIZES.size() - 1)]
	var out: Array = []
	for i in count:
		var kind := _roll_kind(rng, tier)
		out.append({
			"id": "%s.%d.%d" % [char_id, tier, i],
			"kind": kind,
			"payload": _payload(rng, char_id, is_killer, kind),
			"angle": TAU * (float(i) + 0.5) / float(count) + rng.randf_range(-0.10, 0.10),
			"ring": 1 if i % 2 == 0 else 0,
			"cost": cost_for(tier, kind),
		})
	return out


static func _roll_kind(rng: RandomNumberGenerator, tier: int) -> int:
	var r := rng.randf()
	# Early tiers favour perks so a new player actually gets a usable build.
	var perk_chance := 0.36 if tier <= 3 else 0.24
	if r < perk_chance:
		return Kind.PERK
	if r < perk_chance + 0.26:
		return Kind.ITEM
	if r < perk_chance + 0.52:
		return Kind.ADDON
	return Kind.BONUS


static func _payload(rng: RandomNumberGenerator, char_id: String, is_killer: bool,
		kind: int) -> Dictionary:
	match kind:
		Kind.PERK:
			var pool := perk_pool(is_killer)
			var owned := 0
			while owned < pool.size():
				var pid: String = pool[rng.randi_range(0, pool.size() - 1)]
				if not SaveData.has_unlock(char_id, "perk:" + pid):
					return {"perk": pid}
				owned += 1
			return {"bp": rng.randi_range(2000, 5000)}
		Kind.ITEM:
			if is_killer:
				return {"addon": _random_killer_addon(rng, char_id)}
			return {"item": _random_from(rng, GameConfig.items.keys())}
		Kind.ADDON:
			if is_killer:
				return {"addon": _random_killer_addon(rng, char_id)}
			return {"addon": _random_item_addon(rng)}
		_:
			return {"bp": rng.randi_range(1800, 5200)}


## The three perks a character owns exclusively. Never handed out by the web --
## they are that character's identity, granted directly on first use.
static func exclusive_perks_for(char_id: String) -> Array:
	var out: Array = []
	for pid in GameConfig.perks.keys():
		if str(GameConfig.perks[pid].get("owner", "")) == char_id:
			out.append(pid)
	out.sort()
	return out


## What the bloodweb may hand out: the SHARED pool of the side. Exclusives are
## excluded because they are granted directly rather than bought, and other
## characters' exclusives are excluded because those are not purchasable at all --
## they unlock wholesale once their owner reaches TEACHABLE_TIER.
static func perk_pool(is_killer: bool) -> Array:
	var side := side_of(is_killer)
	var out: Array = []
	for pid in GameConfig.perks.keys():
		var p: Dictionary = GameConfig.perks[pid]
		if str(p.get("side", "")) != side:
			continue
		if str(p.get("owner", "")) != "":
			continue
		out.append(pid)
	out.sort()
	return out


static func _random_from(rng: RandomNumberGenerator, arr: Array) -> String:
	if arr.is_empty():
		return ""
	return str(arr[rng.randi_range(0, arr.size() - 1)])


static func _random_killer_addon(rng: RandomNumberGenerator, char_id: String) -> String:
	var cfg: Dictionary = GameConfig.killers.get(char_id, {})
	var addons: Array = cfg.get("addons", [])
	if addons.is_empty():
		return ""
	return str(addons[rng.randi_range(0, addons.size() - 1)].get("id", ""))


static func _random_item_addon(rng: RandomNumberGenerator) -> String:
	var keys := GameConfig.items.keys()
	if keys.is_empty():
		return ""
	var item: Dictionary = GameConfig.items[keys[rng.randi_range(0, keys.size() - 1)]]
	var addons: Array = item.get("addons", [])
	if addons.is_empty():
		return ""
	return str(addons[rng.randi_range(0, addons.size() - 1)].get("id", ""))


# ---------------------------------------------------------------------------
# Economy
# ---------------------------------------------------------------------------
static func cost_for(tier: int, kind: int) -> int:
	var base := 900 + tier * 500
	match kind:
		Kind.PERK:
			base = int(base * 1.5)
		Kind.ITEM:
			base = int(base * 1.15)
		Kind.BONUS:
			base = int(base * 0.45)
	# Round to 50 so the numbers read cleanly in the UI.
	return int(round(float(base) / 50.0)) * 50


static func advance_goal(node_count: int) -> int:
	return maxi(1, int(ceil(float(node_count) * ADVANCE_RATIO)))


static func kind_key(kind: int) -> String:
	match kind:
		Kind.PERK:
			return "perk"
		Kind.ITEM:
			return "item"
		Kind.ADDON:
			return "addon"
	return "bonus"
