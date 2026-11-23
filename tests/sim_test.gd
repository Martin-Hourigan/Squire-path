extends SceneTree
## Headless: plays whole runs with simple squire bots, in both modes, to check
## nothing gets stuck. idle = never brews; single = hands over every
## ingredient alone at once; recipes = brews recipes it holds (Healing
## Draught kept in the low-HP slot), redraws when it holds none; in turns it
## puts one ingredient in a turn and hands over when the recipe is done.
##   godot --headless --path . --script res://tests/sim_test.gd

const RUNS := 100
const DT := 0.05


func _init() -> void:
	var data := Run.load_data()
	var map := Run.load_map()
	var errors := 0
	var probe := Run.new()
	probe.setup(data, map, 1)
	print("path: %d tiles, %d enemies, %d pickups" % [probe.path.size(), probe.foes.size(), probe.pickups.size()])
	if probe.foes.size() != 2 or probe.path.back() != Vector2i(24, 25):
		errors += 1
		print("FAIL map")
	for mode in ["realtime", "turns"]:
		for bot in ["idle", "single", "recipes"]:
			var through := 0
			var fights := 0
			for r in RUNS:
				var run := Run.new()
				run.setup(data, map, 1000 + r, mode, Run.starting_book(data))
				while run.outcome == "" and run.t < 900.0:
					if run.your_turn():
						_bot(run, bot)
						run.end_turn()
					run.step_time(DT)
					run.events.clear()
				if run.outcome == "":
					errors += 1
				through += 1 if run.outcome == "won" else 0
				fights += run.fights_won
			print("%-8s %-8s made it through %3d%%   fights won %.1f" % [mode, bot, 100 * through / RUNS, float(fights) / RUNS])
	print("errors: %d" % errors)
	quit(1 if errors else 0)


func _bot(run: Run, bot: String) -> void:
	if bot == "idle":
		return
	if bot == "single":
		while not run.hand.is_empty() and run.add_to_flask(0) and run.hand_over():
			pass
		return
	if run.state != "fight":
		return
	if run.redraw_ready() and Run.recipe_ids(run.d).all(func(r): return not _can(run, r)):
		run.redraw()
	if run.mode == "turns":
		_bot_turns(run)
		return
	if run.low_slot == null and _brew(run, run.d["recipes"]["healing_draught"]["ings"]):
		run.to_low_slot()
	for r in ["iron_tonic", "shield_oil", "venom_oil", "bitter_edge", "salve", "iron_wash", "venom_drop"]:
		if _brew(run, run.d["recipes"][r]["ings"]):
			run.hand_over()


func _bot_turns(run: Run) -> void:
	var goal: String = run.get_meta("goal", "")
	if run.flask.is_empty():
		goal = ""
		for r in ["healing_draught", "iron_tonic", "shield_oil", "venom_oil", "bitter_edge", "salve", "iron_wash", "venom_drop"]:
			if (r != "healing_draught" or run.low_slot == null) and _can(run, r):
				goal = r
				break
		run.set_meta("goal", goal)
	if goal == "":
		return
	var ids: Array = run.d["recipes"][goal]["ings"].duplicate()
	for id in run.flask:
		ids.erase(id)
	if not ids.is_empty():
		run.add_to_flask(run.hand.find(ids[0]))
	if run.flask.size() == run.d["recipes"][goal]["ings"].size():
		if goal == "healing_draught":
			run.to_low_slot()
		else:
			run.hand_over()


func _can(run: Run, r: String) -> bool:
	var ids: Array = run.d["recipes"][r]["ings"]
	for id in ids:
		if run.hand.count(id) < ids.count(id):
			return false
	return true


func _brew(run: Run, ids: Array) -> bool:
	if not _have(run, ids):
		return false
	for id in ids:
		run.add_to_flask(run.hand.find(id))
	return true


func _have(run: Run, ids: Array) -> bool:
	if not run.flask.is_empty() or run.potions_left() <= 0:
		return false
	for id in ids:
		if run.hand.count(id) < ids.count(id):
			return false
	return true
