class_name Run
extends RefCounted
## The rules of one run (no drawing here; run_view.gd shows it). The hero
## walks a set path through the rooms of data/map.txt (start S, end X); an
## enemy (E) standing on the path stops them for a fight; ingredients lying on
## the path (r/b/n/h) are picked up as they walk over them. HP carries on from
## fight to fight. Two modes:
##   realtime - the hero walks on their own and fights on their own: attacks on
##     a timer, fires the weapon special when its power is full.
##   turns - walking, each tile is a turn. In a fight: your turn (brew, hand
##     over, END TURN), then the hero attacks, then the enemy does what it
##     showed it would (attack, block, or a Big Swing). An enemy that blocks
##     stops the hero's first hit; the hero always blocks, so hits land at
##     hero_block.
## You, the alchemist, hold ingredients drawn from your bag, put 1-3 in the
## flask and HAND IT OVER (used at the hero's next chance; in turns right
## away) or put it in the LOW-HP SLOT (used when HP drops low). Every potion is
## for the hero and their gear: heal, a shield WARD that soaks up damage, VENOM
## on the weapon that poisons with each hit. Ingredients that make a RECIPE
## brew that named potion, much stronger; anything else is an unnamed potion,
## the ingredients' effects added up. Brewing a recipe you didn't know puts it
## in your book; winning a fight teaches one more.
## A potion loses strength while it waits to be used (fresh: full its first
## turn, then half, then a tenth).
## You start with a full hand; nothing is drawn on its own in real time. A
## meter (seconds, or turns) lets you REDRAW: swap your whole hand. In turn
## fights a couple more are drawn each turn.
## All numbers come from data/game.json and are placeholders.

const EFFECTS := ["heal", "ward", "venom"]
const PICKUPS := {"r": "redcap", "b": "ironbark", "n": "nightshade", "h": "honey"}
const DIRS := [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)]

var d: Dictionary
var mode := "realtime"
var m: Dictionary  # d[mode]
var rng := RandomNumberGenerator.new()
var t := 0.0
var outcome := ""    # "", "won" (reached the end), "lost"
var known := {}      # recipe id -> true (the book)
var state := "walk"  # walk, fight
var fights_won := 0

# the map
var rows: Array = []
var path: Array = []      # Vector2i, start to end
var step := 0             # the hero's tile: path[step]
var walk_t := 0.0         # realtime: 0..1 on the way to the next tile; turns: the beat timer
var foes: Array = []      # {tile, hp, max, cd, count, winding, wind_t, poison, frame, frame_t}
var foe = null            # the one being fought
var pickups := {}         # Vector2i -> ingredient id

var hero := {}
var draw_pile: Array = []
var hand: Array = []       # ingredient ids
var flask: Array = []      # ingredient ids (still count toward the hand cap)
var discard: Array = []
var handed: Array = []     # realtime: potions waiting for the hero, used in order
var low_slot = null        # one potion or null
var redraw_t := 0.0  # seconds (realtime) or turns since the last redraw
var poison_t := 0.0

# turn fights
var turn := 1
var phase := "you"  # you, hero (hero just attacked), enemy (enemy just acted)
var phase_t := 0.0
var potions_used := 0  # this turn
var parts_added := 0   # turns: ingredients put in the flask this turn
var intent := "attack"  # what the enemy will do: attack, big, block

## What happened since the view last looked: {kind, amount, text}.
var events: Array = []


func setup(data: Dictionary, map_text: String, seed_value: int, mode_ := "realtime", book := {}) -> void:
	d = data
	mode = mode_
	m = d[mode]
	known = book
	rng.seed = seed_value
	var h: Dictionary = d["hero"]
	hero = {"hp": float(h["hp"]), "max": float(h["hp"]), "power": 0.0, "ward": 0.0, "venom": 0,
		"cd": float(h["attack_every"]), "busy": 0.0, "frame": "idle", "frame_t": 0.0}
	_read_map(map_text)
	draw_pile = d["bag"].duplicate()
	_shuffle(draw_pile)
	for i in int(m["start_hand"]):
		_draw_one()


## The recipes at the start (marked known in the data).
static func starting_book(data: Dictionary) -> Dictionary:
	var book := {}
	for id in recipe_ids(data):
		if data["recipes"][id].get("known", false):
			book[id] = true
	return book


static func recipe_ids(data: Dictionary) -> Array:
	return data["recipes"].keys().filter(func(k): return not k.begins_with("_"))


static func load_data() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string("res://data/game.json"))


static func load_map() -> String:
	return FileAccess.get_file_as_string("res://data/map.txt")


# ── The map ──────────────────────────────────────────────────────────────────

func _read_map(text: String) -> void:
	rows = Array(text.strip_edges().split("\n")).map(func(r): return r.strip_edges())
	var start := Vector2i.ZERO
	var end := Vector2i.ZERO
	for y in rows.size():
		for x in rows[y].length():
			var c: String = rows[y][x]
			var p := Vector2i(x, y)
			match c:
				"S": start = p
				"X": end = p
				"E": foes.append(_new_foe(p))
			if PICKUPS.has(c):
				pickups[p] = PICKUPS[c]
	# the path: start, past every enemy (nearest first), to the end
	var marks: Array = foes.map(func(f): return f["tile"])
	var from_start := _dists(start)
	marks.sort_custom(func(a, b): return from_start[a] < from_start[b])
	marks.append(end)
	path = [start]
	for mk in marks:
		path.append_array(_route(path.back(), mk).slice(1))
	if path.size() < 2:
		push_error("no path in the map (is data/map.txt missing?)")
		outcome = "broken"


func walkable(p: Vector2i) -> bool:
	return p.y >= 0 and p.y < rows.size() and p.x >= 0 and p.x < rows[p.y].length() and rows[p.y][p.x] != "#"


func _dists(from: Vector2i) -> Dictionary:
	var dist := {from: 0}
	var todo := [from]
	while not todo.is_empty():
		var c: Vector2i = todo.pop_front()
		for dv in DIRS:
			var n: Vector2i = c + dv
			if walkable(n) and not dist.has(n):
				dist[n] = dist[c] + 1
				todo.append(n)
	return dist


## Shortest way from a to b (both ends included).
func _route(a: Vector2i, b: Vector2i) -> Array:
	var dist := _dists(b)
	var out := [a]
	var c := a
	while c != b:
		for dv in DIRS:
			var n: Vector2i = c + dv
			if dist.has(n) and dist[n] < dist[c]:
				c = n
				break
		out.append(c)
	return out


func _new_foe(p: Vector2i) -> Dictionary:
	var e: Dictionary = d["enemy"]
	return {"tile": p, "hp": float(e["hp"]), "max": float(e["hp"]), "cd": float(e["attack_every"]),
		"poison": 0, "count": 0, "winding": false, "wind_t": 0.0, "frame": "idle", "frame_t": 0.0}


func foe_at(p: Vector2i):
	for f in foes:
		if f["tile"] == p:
			return f
	return null


## Where the hero is, in tiles (between two tiles while walking in real time).
func hero_pos() -> Vector2:
	var a := Vector2(path[step])
	if state == "walk" and mode == "realtime" and step + 1 < path.size():
		return a.lerp(Vector2(path[step + 1]), walk_t)
	return a


# ── Your actions ─────────────────────────────────────────────────────────────

func held() -> int:
	return hand.size() + flask.size()


## Can you act now? (Always, except during the hero's and enemy's part of a
## turn-based fight.)
func your_turn() -> bool:
	return outcome == "" and (mode == "realtime" or state == "walk" or phase == "you")


func potions_left() -> int:
	return int(m["potions_per_turn"]) - potions_used if mode == "turns" and state == "fight" else 99


## Turns: how many more ingredients can go in the flask this turn.
func parts_left() -> int:
	return int(m["parts_per_turn"]) - parts_added if mode == "turns" else 99


func can_add(i: int) -> bool:
	return your_turn() and parts_left() > 0 and i >= 0 and i < hand.size() and flask.size() < int(d["flask_max"])


func add_to_flask(i: int) -> bool:
	if not can_add(i):
		return false
	flask.append(hand[i])
	hand.remove_at(i)
	parts_added += 1
	return true


## Taking back the ingredient put in this turn gives the turn's part back.
func take_from_flask(i: int) -> void:
	if i >= 0 and i < flask.size():
		if parts_added > 0 and i == flask.size() - 1:
			parts_added -= 1
		hand.append(flask[i])
		flask.remove_at(i)


func flask_ready() -> bool:
	return outcome == "" and flask.size() >= int(d["flask_min"])


func can_hand_over() -> bool:
	return flask_ready() and your_turn() and potions_left() > 0


## Real time: the hero uses it at their next chance. Turns: right away.
func hand_over() -> bool:
	if not can_hand_over():
		return false
	if mode == "turns":
		if state == "fight":
			potions_used += 1
		_use(_brew())
	else:
		handed.append(_brew())
	return true


func can_slot() -> bool:
	return flask_ready() and low_slot == null and your_turn() and potions_left() > 0


func to_low_slot() -> bool:
	if not can_slot():
		return false
	if mode == "turns" and state == "fight":
		potions_used += 1
	low_slot = _brew()
	return true


func redraw_need() -> float:
	return float(m["redraw_fill"]) if mode == "realtime" else float(m["redraw_turns"])


func redraw_ready() -> bool:
	return your_turn() and redraw_t >= redraw_need()


## Discard the hand (not the flask) and draw a full one.
func redraw() -> bool:
	if not redraw_ready():
		return false
	discard.append_array(hand)
	hand.clear()
	while held() < int(d["hand_cap"]) and _draw_one():
		pass
	redraw_t = 0.0
	return true


# ── Brewing ──────────────────────────────────────────────────────────────────

## The recipe these ingredients make (any order), or "".
func recipe_of(ids: Array) -> String:
	var mine := ids.duplicate()
	mine.sort()
	for id in recipe_ids(d):
		var want: Array = d["recipes"][id]["ings"].duplicate()
		want.sort()
		if want == mine:
			return id
	return ""


## What the flask would make right now: {recipe, name, fx: {effect: amount}}.
## A recipe you don't know yet shows as unknown until you brew it.
func flask_effects(ids: Array = flask) -> Dictionary:
	var fx := {}
	for e in EFFECTS:
		fx[e] = 0.0
	var r := recipe_of(ids)
	if r != "":
		for e in d["recipes"][r]["fx"]:
			fx[e] += float(d["recipes"][r]["fx"][e])
	else:
		for id in ids:
			for e in d["ingredients"][id]["fx"]:
				fx[e] += float(d["ingredients"][id]["fx"][e])
	var name := "Unnamed potion"
	if r != "" and known.has(r):
		name = String(d["recipes"][r]["name"])
	elif r != "":
		name = "Unknown recipe?"
	return {"recipe": r, "name": name, "fx": fx}


func _brew() -> Dictionary:
	var p := flask_effects()
	p["ings"] = flask.duplicate()
	p["age"] = 0.0
	if p["recipe"] != "" and not known.has(p["recipe"]):
		learn(p["recipe"])
		p["name"] = String(d["recipes"][p["recipe"]]["name"])
	discard.append_array(flask)
	flask.clear()
	return p


func learn(r: String) -> void:
	known[r] = true
	events.append({"kind": "learned", "text": String(d["recipes"][r]["name"])})


## How strong a potion still is, from its age in turns.
func fresh(p: Dictionary) -> float:
	var steps: Array = d["fresh"]["steps"]
	return float(steps[mini(int(p["age"]), steps.size() - 1)])


func _age_potions(turns: float) -> void:
	for p in handed:
		p["age"] += turns
	if low_slot != null:
		low_slot["age"] += turns


# ── Time ─────────────────────────────────────────────────────────────────────

func step_time(dt: float) -> void:
	if outcome != "":
		return
	t += dt
	for a in [hero] + foes:
		a["frame_t"] -= dt
		if a["frame_t"] <= 0.0:
			a["frame"] = "idle"
	if mode == "realtime":
		redraw_t = minf(redraw_need(), redraw_t + dt)
		_age_potions(dt / float(d["fresh"]["turn_secs"]))
		hero["busy"] -= dt
		if hero["busy"] <= 0.0 and not _check_low_slot() and not handed.is_empty():
			_use(handed.pop_front())
	if state == "walk":
		_walk(dt)
	elif mode == "turns":
		_turn_step(dt)
	else:
		_fight_realtime(dt)


func _walk(dt: float) -> void:
	if step + 1 >= path.size():
		outcome = "won"
		return
	var next: Vector2i = path[step + 1]
	var f = foe_at(next)
	if f != null:
		_start_fight(f)
		return
	if mode == "realtime":
		walk_t += dt * float(d["walk"]["tiles_per_sec"])
		if walk_t < 1.0:
			return
		walk_t -= 1.0
	else:
		walk_t += dt
		if walk_t < float(d["walk"]["beat"]):
			return
		walk_t = 0.0
		_turn_passes()
	step += 1
	var here: Vector2i = path[step]
	if pickups.has(here):
		var id: String = pickups[here]
		pickups.erase(here)
		if held() < int(d["hand_cap"]):
			hand.append(id)
		else:
			draw_pile.append(id)
		events.append({"kind": "pickup", "text": String(d["ingredients"][id]["name"])})
	if step + 1 >= path.size():
		outcome = "won"


## Turns: a turn goes by (a tile walked, or a fight turn).
func _turn_passes() -> void:
	parts_added = 0
	redraw_t = minf(redraw_need(), redraw_t + 1.0)
	_age_potions(1.0)


func _start_fight(f: Dictionary) -> void:
	state = "fight"
	foe = f
	walk_t = 0.0
	poison_t = 0.0
	hero["cd"] = float(d["hero"]["attack_every"])
	f["cd"] = float(d["enemy"]["attack_every"])
	turn = 1
	phase = "you"
	potions_used = 0
	parts_added = 0
	if mode == "turns":
		_pick_intent()
	events.append({"kind": "fight"})


func _fight_realtime(dt: float) -> void:
	poison_t += dt
	if poison_t >= float(d["poison_tick"]):
		poison_t = 0.0
		_poison_tick()
		if state != "fight":
			return
	var sp: Dictionary = d["special_power"]
	hero["power"] = minf(float(sp["max"]), hero["power"] + float(sp["per_second"]) * dt)
	hero["cd"] -= dt
	if hero["busy"] <= 0.0 and hero["cd"] <= 0.0:
		hero["cd"] = float(d["hero"]["attack_every"])
		hero["busy"] = float(d["attack_frame_time"])
		_frame(hero, "attack")
		var w: Dictionary = d["weapons"][d["hero"]["weapon"]]
		if hero["power"] >= float(sp["max"]):
			hero["power"] = 0.0
			_hero_hit(float(w["special_dmg"]), String(w["special"]) + "!")
		else:
			_hero_hit(float(d["hero"]["attack_dmg"]), "")
	if state != "fight":
		return
	var e: Dictionary = d["enemy"]
	if foe["winding"]:
		foe["wind_t"] -= dt
		if foe["wind_t"] <= 0.0:
			foe["winding"] = false
			_hurt_hero(float(e["big_dmg"]), String(e["big_name"]))
		return
	foe["cd"] -= dt
	if foe["cd"] <= 0.0:
		foe["cd"] = float(e["attack_every"])
		foe["count"] += 1
		if foe["count"] % int(e["big_every"]) == 0:
			foe["winding"] = true
			foe["wind_t"] = float(e["big_windup"])
			events.append({"kind": "windup", "text": String(e["big_name"])})
		else:
			_hurt_hero(float(e["attack_dmg"]), "")


func _check_low_slot() -> bool:
	if low_slot != null and hero["hp"] <= hero["max"] * float(d["low_hp_at"]):
		var p: Dictionary = low_slot
		low_slot = null
		_use(p, "low-HP slot")
		return true
	return false


## The hero drinks it, rubs it on the weapon, or on the shield - at whatever
## strength it has left.
func _use(p: Dictionary, from: String = "") -> void:
	hero["busy"] = float(d["hero"]["drink_time"])
	var k := fresh(p)
	var label := String(p["name"])
	if k < 1.0:
		label += " (%d%%)" % int(round(k * 100.0))
	events.append({"kind": "use", "text": label + (" (" + from + ")" if from != "" else "")})
	var fx: Dictionary = p["fx"]
	var heal: float = fx["heal"] * k
	if heal > 0.0:
		var before: float = hero["hp"]
		hero["hp"] = minf(hero["max"], hero["hp"] + heal)
		events.append({"kind": "heal", "amount": hero["hp"] - before, "wasted": heal - (hero["hp"] - before)})
	if fx["ward"] * k > 0.0:
		hero["ward"] += fx["ward"] * k
		events.append({"kind": "ward", "amount": fx["ward"] * k})
	var venom := roundi(fx["venom"] * k)
	if venom > 0:
		hero["venom"] += venom
		events.append({"kind": "venom", "amount": venom})


# ── Turn fights ──────────────────────────────────────────────────────────────

## Done on your turn: the hero attacks now, the enemy a beat later.
func end_turn() -> bool:
	if mode != "turns" or state != "fight" or not your_turn():
		return false
	_hero_attacks()
	phase = "hero"
	phase_t = float(m["beat"])
	return true


func _turn_step(dt: float) -> void:
	if phase == "you":
		return
	phase_t -= dt
	if phase_t > 0.0:
		return
	if phase == "hero":
		_poison_tick()
		if state == "fight":
			_enemy_acts()
		phase = "enemy"
		phase_t = float(m["beat"])
	elif outcome == "":
		_new_turn()


## The hero's attack, then the special too if power is full. An enemy that
## chose to block stops the first hit.
func _hero_attacks() -> void:
	_frame(hero, "attack")
	var sp: Dictionary = d["special_power"]
	var w: Dictionary = d["weapons"][d["hero"]["weapon"]]
	var hits: Array = [[float(d["hero"]["attack_dmg"]), ""]]
	if hero["power"] >= float(sp["max"]):
		hero["power"] = 0.0
		hits.append([float(w["special_dmg"]), String(w["special"]) + "!"])
	for i in hits.size():
		if i == 0 and intent == "block":
			events.append({"kind": "enemy_block", "text": "blocked"})
			continue
		_hero_hit(hits[i][0], hits[i][1])
		if state != "fight":
			return


func _enemy_acts() -> void:
	var e: Dictionary = d["enemy"]
	var cut := float(m["hero_block"])
	match intent:
		"attack": _hurt_hero(float(e["attack_dmg"]) * cut, "blocked")
		"big": _hurt_hero(float(e["big_dmg"]) * cut, String(e["big_name"]) + ", blocked")
		"block": events.append({"kind": "windup", "text": "guards"})


func _new_turn() -> void:
	phase = "you"
	if state != "fight":
		return
	turn += 1
	potions_used = 0
	_turn_passes()
	var sp: Dictionary = d["special_power"]
	hero["power"] = minf(float(sp["max"]), hero["power"] + float(m["power_per_turn"]))
	for i in int(m["draw_per_turn"]):
		if held() >= int(d["hand_cap"]) or not _draw_one():
			break
	_pick_intent()


## Every big_every-th turn a Big Swing; otherwise attack, or now and then block.
func _pick_intent() -> void:
	foe["count"] += 1
	if foe["count"] % int(d["enemy"]["big_every"]) == 0:
		intent = "big"
	elif rng.randf() < float(m["enemy_block_chance"]):
		intent = "block"
	else:
		intent = "attack"


# ── Hits ─────────────────────────────────────────────────────────────────────

## A hit from the hero; a venomed weapon poisons too.
func _hero_hit(n: float, label: String) -> void:
	_hurt_foe(n, label)
	if hero["venom"] > 0 and state == "fight":
		hero["venom"] -= 1
		foe["poison"] += int(d["venom_poison"])
		events.append({"kind": "poisoned", "amount": d["venom_poison"]})


func _poison_tick() -> void:
	if foe == null or foe["poison"] <= 0:
		return
	_hurt_foe(float(foe["poison"]), "poison")
	if foe != null:
		foe["poison"] -= 1


func _hurt_foe(n: float, label: String) -> void:
	foe["hp"] = maxf(0.0, foe["hp"] - n)
	events.append({"kind": "enemy_hit", "amount": n, "text": label})
	if foe["hp"] <= 0.0:
		_foe_down()


## The enemy falls: back to walking, and the book learns a recipe.
func _foe_down() -> void:
	foes.erase(foe)
	foe = null
	state = "walk"
	phase = "you"
	walk_t = 0.0
	fights_won += 1
	events.append({"kind": "foe_down"})
	var left := recipe_ids(d).filter(func(id): return not known.has(id))
	if not left.is_empty():
		learn(left[rng.randi() % left.size()])


## A hit on the hero: the shield ward soaks it up first.
func _hurt_hero(n: float, label: String) -> void:
	_frame(foe, "attack")
	var soak := minf(hero["ward"], n)
	if soak > 0.0:
		hero["ward"] -= soak
		n -= soak
		events.append({"kind": "warded", "amount": soak})
	hero["hp"] = maxf(0.0, hero["hp"] - n)
	var sp: Dictionary = d["special_power"]
	hero["power"] = minf(float(sp["max"]), hero["power"] + n * float(sp["per_hp_lost"]))
	events.append({"kind": "hero_hit", "amount": n, "text": label})
	if hero["hp"] <= 0.0:
		outcome = "lost"
	elif mode == "turns" or hero["busy"] <= 0.0:
		_check_low_slot()


func _frame(a: Dictionary, f: String) -> void:
	a["frame"] = f
	a["frame_t"] = float(d["attack_frame_time"])


# ── Bag ──────────────────────────────────────────────────────────────────────

func _draw_one() -> bool:
	if draw_pile.is_empty():
		draw_pile = discard.duplicate()
		discard.clear()
		_shuffle(draw_pile)
	if draw_pile.is_empty():
		return false
	hand.append(draw_pile.pop_back())
	return true


func _shuffle(a: Array) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = a[i]
		a[i] = a[j]
		a[j] = tmp
