# Z-Deathmatch 0.2.2 (experimental)

**[Download ZIP](dist/Z-Deathmatch-0.2.2.zip?raw=true)**

A zombie competition for Bodycam with up to **6 players**. The host installs the mod; friends join through Steam using the standard game.

## Install and play

1. Install UE4SS with game-thread timer support (`LoopInGameThreadWithDelay` and `CancelDelayedAction`).
2. Close Bodycam. Download the ZIP and extract it **directly into your Bodycam game folder** — the folder containing the `Bodycam` subfolder.
3. Start Bodycam, open the hosting menu, choose **Z-Deathmatch**, and select a map.

The installed mod folder is `Bodycam/Binaries/Win64/ue4ss/Mods/BodycamZombieChill`. For a source installation, copy `mod/BodycamZombieChill` into that `Mods` directory.

## Match

- Zombies spawn automatically during **30 seconds of preparation**, followed by a **5-minute scored round**.
- The target population is **7 zombies per eligible player**, with a minimum of **10** and a maximum of **42**. For 1–6 players: **10 / 14 / 21 / 28 / 35 / 42**.
- Players can join and leave throughout the round. Spawning adjusts to the current player count.
- **80%** of zombies start running **1–4 seconds after spotting a player**. Each runner has a **25% chance of running 20% faster**. Zombies have **80% greater sight and lose-sight ranges**.
- Zombies retry stalled pursuit using the map's navigation.
- Supported Ultra Dynamic Sky maps provide a host-side sky cycle from **18:00 to 06:00** over the match.
- At round end, zombies despawn and the game's standard map vote opens.

## Scoring

- Zombie kill: **+1 point**.
- Death: **−5 points from a positive score**, down to zero.
- Killing another player: **−5 points**, including below zero. At **−15 or lower**, the player becomes a spectator for the rest of the round.
- **Puppetmaster**, a virtual opponent, earns **+5 points** whenever one of the mod's zombies kills a player. Its death count tracks killed zombies.
- The highest eligible score wins, including Puppetmaster. Tied scores share the win.

**Tab** shows the game's kill/death statistics. The mod's points and round result are saved in `Scripts/status.json`.

## Controls and updates

**F10** starts or stops preparation or the current round.

Close Bodycam before updating the mod, then start the game again. To uninstall, close Bodycam and remove `BodycamZombieChill` from UE4SS's `Mods` folder.
