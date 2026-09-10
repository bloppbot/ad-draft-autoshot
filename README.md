# AD Draft AutoShot - automatic draft screenshot

Takes the Ability Draft screenshot **automatically** at the exact moment the
game switches from drafting to STRATEGY TIME. No hotkey needed anymore: draft
ends, screenshot happens, your Streamlabs overlay updates itself.

Works while **playing** (not only spectating): it uses Dota's official Game
State Integration, which reports your own game's phase changes. No game files
are modified and it is completely allowed (no anti-cheat risk, this is a
Valve-provided feature for streamers).

**Download:** click the green **Code** button above > **Download ZIP**, then
unzip it anywhere.

## Version B: swap correction via the Steam Web API (new)

Players can still swap heroes after the draft (strategy time, pre-game, up to
the horn), which makes the captured board wrong. **Version B** takes the same
screenshot, then pulls the live roster of your match from Valve's API until
the horn and, when two players trade heroes, exchanges their names inside
`screenshot.png`. Needs a free Steam Web API key and public game details on
your Steam profile. Run `start_autoshot-b.bat` instead of `start_autoshot.bat`
and read **[README-B.md](README-B.md)** ([по-русски](README-B.ru.md)).
Version A below stays as the simple option.

## Files

- `autoshot.ps1` - the listener that waits for the phase change and takes the screenshot. Pure Windows PowerShell, nothing to install.
- `start_autoshot.bat` - starts the listener. This is the only thing you run.
- `gamestate_integration_autoshot.cfg` - the config that tells Dota to report game phases. Goes into your Dota folder (step 2).

## Setup

### Step 1: Put this folder somewhere permanent

For example `C:\screenshot\`. If you already have a manual screenshot hotkey
setup (e.g. an AutoHotkey script), put these files in the SAME folder: the
automatic screenshot is saved as `screenshot.png` right next to
`autoshot.ps1`, so your existing Streamlabs image sources keep working
without any change. The hotkey keeps working too, as a manual backup.

If you set up fresh: in Streamlabs/OBS add Image sources pointing at
`screenshot.png` in this folder (typically one source per team, cropped to
the Radiant / Dire half of the draft screen).

### Step 2: Install the Dota config (this is "installing GSI", one-time)

1. Open Steam > Library > right-click **Dota 2** > **Manage** > **Browse local files**. A folder opens.
2. In that folder, go into: `game` > `dota` > `cfg` > `gamestate_integration`.
   If the `gamestate_integration` folder does not exist, create it (right-click > New > Folder, name it exactly `gamestate_integration`).
3. Copy `gamestate_integration_autoshot.cfg` from this kit into that folder.
4. Restart Dota if it was running.

That's all GSI is: one config file that tells Dota "report the game phase to
this local address". Dota does the rest by itself.

### Step 3: Start the listener

Double-click `start_autoshot.bat`. A console window opens and logs what's
happening. Leave it open (minimized is fine). Screenshot triggers only work
while this window is running.

Autostart with Windows (optional): press Win+R, type `shell:startup`, Enter,
and put a shortcut to `start_autoshot.bat` into the folder that opens.

## Test it (2 minutes)

Start the listener, then create a bot match / lobby in Ability Draft mode and
draft. The console window logs every phase change, and the moment the game
jumps to STRATEGY TIME you'll see "screenshot saved". Done.

## Troubleshooting

- **Console shows nothing during a game**: the .cfg is not in the right folder, or Dota wasn't restarted after copying it.
- **Window closes immediately on start**: start `start_autoshot.bat` again; if it keeps happening, another program is using port 3211. Change `$Port` at the top of `autoshot.ps1` AND the port in the .cfg to e.g. 3212.
- **Screenshot is black**: switch Dota from Exclusive Fullscreen to Borderless Window (Video settings).
- **Wrong monitor**: the capture takes the primary monitor. Dota must run on the primary monitor.

## Tuning (top of autoshot.ps1)

- `$DelayMs` - wait after the phase flip before capturing (default 500 ms)
- `$CooldownSec` - re-trigger guard (default 60 s)

---

Built by [BloppBOT](https://github.com/bloppbot) for the Ability Draft
community. MIT licensed: use it, share it, break it, fix it.
