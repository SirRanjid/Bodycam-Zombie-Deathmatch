# Nexus quarantine review - Bodycam Zombie Modes

Nexus mod page: https://www.nexusmods.com/bodycam/mods/80
File reference supplied by the uploader: 271.

## File under review

The local archive was renamed from `Bodycam-Zombie-Modes-0.1.0-preview.zip` to `Bodycam-Zombie-Modes.zip`; its bytes and checksum are unchanged.

- ZIP SHA-256: `1b32f09d1fc36afc885e5850ff3fd6761b7ab15af469fc0f83e2e973669f0e10`
- Size: 269,865 bytes; 36 entries.
- ZIP CRC verification passed.
- No nested ZIP/7z/RAR/TAR/GZ archives and no password-encrypted entries.
- One native DLL: `BodycamZombieVariants/Native/bodycam_variants_native.dll`.
- One optional PowerShell installer: `Install-Variants.ps1`.
- No EXE, BAT or CMD entry.

This audit covers the exact local ZIP with the checksum above. The quarantined file could not be independently downloaded from Nexus, so its server-side bytes and VirusTotal results have not been verified. The generic quarantine notice does not disclose a specific scanner finding.

## Native code

[Complete source and tested build instructions](../native/README.md). The documented build passed all 1,233 native tests. Machine-code and data sections match the published DLL exactly; only 20 bytes of COFF timestamp/build-ID metadata differ. See [rebuild verification](../native/build-verification.json).

Published DLL SHA-256: `4351cf396e9b448f20894d8b7864372f60fce6f635995bcafa3d77756f2587ba`.

The companion implements bounded native score/XP interception and match-point rewards for exact owned zombies. It uses MinHook for in-process detours; the source, MinHook license and all four native test suites are available. The Lua modules are under `mod/BodycamZombieVariants/Scripts`.

## Optional installer

The Nexus ZIP's `Install-Variants.ps1` is byte-identical to [the published installer](../packages/zombie-variants-20261022/Install.ps1). It checks package hashes and exact game/UE4SS versions, refuses an installation while Bodycam is running, stages the mod locally, retains the prior variant folder as a backup and rolls back the directory move if needed. It does not download dependencies or edit registry/startup settings. Manual copying of the mod folders does not require this script.

The original PvE `BodycamZombieChill` component is Lua-only and unchanged from version 0.2.2. The game runtime and UE4SS are not bundled.

## Review status

This publication supplies the missing native-source/build context for manual review. It is not a Nexus approval, a malware scan result or proof of a false positive. The uploaded ZIP has not been changed, repacked or resubmitted to avoid scanning.
