# Z-Deathmatch 0.2.2 (experimental)

**[Download ZIP](dist/Z-Deathmatch-0.2.2.zip?raw=true)**

Host-only zombie competition for Bodycam: up to **6 human players**, with **7 living zombies per eligible connected player**, at least **10** and capped at **42**. The targets for 1–6 eligible players are **10 / 14 / 21 / 28 / 35 / 42**; with none, the target is zero. Friends can join and leave without this mod. No game assets are included.

## Install and play

1. Install UE4SS with game-thread timer support (`LoopInGameThreadWithDelay` and `CancelDelayedAction`). This mod requires those APIs.
2. Close Bodycam. Download the ZIP above and extract it **directly into your Bodycam game folder** (the folder containing the `Bodycam` subfolder). The archive already includes `Bodycam/Binaries/Win64/ue4ss/Mods/BodycamZombieChill`.
3. Restart Bodycam, open the hosting menu, choose **Z-Deathmatch**, and select an installed map. The older zombie-unlock test mod is not required.

From source instead: copy `mod/BodycamZombieChill` into your game folder's `Bodycam/Binaries/Win64/ue4ss/Mods/` directory.

Zombies spawn automatically during the **30-second preparation**, followed by a **5-minute scored round**. Death does not restart the clock. All owned zombies are removed before the game's normal next-map vote. F10 manually starts/stops preparation or the round.

## Rules

- Zombie kill: **+1 point**. Your death: **-5 from positive points**, stopping at zero; an already negative score stays unchanged.
- Killing another player: **-5**, including below zero. At **-15 or lower**, spectate until the round ends.
- **Puppetmaster**, an internal virtual opponent, earns **+5** per confirmed player kill by an owned zombie. Zombie deaths add to its death count without a points penalty. It uses no human slot and can win.
- Highest eligible points win; ties share the win. **80%** of zombies may run after an individual **1–4-second perception delay**. Each runner has a one-time **25% chance of 20% extra running speed** (450 instead of 375). Their sight and lose-sight ranges are increased by **80%** (1.8×).
- Temporary player deaths keep the zombie target unchanged; eliminated spectators do not count. When someone leaves, existing zombies remain and new spawning waits for the lower target.

## Limits and removal

Spawning and stalled-path recovery are best effort and need usable map navigation. Stalled zombies are checked after **3 seconds**, with failed retries delayed **5–30 seconds**. Supported Ultra Dynamic Sky maps cycle from **18:00 to 06:00 during the 5-minute match**; baked lighting and lighting on unmodded guests may not follow it.

The native Tab scoreboard does **not** show weighted mod points or Puppetmaster. No custom winner notice is implemented; final mod scores are in `Scripts/status.json`.

Automated checks use mocked Unreal interfaces and do not establish full live reliability across maps or six-player sessions. Modless guest play has been observed; the 0.2.2 changes and the 42-zombie limit still need live validation.

Restart Bodycam after updates; live reload is disabled. To uninstall, close the game and remove `BodycamZombieChill` from UE4SS's `Mods` folder.
