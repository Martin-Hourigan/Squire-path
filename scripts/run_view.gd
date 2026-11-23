extends Node2D
## The menu (REAL-TIME / TURN-BASED, updates) and one run (rules in run.gd).
## The map is a square grid seen from above, turned 45 degrees so the rooms
## are diamonds; the camera follows the hero. Hero and enemies are PLACEHOLDER
## rectangles named after their asset and frame (idle / attack).
## Top left: the hero. Top right: the enemy being fought.
## Bottom: your hand of ingredients, the flask, the low-HP slot, REDRAW, BOOK,
## and END TURN in turn-based fights.
## Tap/click an ingredient to put it in the flask, a flask ingredient to take
## it back, then HAND OVER or LOW-HP SLOT. Keys: 1-5, Q, W, R, B (book),
## Space (end turn), Esc / phone back (menu). The book is saved in
## user://book.json.
## Dev args: --seed <n>, --mode realtime|turns (skips the menu)

const HALF := 32.0  # half a tile's width on screen (tiles are squares turned 45 degrees)
const VIEW_CENTRE := Vector2(480, 200)
const BAND := Rect2(0, 372, 960, 168)
const CARD := Vector2(80, 148)
const HAND_POS := Vector2(8, 384)
const FLASK := Rect2(446, 380, 262, 152)
const SIDE := Rect2(716, 380, 236, 152)
const INK := Color("#f2ead6")
const DIM := Color("#8a8478")
const GOLD := Color("#c8a040")
const GOOD := Color("#8ae08a")
const BOOK_PATH := "user://book.json"

var run: Run
var data: Dictionary
var map_text: String
var screen := "menu"  # menu, run
var mode := "realtime"
var book := {}  # recipe id -> true
var book_open := false
var cam := Vector2.ZERO  # tile position the camera looks at
var update_state := "idle"  # idle, checking, latest, new, failed, downloading, ready, download_failed
var update_tag := ""
var update_url := ""
var update_page := ""
var http: HTTPRequest
var download: HTTPRequest
var _font: Font
var _floaters: Array = []    # {text, pos (tiles), lift, t, col}
var _seed := 1


func _ready() -> void:
	_font = ThemeDB.fallback_font
	data = Run.load_data()
	map_text = Run.load_map()
	_load_book()
	var args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	var i := args.find("--seed")
	if i >= 0 and i + 1 < args.size():
		_seed = int(args[i + 1])
	var j := args.find("--mode")
	if j >= 0 and j + 1 < args.size():
		_start(args[j + 1])
	# an update downloaded last time has been installed (or given up on)
	if FileAccess.file_exists(Update.APK):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(Update.APK))
	if OS.has_feature("mobile"):
		_check_update()


func _start(m: String) -> void:
	mode = m
	screen = "run"
	_new_run()


func _new_run() -> void:
	run = Run.new()
	run.setup(data, map_text, _seed, mode, book)
	_seed += 1
	_floaters.clear()
	book_open = false
	cam = run.hero_pos()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if screen == "menu":
			get_tree().quit()
		screen = "menu"


func _process(dt: float) -> void:
	if screen == "menu":
		queue_redraw()
		return
	if not book_open:
		run.step_time(dt)
	for ev in run.events:
		_on_event(ev)
	run.events.clear()
	var look := run.hero_pos()
	if run.foe != null:
		look = look.lerp(Vector2(run.foe["tile"]), 0.5)
	cam = cam.lerp(look, minf(dt * 6.0, 1.0))
	for f in _floaters:
		f["t"] += dt
		f["lift"] += 22.0 * dt
	_floaters = _floaters.filter(func(f): return f["t"] < 1.4)
	queue_redraw()


func _on_event(ev: Dictionary) -> void:
	var at := run.hero_pos()
	var foe_at := Vector2(run.foe["tile"]) if run.foe != null else at
	match ev["kind"]:
		"enemy_hit":
			var txt := "-%d" % int(ev["amount"])
			if ev["text"] != "":
				txt = ev["text"] + " " + txt
			_float(txt, foe_at, 60, Color("#ffd0a0"))
		"hero_hit":
			var txt2 := "-%d" % int(ev["amount"])
			if ev["text"] != "":
				txt2 = ev["text"] + " " + txt2
			_float(txt2, at, 60, Color("#ff7a6a"))
		"heal":
			var txt3 := "+%d HP" % int(ev["amount"])
			if ev["wasted"] > 0.0:
				txt3 += "  (%d wasted)" % int(ev["wasted"])
			_float(txt3, at, 80, GOOD)
		"ward":
			_float("+%d shield ward" % int(ev["amount"]), at, 96, Color("#a0c0e0"))
		"warded":
			_float("ward soaks %d" % int(ev["amount"]), at, 76, Color("#a0c0e0"))
		"venom":
			_float("venom on the blade", at, 112, Color("#b080e0"))
		"poisoned":
			_float("+%d poison" % int(ev["amount"]), foe_at, 80, Color("#b080e0"))
		"learned":
			_float("NEW RECIPE: " + ev["text"], at, 130, GOLD)
			_save_book()
		"pickup":
			_float("+" + ev["text"], at, 70, INK)
		"use":
			_float("the knight uses " + ev["text"], at, 40, INK)
		"enemy_block":
			_float("blocked", foe_at, 80, Color("#c8c8d0"))
		"windup":
			_float(ev["text"] + "!", foe_at, 100, Color("#ff9a50"))
		"foe_down":
			_float("the brute falls", at, 100, GOLD)


func _float(text: String, tile: Vector2, lift: float, col: Color) -> void:
	_floaters.append({"text": text, "pos": tile, "lift": lift, "t": 0.0, "col": col})


# ── Input ────────────────────────────────────────────────────────────────────

func _unhandled_input(ev: InputEvent) -> void:
	if screen == "menu":
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			_menu_click(ev.position)
		return
	if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
		if book_open:
			book_open = false
			return
		_click(ev.position)
	elif ev is InputEventKey and ev.pressed and not ev.echo:
		var k: int = ev.keycode
		if k == KEY_ESCAPE:
			screen = "menu"
			return
		if run.outcome != "":
			if k == KEY_R or k == KEY_SPACE or k == KEY_ENTER:
				_new_run()
			return
		if k == KEY_B:
			book_open = not book_open
		elif k >= KEY_1 and k <= KEY_9:
			run.add_to_flask(k - KEY_1)
		elif k == KEY_Q:
			run.hand_over()
		elif k == KEY_W:
			run.to_low_slot()
		elif k == KEY_R:
			run.redraw()
		elif k == KEY_SPACE or k == KEY_ENTER:
			run.end_turn()
		elif k == KEY_BACKSPACE:
			while not run.flask.is_empty():
				run.take_from_flask(0)


func _menu_click(p: Vector2) -> void:
	if _btn_mode(0).has_point(p):
		_start("realtime")
	elif _btn_mode(1).has_point(p):
		_start("turns")
	elif _btn_update().has_point(p):
		_update_tap()
	elif _btn_forget().has_point(p):
		book = Run.starting_book(data)
		_save_book()


func _click(p: Vector2) -> void:
	if run.outcome != "":
		if _btn_menu().has_point(p):
			screen = "menu"
		else:
			_new_run()
		return
	for i in run.hand.size():
		if _card_rect(i).has_point(p):
			run.add_to_flask(i)
			return
	for i in run.flask.size():
		if _flask_slot(i).has_point(p):
			run.take_from_flask(i)
			return
	if _btn_hand_over().has_point(p):
		run.hand_over()
	elif _btn_low().has_point(p):
		run.to_low_slot()
	elif _btn_redraw().has_point(p):
		run.redraw()
	elif _btn_book().has_point(p):
		book_open = true
	elif _btn_end_turn().has_point(p):
		run.end_turn()


# ── Layout ───────────────────────────────────────────────────────────────────

func _card_rect(i: int) -> Rect2:
	return Rect2(HAND_POS + Vector2(i * (CARD.x + 6), 0), CARD)


func _flask_slot(i: int) -> Rect2:
	return Rect2(FLASK.position + Vector2(10 + i * 56, 10), Vector2(50, 50))


func _btn_hand_over() -> Rect2:
	return Rect2(FLASK.position + Vector2(8, 106), Vector2(120, 40))


func _btn_low() -> Rect2:
	return Rect2(FLASK.position + Vector2(134, 106), Vector2(120, 40))


func _btn_redraw() -> Rect2:
	return Rect2(SIDE.position + Vector2(0, 58), Vector2(114, 40))


func _btn_book() -> Rect2:
	return Rect2(SIDE.position + Vector2(122, 58), Vector2(114, 40))


func _btn_end_turn() -> Rect2:
	return Rect2(SIDE.position + Vector2(0, 106), Vector2(236, 44))


func _low_rect() -> Rect2:
	return Rect2(SIDE.position + Vector2(0, 4), Vector2(236, 46))


func _btn_mode(i: int) -> Rect2:
	return Rect2(330, 210 + i * 90, 300, 70)


func _btn_update() -> Rect2:
	return Rect2(330, 430, 300, 46)


func _btn_forget() -> Rect2:
	return Rect2(800, 500, 146, 30)


func _btn_menu() -> Rect2:
	return Rect2(400, 340, 160, 44)


## A tile position on screen (the middle of the tile's diamond).
func _scr(tile: Vector2) -> Vector2:
	var v := tile - cam
	return VIEW_CENTRE + Vector2(v.x - v.y, v.x + v.y) * HALF


# ── Drawing ──────────────────────────────────────────────────────────────────

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, Vector2(960, 540)), Color("#121116"))
	if screen == "menu":
		_draw_menu()
		return
	_draw_map()
	_draw_actors()
	for f in _floaters:
		var a: float = clampf(1.4 - f["t"], 0.0, 1.0)
		_text_c(_scr(f["pos"]) - Vector2(0, f["lift"]), f["text"], 14, Color(f["col"], a))
	_draw_hero_panel()
	_draw_foe_panel()
	_draw_band()
	if run.outcome != "":
		_draw_outcome()
	elif book_open:
		_draw_book()


func _diamond(c: Vector2, half: float) -> PackedVector2Array:
	return PackedVector2Array([c + Vector2(0, -half), c + Vector2(half, 0), c + Vector2(0, half), c + Vector2(-half, 0)])


func _draw_map() -> void:
	var ahead := {}
	for i in range(run.step, run.path.size()):
		ahead[run.path[i]] = true
	for y in run.rows.size():
		for x in run.rows[y].length():
			var p := Vector2i(x, y)
			var c := _scr(Vector2(p))
			if c.y < -HALF or c.y > BAND.position.y + HALF or c.x < -HALF or c.x > 960 + HALF:
				continue
			if run.walkable(p):
				var shade := Color("#3a3a34") if (x + y) % 2 == 0 else Color("#36362f")
				draw_colored_polygon(_diamond(c, HALF), shade)
				draw_polyline(_diamond(c, HALF) + PackedVector2Array([c + Vector2(0, -HALF)]), Color("#4a4a42"), 1.0)
				if ahead.has(p):
					draw_circle(c, 2.5, Color("#c8a040", 0.45))
				if run.rows[y][x] == "X":
					draw_polyline(_diamond(c, HALF - 4) + PackedVector2Array([c + Vector2(0, -HALF + 4)]), GOLD, 2.0)
			elif _near_floor(p):
				draw_colored_polygon(_diamond(c, HALF), Color("#22201f"))
				draw_polyline(_diamond(c, HALF) + PackedVector2Array([c + Vector2(0, -HALF)]), Color("#2c2a28"), 1.0)
	for p in run.pickups:
		var c2 := _scr(Vector2(p))
		var col := Color(data["ingredients"][run.pickups[p]]["col"])
		draw_circle(c2, 8, col)
		draw_arc(c2, 8, 0, TAU, 16, col.lightened(0.4), 1.5)


func _near_floor(p: Vector2i) -> bool:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if run.walkable(p + Vector2i(dx, dy)):
				return true
	return false


## Everyone standing on the map, the ones further back drawn first.
func _draw_actors() -> void:
	var hp := run.hero_pos()
	var list: Array = []  # [tile, size, asset, colour]
	for f in run.foes:
		var lunge := Vector2.ZERO
		if f["frame"] == "attack":
			lunge = (hp - Vector2(f["tile"])) * 0.3
		list.append([Vector2(f["tile"]) + lunge, Vector2(38, 54), "%s_%s" % [data["enemy"]["asset"], f["frame"]], Color("#9a7ab0")])
	var lunge2 := Vector2.ZERO
	if run.hero["frame"] == "attack" and run.foe != null:
		lunge2 = (Vector2(run.foe["tile"]) - hp) * 0.3
	list.append([hp + lunge2, Vector2(30, 44), "knight_" + String(run.hero["frame"]), Color("#5a8ac8")])
	list.sort_custom(func(a, b): return a[0].x + a[0].y < b[0].x + b[0].y)
	for a in list:
		_actor(a[0], a[1], a[2], a[3])


## Placeholder art: a rectangle standing on its tile, with the asset's name.
func _actor(tile: Vector2, size: Vector2, asset: String, col: Color) -> void:
	var foot := _scr(tile) + Vector2(0, 6)
	var r := Rect2(foot - Vector2(size.x * 0.5, size.y), size)
	draw_colored_polygon(_diamond(_scr(tile), HALF * 0.55), Color(0, 0, 0, 0.35))
	draw_rect(r, col.darkened(0.55))
	draw_rect(r, col, false, 2.0)
	_text_c(Vector2(r.get_center().x, r.position.y - 4), asset, 10, Color(INK, 0.8))


func _draw_hero_panel() -> void:
	var r := Rect2(8, 8, 220, 96)
	_panel(r)
	var x := r.position.x + 10
	var w := r.size.x - 20
	var h: Dictionary = run.hero
	_text(Vector2(x, r.position.y + 18), "THE KNIGHT", 13, INK)
	_bar(Rect2(x, r.position.y + 26, w, 14), h["hp"] / h["max"], Color("#4aa050"))
	var lx: float = x + w * float(data["low_hp_at"])
	draw_line(Vector2(lx, r.position.y + 24), Vector2(lx, r.position.y + 42), Color("#ffd060"), 1.5)
	_text_c(Vector2(x + w * 0.5, r.position.y + 37), "%d / %d" % [int(ceil(h["hp"])), int(h["max"])], 11, INK)
	var w_data: Dictionary = data["weapons"][data["hero"]["weapon"]]
	_text(Vector2(x, r.position.y + 56), "%s (%d)" % [w_data["special"], int(w_data["special_dmg"])], 10, DIM)
	_bar(Rect2(x + 90, r.position.y + 48, w - 90, 9), h["power"] / float(data["special_power"]["max"]), GOLD)
	var gear: Array = []
	if h["ward"] > 0.0:
		gear.append("shield ward %d" % int(h["ward"]))
	if h["venom"] > 0:
		gear.append("venom %d hit%s" % [h["venom"], "" if h["venom"] == 1 else "s"])
	_text(Vector2(x, r.position.y + 76), ", ".join(gear) if not gear.is_empty() else "shield, blade: plain", 11, Color("#b0a0e0") if not gear.is_empty() else DIM)
	_text(Vector2(x, r.position.y + 91), "fights won: %d" % run.fights_won, 10, DIM)


func _draw_foe_panel() -> void:
	if run.foe == null:
		return
	var f: Dictionary = run.foe
	var r := Rect2(732, 8, 220, 96)
	_panel(r)
	var x := r.position.x + 10
	var w := r.size.x - 20
	var e: Dictionary = data["enemy"]
	_text(Vector2(x, r.position.y + 18), String(e["asset"]).to_upper(), 13, INK)
	_bar(Rect2(x, r.position.y + 26, w, 14), f["hp"] / f["max"], Color("#c04a40"))
	_text_c(Vector2(x + w * 0.5, r.position.y + 37), "%d / %d" % [int(f["hp"]), int(f["max"])], 11, INK)
	if run.mode == "turns":
		var plan := "ATTACK %d" % int(e["attack_dmg"])
		var pcol := Color("#ffb070")
		if run.intent == "big":
			plan = "%s %d" % [String(e["big_name"]).to_upper(), int(e["big_dmg"])]
			pcol = Color("#ff7a50")
		elif run.intent == "block":
			plan = "BLOCK"
			pcol = Color("#c8c8d0")
		if run.phase == "you":
			_text(Vector2(x, r.position.y + 62), "NEXT: " + plan, 14, pcol)
		_text(Vector2(x, r.position.y + 86), "turn %d" % run.turn, 11, DIM)
	elif f["winding"]:
		_bar(Rect2(x, r.position.y + 50, w, 9), 1.0 - f["wind_t"] / float(e["big_windup"]), Color("#ff9a50"))
		_text(Vector2(x, r.position.y + 76), "%s %d in %.1fs" % [e["big_name"], int(e["big_dmg"]), maxf(0.0, f["wind_t"])], 12, Color("#ffb070"))
	if f["poison"] > 0:
		_text(Vector2(x + 130, r.position.y + 86), "poison %d" % f["poison"], 11, Color("#b080e0"))


func _draw_band() -> void:
	draw_rect(BAND, Color("#1b1a1f"))
	draw_line(BAND.position, Vector2(BAND.end.x, BAND.position.y), Color("#4a4540"), 1.5)
	# the hand
	for i in int(data["hand_cap"]):
		var r := _card_rect(i)
		if i >= run.hand.size():
			draw_rect(r, Color("#ffffff", 0.04))
			draw_rect(r, Color("#ffffff", 0.1), false, 1.0)
			continue
		var ing: Dictionary = data["ingredients"][run.hand[i]]
		var col := Color(ing["col"])
		draw_rect(r, Color("#24222a"))
		draw_rect(Rect2(r.position, Vector2(r.size.x, 5)), col)
		draw_circle(r.position + Vector2(r.size.x * 0.5, 46), 21, col)
		_text_c(r.position + Vector2(r.size.x * 0.5, 94), ing["name"], 13, INK)
		_text_c(r.position + Vector2(r.size.x * 0.5, 114), _fx_text(_full(ing["fx"])), 10, GOOD)
		var dim := not run.can_add(i)
		draw_rect(r, Color(col, 0.35 if dim else 0.9), false, 1.5)
		if dim:
			draw_rect(r, Color(0, 0, 0, 0.35))
		_text(r.position + Vector2(4, 18), str(i + 1), 10, DIM)
	# the flask
	_panel(FLASK)
	for i in int(data["flask_max"]):
		var s := _flask_slot(i)
		draw_rect(s, Color("#24222a"))
		draw_rect(s, Color("#ffffff", 0.18), false, 1.0)
		if i < run.flask.size():
			draw_circle(s.get_center(), 18, Color(data["ingredients"][run.flask[i]]["col"]))
	var brew := run.flask_effects()
	var x := FLASK.position.x + 10
	var y := FLASK.position.y + 80
	if run.flask.is_empty():
		_text(Vector2(x, y), "flask: empty", 12, DIM)
	else:
		var named: bool = brew["recipe"] != "" and run.known.has(brew["recipe"])
		var k := run.flask_fresh()
		_text(Vector2(x, y), brew["name"] + ("" if k >= 1.0 else "  %d%%" % int(round(k * 100.0))), 13, GOLD if named else INK)
		_text(Vector2(x, y + 17), _fx_text(brew["fx"]), 11, GOOD)
	if run.mode == "turns":
		_text(Vector2(FLASK.position.x + 180, FLASK.position.y + 54), "part: %d" % maxi(run.parts_left(), 0), 10, DIM)
	if run.mode == "turns" and run.state == "fight":
		_text(Vector2(FLASK.position.x + 180, FLASK.position.y + 26), "potions", 10, DIM)
		_text(Vector2(FLASK.position.x + 180, FLASK.position.y + 40), "left: %d" % maxi(run.potions_left(), 0), 10, DIM)
	_button(_btn_hand_over(), "HAND OVER", run.can_hand_over())
	_button(_btn_low(), "LOW-HP SLOT" if run.low_slot == null else "SLOT FULL", run.can_slot())
	# low-HP slot, redraw, book, end turn
	var lr := _low_rect()
	draw_rect(lr, Color("#24222a"))
	draw_rect(lr, Color("#ffd060", 0.6), false, 1.5)
	_text(lr.position + Vector2(6, 14), "LOW-HP SLOT (at %d HP)" % int(run.hero["max"] * float(data["low_hp_at"])), 10, Color("#ffd060"))
	if run.low_slot == null:
		_text(lr.position + Vector2(6, 34), "empty", 11, DIM)
	else:
		var p: Dictionary = run.low_slot
		var k := run.fresh(p)
		var line := "%s  %s" % [p["name"], "fresh" if k >= 1.0 else "%d%% strength" % int(round(k * 100.0))]
		_text(lr.position + Vector2(6, 34), line, 11, GOOD if k >= 1.0 else Color("#e0c070"))
	var rb := _btn_redraw()
	_button(rb, "REDRAW", run.redraw_ready())
	if not run.redraw_ready():
		_bar(Rect2(rb.position.x + 6, rb.end.y - 7, rb.size.x - 12, 4), run.redraw_t / run.redraw_need(), Color("#b07ad0"))
	_button(_btn_book(), "BOOK", true)
	if run.mode == "turns" and run.state == "fight":
		_button(_btn_end_turn(), "END TURN", run.your_turn())
	else:
		_text_c(_btn_end_turn().get_center() + Vector2(0, 4), "walking..." if run.state == "walk" else "fighting", 12, DIM)


func _draw_outcome() -> void:
	draw_rect(Rect2(0, 0, 960, 540), Color(0, 0, 0, 0.6))
	var won := run.outcome == "won"
	if run.outcome == "broken":
		_text_c(Vector2(480, 220), "THE MAP DIDN'T LOAD", 30, Color("#ff7a6a"))
		_button(_btn_menu(), "MENU", true)
		return
	_text_c(Vector2(480, 220), "THE KNIGHT MADE IT THROUGH" if won else "THE KNIGHT FELL", 30, GOLD if won else Color("#ff7a6a"))
	var sub := "fights won: %d" % run.fights_won
	if won:
		sub += "  ·  %d / %d HP left" % [int(ceil(run.hero["hp"])), int(run.hero["max"])]
	_text_c(Vector2(480, 256), sub, 16, INK)
	_text_c(Vector2(480, 296), "tap for another run", 13, DIM)
	_button(_btn_menu(), "MENU", true)


func _draw_menu() -> void:
	_text_c(Vector2(480, 120), "SQUIRE", 44, GOLD)
	_text_c(Vector2(480, 155), "the path", 18, DIM)
	_button(_btn_mode(0), "REAL-TIME", true)
	_button(_btn_mode(1), "TURN-BASED", true)
	_button(_btn_update(), update_label(), update_state != "checking" and update_state != "downloading")
	_text(Vector2(14, 528), "v" + Update.current(), 12, DIM)
	_button(_btn_forget(), "FORGET RECIPES", true)
	_text(Vector2(800, 492), "book: %d / %d" % [book.size(), Run.recipe_ids(data).size()], 11, DIM)


## "heal 14, shield ward 6" from {effect: amount}.
func _fx_text(fx: Dictionary) -> String:
	var parts: Array = []
	for e in Run.EFFECTS:
		if fx[e] > 0.0:
			parts.append(String(data["effects"][e]["fmt"]) % int(fx[e]))
	return ", ".join(parts)


## Every effect, at zero if missing (for _fx_text).
func _full(fx: Dictionary) -> Dictionary:
	var out := {}
	for e in Run.EFFECTS:
		out[e] = float(fx.get(e, 0.0))
	return out


# ── The book ─────────────────────────────────────────────────────────────────

func _load_book() -> void:
	book = Run.starting_book(data)
	if FileAccess.file_exists(BOOK_PATH):
		var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(BOOK_PATH))
		if typeof(saved) == TYPE_ARRAY:
			for id in saved:
				if data["recipes"].has(id):
					book[id] = true


func _save_book() -> void:
	var f := FileAccess.open(BOOK_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(book.keys()))


func _draw_book() -> void:
	draw_rect(Rect2(0, 0, 960, 540), Color(0, 0, 0, 0.7))
	var r := Rect2(150, 30, 660, 470)
	_panel(r)
	_text_c(Vector2(480, 62), "RECIPE BOOK", 22, GOLD)
	var y := 100.0
	for id in Run.recipe_ids(data):
		var rec: Dictionary = data["recipes"][id]
		var cx := r.position.x + 30
		if book.has(id):
			_text(Vector2(cx, y), rec["name"], 15, INK)
			var ix := cx + 170
			for ing in rec["ings"]:
				draw_circle(Vector2(ix, y - 5), 8, Color(data["ingredients"][ing]["col"]))
				ix += 20
			_text(Vector2(cx + 240, y), " + ".join(rec["ings"].map(func(i): return data["ingredients"][i]["name"])), 12, DIM)
			_text(Vector2(cx + 240, y + 18), _fx_text(_full(rec["fx"])), 12, GOOD)
		else:
			_text(Vector2(cx, y), "? ? ?", 15, DIM)
		y += 44
	_text(Vector2(r.position.x + 30, r.end.y - 30), "Any other mix, or one ingredient alone: an unnamed potion, the ingredients added up.", 11, DIM)
	_text(Vector2(r.position.x + 30, r.end.y - 12), "A potion waiting to be used: full strength its first turn, then half, then a tenth.", 11, DIM)
	_text_c(Vector2(480, r.end.y + 24), "tap to close", 12, DIM)


# ── Updates ──────────────────────────────────────────────────────────────────

func _check_update() -> void:
	if http == null:
		http = HTTPRequest.new()
		add_child(http)
		http.request_completed.connect(_on_release)
	update_state = "checking"
	if http.request(Update.API, ["User-Agent: Squire-path", "Accept: application/vnd.github+json"]) != OK:
		update_state = "failed"


func _on_release(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var rel := {}
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		rel = Update.read_release(body.get_string_from_utf8())
	if rel.is_empty():
		update_state = "failed"
		return
	update_tag = rel.tag
	update_url = rel.url
	update_page = rel.page
	update_state = "new" if Update.newer(update_tag, Update.current()) else "latest"


## Download the new APK in the game, then hand it to Android's installer.
func _download_update() -> void:
	if download == null:
		download = HTTPRequest.new()
		download.use_threads = true
		download.download_file = Update.APK
		add_child(download)
		download.request_completed.connect(_on_downloaded)
	update_state = "downloading"
	if download.request(update_url, ["User-Agent: Squire-path"]) != OK:
		update_state = "download_failed"


func _on_downloaded(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200 or not FileAccess.file_exists(Update.APK):
		update_state = "download_failed"
		return
	update_state = "ready"
	Update.install()


func update_label() -> String:
	match update_state:
		"checking":
			return "CHECKING..."
		"latest":
			return "UP TO DATE"
		"new":
			return "UPDATE TO " + update_tag
		"downloading":
			var size := download.get_body_size()
			if size > 0:
				return "DOWNLOADING %d%%" % (100 * download.get_downloaded_bytes() / size)
			return "DOWNLOADING..."
		"ready":
			return "INSTALL " + update_tag
		"download_failed":
			return "FAILED. RETRY"
	return "CHECK FOR UPDATES"


func _update_tap() -> void:
	match update_state:
		"new", "download_failed":
			if OS.get_name() == "Android":
				_download_update()
			else:
				OS.shell_open(update_page)
		"ready":
			Update.install()
		"checking", "downloading":
			pass
		_:
			_check_update()


# ── Helpers ──────────────────────────────────────────────────────────────────

func _panel(r: Rect2) -> void:
	draw_rect(r, Color("#201e24", 0.92))
	draw_rect(r, Color("#4a4540"), false, 1.5)


func _bar(r: Rect2, frac: float, col: Color) -> void:
	draw_rect(r, Color("#0e0d10"))
	draw_rect(Rect2(r.position, Vector2(r.size.x * clampf(frac, 0.0, 1.0), r.size.y)), col)
	draw_rect(r, Color("#ffffff", 0.15), false, 1.0)


func _button(r: Rect2, label: String, on: bool) -> void:
	draw_rect(r, Color("#3a3428") if on else Color("#24222a"))
	draw_rect(r, GOLD if on else Color("#ffffff", 0.12), false, 2.0 if on else 1.0)
	_text_c(r.get_center() + Vector2(0, 5), label, 13, INK if on else DIM)


func _text(p: Vector2, s: String, size: int, col: Color) -> void:
	draw_string(_font, p, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


func _text_c(p: Vector2, s: String, size: int, col: Color) -> void:
	var w := _font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	draw_string(_font, p - Vector2(w * 0.5, 0), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
