# Zombie Variants candidate - 2026-10-22

Published on 2026-10-23. Package version: `0.1.0-candidate`; scope: `ambient_round_end`.

This publication carries the exact package installed and verified on 2026-10-22. It adds the new native-mode Z variants alongside the existing Z-Deathmatch 0.2.2 download.

The latest change removes all owned living zombies and retained zombie corpses at native round end using the existing 500 ms update. Spawns pause during intermission, old death requests are discarded, and a changed round identity also catches transitions between updates. Failed cleanup keeps its ownership/score protection and blocks replacement spawns until confirmed. Player-corpse cleanup metadata survives round transitions.

The optional native Sky Light Intensity input is increased by 10% from its saved original. Existing 18:00 time, cloud cover, rain, fog, full zombie damage, waves, population and sprint settings are preserved. A 10% intensity-input increase is not a guarantee of a 10% brighter rendered image; this input and fog tint/smoothing are host-local.

Validation: 1,998 offline checks passed; all 13 Lua modules compile. The package's 17 installed files match its manifest. The original Z-Deathmatch source and installation were verified unchanged. The latest brightness and round-transition changes still require cold gameplay acceptance; no new live-test result is claimed by this publication.

Package SHA-256: `8f9fa86588d3e5f41ad276f85c51d96ff94bf09eafe74ee0f739afa747e6dd8d`.
