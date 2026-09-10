# AD Draft AutoShot B - the swap-aware version

Same idea as AutoShot: the draft screenshot is taken automatically the moment
the game switches from drafting to STRATEGY TIME. **New in B:** players can
still swap heroes after that (strategy time, pre-game, right up to the horn),
and then the board on your overlay shows the wrong names. Version B watches
the hero portraits in the top bar until the horn, and whenever two players
trade heroes it **exchanges their names inside `screenshot.png`**. Your
overlay keeps pointing at the same file and simply shows the corrected board.

No API key, no account, nothing to install. Pure Windows PowerShell (Windows
10/11). The hero portraits it compares against are downloaded once from
Valve's own CDN (about 8 MB) into `%LOCALAPPDATA%\ad-draft-autoshot`.

## Files

- `autoshot-b.ps1` - the listener (screenshot + swap watcher)
- `start_autoshot-b.bat` - starts it. This is the only thing you run.
- `heroes.json` - hero list (names) used for reading the board
- `gamestate_integration_autoshot.cfg` - the Dota config, same file as version A (goes into the Dota folder, see below)

You can keep the original `autoshot.ps1` in the folder; just run only one of
the two listeners at a time (both use port 3211).

## Setup

1. Put the folder somewhere permanent, e.g. `C:\screenshot\`. Point your
   Streamlabs / OBS image sources at `screenshot.png` in that folder (same as
   before, nothing changes for existing setups).
2. Dota config (one time): Steam > Library > right-click Dota 2 > Manage >
   Browse local files, then `game\dota\cfg\gamestate_integration\` (create the
   folder if missing). Copy `gamestate_integration_autoshot.cfg` there.
   Restart Dota if it was running.
3. Double-click `start_autoshot-b.bat`. Leave the window open (minimized is
   fine). The first start downloads the hero portraits.

Requirements for the swap correction (the screenshot itself always works):

- Dota UI language **English** (the board is read by text; "PUDGE", "STORM
  SPIRIT"...). Any Windows OCR language pack that covers Latin letters works;
  Windows installs one with your display language.
- Dota on the primary monitor, 16:9 recommended (1080p, 1440p, 4K all fine).
  Other aspect ratios: run the calibration below and check the boxes.
- Borderless window mode if screenshots come out black.

## What you will see in the console

```
[20:01:12] HERO_SELECTION -> STRATEGY_TIME : capturing in 500ms
[20:01:13] screenshot saved -> C:\screenshot\screenshot.png (2560x1440)
[20:01:14] board: Radiant card 1 = sniper
...
[20:01:15] board: Dire card 5 = slark
[20:02:40] pre-game: watching the top bar for hero swaps every 3 s
[20:02:42] top bar baseline (10/10): R: sniper, tinker, ...  |  D: kunkka, ...
[20:03:01] possible swap seen (0-2), confirming on next reading
[20:03:04] SWAP detected: the player who drafted sniper now plays primal_beast (and vice versa) -> names exchanged on the board
[20:03:04] screenshot.png rewritten with 1 name swap(s)
[20:04:10] horn: one final reading
[20:04:12] watcher done for this game (1 swap(s) corrected)
```

`screenshot.base.png` is the untouched capture, `screenshot.png` is the
corrected one. `debug_board.png` / `debug_topbar.png` show what was read
(yellow = hero name box, cyan = the name strip that gets exchanged, green =
recognized portrait, red = not recognized).

## Calibration (do this once, or when something is not recognized)

Run this from a PowerShell window in the folder, during a game (after the
horn is fine, any mode, the top bar just has to be visible):

```
powershell -ExecutionPolicy Bypass -File .\autoshot-b.ps1 -Calibrate
```

It waits 3 seconds, captures the screen, writes `calibration.png` with all
detection boxes drawn and prints the ten heroes it recognized in the top bar.
Green boxes must sit on the ten portraits. To check the board part, run the
same command while the STRATEGY TIME screen is up: the yellow boxes must
cover the hero names, the cyan boxes the player names, and the console lists
the ten hero names it read.

If the boxes are off, create `autoshot-b.config.json` next to the script:

```json
{
  "HudCenterOffset": 0,
  "Layout": { "TopRadiantX": -0.386, "TopDireX": 0.102, "TopPitch": 0.0578 }
}
```

All numbers are fractions of the screen height, x relative to the screen
center. Every key from the `$L` block at the top of the script can be
overridden here, and so can `PollSec`, `MinSlotScore`, `DebugImages`, etc.

## How it decides that a swap happened

- The board is read once at capture time: which hero is on which card.
- From pre-game on, the ten top-bar portraits are matched against the hero
  art every 3 seconds. The first clean reading (at least 8 of 10 heroes
  recognized, no duplicates) is the baseline.
- Dota only allows swaps within a team, so a swap shows up as two portraits
  of the same team trading places. It has to be seen in two consecutive
  readings before it is applied (no flicker corrections).
- Correction = the two name strips on the board are exchanged, pixel for
  pixel, starting from the untouched capture each time. Nothing is redrawn,
  so it looks exactly like the game rendered it.
- One last reading right after the horn, then the watcher stops until the
  next draft.

Known limits: a swap that completes within the first second of pre-game,
before the baseline reading, is not seen. A card whose hero name could not
be read is reported in the console; swaps involving it are logged but not
corrected. Non-English UI: set `"AssumeBoardOrderMatchesTopBar": true` in the
config if in your games the card order on the board always matches the
top-bar order; then no text reading is needed at all.

## Troubleshooting

- **Console shows nothing during a game**: cfg not in the right folder, or Dota not restarted after copying it.
- **"Windows OCR not available"**: Settings > Time & Language > Language > add English (United States) with the "Basic typing" / OCR feature.
- **Portraits not recognized (all red in `debug_topbar.png`)**: run `-Calibrate` and fix the layout numbers, or set `HudCenterOffset` if your HUD is not centered (second monitor, custom HUD scale).
- **Port in use**: change `$Port` at the top of `autoshot-b.ps1` and in the .cfg.
