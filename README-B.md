# AD Draft AutoShot B - swap correction via the Steam Web API

Same idea as AutoShot: the draft screenshot is taken automatically the moment
the game switches from drafting to STRATEGY TIME. **New in B:** players can
still swap heroes after that (during strategy time and in pre-game, right up
to the horn). The board on screen goes wrong the moment that happens (names
vanish, models switch), which is why the screenshot is still taken right at
the start of strategy time. Version B then pulls the **live roster of the
match from Valve's API** every few seconds until the horn, and whenever two
players have traded heroes it **exchanges their two names inside
`screenshot.png`**. Your overlay keeps pointing at the same file and simply
shows the corrected board.

Pure Windows PowerShell (Windows 10/11), nothing to install. What you need:

- a **Steam Web API key** (free, one minute): https://steamcommunity.com/dev/apikey
  (any domain name works, e.g. `localhost`; the Steam account must not be a
  limited account)
- your Steam profile with **Game details = Public** (Profile > Edit Profile >
  Privacy Settings). That is how the tool finds the game server your match
  runs on. If you do not want that, put the steam64 id of a teammate who has
  it public into the config (`ExtraSteamIds`).
- Dota UI language English (the board is read by text to know which card is
  which hero)

## Files

- `autoshot-b.ps1` - the listener (screenshot + roster watcher)
- `start_autoshot-b.bat` - starts it. This is the only thing you run.
- `autoshot-b.config.example.json` - copy to `autoshot-b.config.json` and paste your key
- `heroes.json` - hero list (ids and names)
- `gamestate_integration_autoshot.cfg` - the Dota config (goes into the Dota folder, see below). Version B's copy also reports your own steam id, so the tool finds your match by itself.

You can keep the original `autoshot.ps1` in the folder; just run only one of
the two listeners at a time (both use port 3211).

## Setup

1. Put the folder somewhere permanent, e.g. `C:\screenshot\`. Point your
   Streamlabs / OBS image sources at `screenshot.png` in that folder (same as
   before, nothing changes for existing setups).
2. Copy `autoshot-b.config.example.json` to `autoshot-b.config.json` and put
   your Steam Web API key into `SteamApiKey`.
3. Dota config (one time): Steam > Library > right-click Dota 2 > Manage >
   Browse local files, then `game\dota\cfg\gamestate_integration\` (create the
   folder if missing). Copy `gamestate_integration_autoshot.cfg` there
   (overwrite the version A file, the new one has one extra line). Restart
   Dota if it was running.
4. Double-click `start_autoshot-b.bat`. Leave the window open (minimized is
   fine).

Dota on the primary monitor, 16:9 recommended (1080p, 1440p, 4K). Borderless
window if screenshots come out black.

## What you will see in the console

```
[20:01:12] HERO_SELECTION -> STRATEGY_TIME : capturing in 500ms
[20:01:13] screenshot saved -> C:\screenshot\screenshot.png (2560x1440)
[20:01:14] board: Radiant card 1 = sniper
...
[20:01:15] board: Dire card 5 = slark
[20:01:15] watching the live roster every 5 s until the horn
[20:01:17] match server id: 90212345678901234
[20:01:17] roster baseline: R: Gaben=sniper, ...  |  D: ...
[20:01:37] SWAP: Gaben now plays primal_beast, dante now plays sniper -> names exchanged on the board
[20:01:37] screenshot.png rewritten with 1 name swap(s)
[20:03:10] horn: one final roster check
[20:03:14] final roster check: no swap
[20:03:14] watcher done for this game (1 swap(s) corrected)
```

`screenshot.base.png` is the untouched capture, `screenshot.png` the
corrected one. `debug_board.png` shows what was read on the board (yellow =
hero name box, cyan = the name strip that gets exchanged).

## How it decides that a swap happened

- The board is read once at capture time: which hero is on which card.
- The first complete roster from the API (10 players, everyone has a hero)
  is the baseline: who drafted what.
- Every 5 seconds the roster is pulled again. When two players of the same
  team now hold each other's heroes, that is a swap: the two name strips on
  the board are exchanged, pixel for pixel, starting from the untouched
  capture each time. Nothing is redrawn, so it looks exactly like the game
  rendered it. Swapping back is handled too.
- One last check a few seconds after the horn, then the watcher stops until
  the next draft.

A swap that is completed before the baseline roster is fetched (within the
first ~2 seconds of strategy time) cannot be told apart from the draft and is
not corrected. A card whose hero name could not be read is reported in the
console; swaps involving it are logged but not corrected. Non-English UI:
set `"AssumeBoardOrderMatchesRoster": true` if in your games the card order
on the board always equals the team slot order the API reports; then no text
reading is needed.

## Calibration

Run this from a PowerShell window in the folder while the STRATEGY TIME
screen is up (a bot match works):

```
powershell -ExecutionPolicy Bypass -File .\autoshot-b.ps1 -Calibrate
```

It waits 3 seconds, captures the screen, writes `calibration.png` with the
boxes drawn and prints the ten hero names it read. Yellow boxes must cover
the hero names, cyan boxes the player names. If they are off, override the
numbers in `autoshot-b.config.json`:

```json
{ "HudCenterOffset": 0, "Layout": { "RowTop0": 0.1426, "RowPitch": 0.1562 } }
```

All layout numbers are fractions of the screen height, x relative to the
screen center. Every key from the `$L` block at the top of the script can be
overridden.

## Troubleshooting

- **Console shows nothing during a game**: cfg not in the right folder, or Dota not restarted after copying it.
- **"match server not found yet" forever**: your Game details are not public, or Steam has not registered the match yet. Make them public, or add a teammate's steam64 to `ExtraSteamIds`.
- **"roster not complete yet" forever**: the API sometimes lags a few seconds after the draft; if it never completes, the match is not on a Valve server (custom lobbies on local servers are not covered).
- **"Windows OCR not available"**: Settings > Time & Language > Language > add English (United States) with the "Basic typing" / OCR feature.
- **Port in use**: change `$Port` at the top of `autoshot-b.ps1` and in the .cfg.
