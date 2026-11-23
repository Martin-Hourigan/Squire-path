# Squire (path)

The hero walks a set path through a string of rooms and fights on their own.
You're their alchemist squire: you never fight, you brew potions and hand
them over. Brewing and the recipe book come from ../Squire-alchemist.

- Top-down on a square grid turned 45 degrees (rooms are diamonds); the
  camera follows the hero. Placeholder rectangles for the knight and brutes.
- The map is `data/map.txt`: `S` start, `X` end, `E` a brute, `r b n h`
  ingredients lying on the floor (Redcap, Ironbark, Nightshade, Honey), `#`
  rock. The path goes from S past every brute (nearest first) to X.
- Walking over an ingredient picks it up (into your hand if there's room,
  else into the bag). A brute on the path stops the hero for a fight. HP
  carries on from fight to fight. Reach X to win the run.

## Brewing

- Put 1-3 ingredients in the flask, then HAND OVER, or put it in the LOW-HP
  SLOT (used by itself when HP drops to 30%).
- Potions: heal; shield ward (soaks up that much damage); venom (the blade
  is coated for that many hits; each hit adds 3 poison, which takes that
  much HP every tick and then goes down by 1).
- Two or three ingredients that match a RECIPE brew a named potion: a pair
  about 3x one ingredient, a full recipe about 5x. Anything else is an
  unnamed potion, the ingredients added up. The book starts with Salve,
  Healing Draught and Shield Oil; brewing an unknown recipe or winning a
  fight teaches more. FORGET RECIPES on the menu resets the book.
- FRESHNESS: the flask is full strength on the turn an ingredient goes in
  and the turn after; then it fades each turn, down to nothing: one
  ingredient loses 50% a turn, two 35%, three 10%. Adding an
  ingredient makes it full again, so a full flask (3 ingredients) can only
  fade. A brewed potion keeps fading until it's used (the low-HP slot, or
  one handed over while the hero is busy). Real time counts a turn as 2 s.

## REAL-TIME

The hero walks on their own (2.5 tiles a second) and fights on their own
(attacks every 2 s; Big Slash when power is full). The brute attacks every
2.5 s, every 4th a telegraphed Big Swing. No ingredients are drawn on their
own; REDRAW (15 s meter) swaps your hand.

## TURN-BASED

One ingredient goes into the flask a turn, so a full recipe takes three
turns to put together (taking back this turn's ingredient gives the turn
back). Walking, each tile is a turn (a tile every 0.4 s). In a fight: your
turn (add an ingredient, hand over at most one potion, used straight away), END TURN, the hero attacks
(a brute that showed BLOCK stops the first hit), poison ticks, the brute
does what it showed; the hero always blocks, taking half. 2 ingredients
drawn each fight turn; REDRAW every 3 turns.

Every number is a PLACEHOLDER in `data/game.json`.

## Controls

Tap an ingredient to put it in the flask, a flask ingredient to take it back,
then HAND OVER / LOW-HP SLOT / REDRAW / BOOK / END TURN. Keys: 1-5, Q, W, R,
B, Space, Backspace (empty flask), Esc or phone back (menu).

## Phone

Public repo github.com/Martin-Hourigan/Squire-path; the APK is on the
release page and the menu's update button installs new versions.
`build_apk.bat` builds `build/Squire-path.apk`;
`python tools/release.py X.Y "notes"` publishes a new version.

## Files

- `data/game.json` - all numbers, ingredients, recipes, the bag
- `data/map.txt` - the rooms and the path
- `scripts/run.gd` - the rules (no drawing)
- `scripts/run_view.gd` - the menu, the map, the hand and flask, the book
- `scripts/update.gd` - checking GitHub for a newer release
- `tests/sim_test.gd` - headless bots play whole runs in both modes:
  `godot --headless --path . --script res://tests/sim_test.gd`
