# Bodycam Zombie Modes

## Current: Zombie Variants 0.1.0 candidate (2026-10-22)

**[Download the current Zombie Variants ZIP](dist/Zombie-Variants-0.1.0-candidate-20261022.zip?raw=true)**

Adds zombies to the available native game modes, including **Z-Team Deathmatch** and **Z-Deathmatch (Classic)**. Native objectives and player-versus-player scoring remain in place. This is a separate `BodycamZombieVariants` host mod; the original Z-Deathmatch 0.2.2 remains available below.

### Gameplay

- Zombies take normal full body and head damage, including the game's normal weapon bonuses and grenade falloff.
- Population follows adaptive **45-second waves** with quieter phases: up to **14 living zombies** and **8 retained corpses**.
- Player and match-bot deaths can create zombies at their death positions. With a valid killer, these zombies immediately run at that killer. Body hits trigger faster pursuit, and other zombies occasionally sprint on their own.
- Native zombie voices accompany pursuit, sprinting and attacks. Zombie ragdolls remain for up to **25 seconds**. A successful death-location spawn hides the corresponding player corpse.
- In native score-limit modes, **five credited zombie kills award one match point**, pooled by team in Team Deathmatch. Personal kill/death counters and XP are unchanged by zombie kills.
- Supported outdoor maps hold **18:00**, rain, full cloud cover and softer, darker fog. The latest update slightly increases diffuse ambient illumination. Indoor maps keep their native lighting where no supported sky exists.
- **At native round end, all owned zombies and zombie corpses are removed.** Replenishment pauses through intermission and restarts in the next active round. Failed cleanup remains tracked before new spawns are allowed.

### Install or update

1. Install a compatible UE4SS runtime with game-thread timers. The candidate is pinned to the inspected Bodycam Steam build **25505592** and the exact game/UE4SS hashes in its manifest; the installer rejects mismatches. UE4SS and game files are not bundled.
2. **Close Bodycam completely.** Extract the downloaded ZIP into a separate folder.
3. Open PowerShell in that extracted folder and run:

   ```powershell
   .\Install.ps1 -GameDirectory 'C:\Program Files (x86)\Steam\steamapps\common\Bodycam\Bodycam\Binaries\Win64'
   ```

   Adjust the path to your actual `Bodycam\Binaries\Win64` folder. For an existing Zombie Variants installation, add `-UpdateExisting`. Use `-ValidateOnly` to check the package and supported binaries without installing.
4. Start Bodycam normally, open the private hosting menu and choose a new `Z-` variant. The installer refuses a running game, retains a backup on updates and leaves the original `BodycamZombieChill` mod untouched.

The Lua source and native companion are in [mod/BodycamZombieVariants](mod/BodycamZombieVariants). Use the downloadable ZIP for installation: its installer, manifest and mod folder must stay together. Do not replace files or reload the mod during play. To uninstall, close the game and remove only `BodycamZombieVariants` from UE4SS's `Mods` directory.

### Verification status

The exact downloadable package passed **1,998 offline checks**, and all **17 installed package files** were verified against its manifest. Earlier CQB playtests confirmed zombie spawning, voices, waves, rain, fog and corpse handling. **The latest round-end cleanup and small ambient-light increase still await their cold in-game acceptance test.** Guest behavior and rendering without the host's mod remain unverified. Historical Cemetery bells/choir have not been identified, so round-boundary music remains muted.

ZIP SHA-256: `8f9fa86588d3e5f41ad276f85c51d96ff94bf09eafe74ee0f739afa747e6dd8d`

See [package notes](docs/Zombie-Variants-20261022.md) for this update and [detailed behavior](mod/BodycamZombieVariants/README.md) for configuration and limits.

## Original Z-Deathmatch 0.2.2 (unchanged)

**[Download original Z-Deathmatch](dist/Z-Deathmatch-0.2.2.zip?raw=true)** | **[Original gameplay and installation guide](docs/Z-Deathmatch-0.2.2.md)**

This separate mode retains its original six-player zombie competition, scoring and round rules. Its published ZIP and `mod/BodycamZombieChill` files are unchanged by the Zombie Variants update.
