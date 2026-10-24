# Native companion source and build instructions

This directory contains the complete C sources, fixed build header, tests and MinHook source needed to build `bodycam_variants_native.dll`, the native companion used by the PvP Zombie Variants. The original PvE Z-Deathmatch is Lua-only.

## What the DLL does

The Lua mod loads this library inside the running Bodycam process. It uses MinHook to intercept native score/death and Blueprint dispatch paths so owned zombie kills do not become ordinary player kills/deaths or XP, while the configured zombie match-point reward is accounted for. The interception is constrained by exact owned-actor identities, world/generation, authority and game-thread checks.

The DLL reads the already-loaded game and UE4SS module files to check their SHA-256 hashes. `build_pin.h` contains the supported hashes, offsets and short instruction signatures. Mismatched builds are rejected. The authored native sources do not implement network requests or an external-process injector. `DllMain` only disables thread notifications; initialization is requested by the Lua bridge on the game thread.

MinHook necessarily allocates executable memory and changes protection on in-process function code for its detours. This explains why the binary merits review; it does not identify the actual Nexus scanner trigger or establish a false positive.

## Exact published snapshot

- Published DLL: `../mod/BodycamZombieVariants/Native/bodycam_variants_native.dll`
- SHA-256: `4351cf396e9b448f20894d8b7864372f60fce6f635995bcafa3d77756f2587ba`
- Size: 199,168 bytes.
- Compiler: Zig 0.15.2, target `x86_64-windows-gnu`.
- MinHook: v1.3.4; required source files are included unchanged under `third_party/minhook` with copyright and license notices.
- All 12 original project C/header inputs match the recorded build hashes in `published-build.json`. The full source snapshot, including the vendored dependency, is listed in `source-manifest.json`.

The public `build.py` is a portable wrapper around the original compiler commands. It uses the frozen header directly rather than regenerating it from private local research files. It places outputs and caches under `native/build/`; it never writes to the installed mod or loads Bodycam. No game executable, UE4SS DLL, game assets, private logs or compiler binaries are distributed here.

## Build and test on Windows x64

1. Download or clone this repository, retaining the directory structure.
2. Install Python 3 (the build was exercised with Python 3.12).
3. Download and extract [Zig 0.15.2 for Windows x64](https://ziglang.org/download/0.15.2/zig-x86_64-windows-0.15.2.zip).
   Archive SHA-256: `3a0ed1e8799a2f8ce2a6e6290a9ff22e6906f8227865911fb7ddedc3cc14cb0c`.
4. From the repository root, run:

   ```powershell
   python .\native\build.py --zig "C:\Tools\zig-x86_64-windows-0.15.2\zig.exe"
   ```

   Adjust the Zig path. If `zig.exe` is on PATH, `python .\native\build.py` also works.

The script validates the compiler version and source checksums, builds the DLL with C11 and `-O2`, and compiles/runs all four native test executables. It requires no game installation, no UE4SS SDK and no running game. No network access is needed once Python, Zig and this source tree are available.

Outputs:

- `native/build/bin/bodycam_variants_native.dll`
- `native/build/bin/MinHook-LICENSE.txt`
- Four test executables under `native/build/bin/`
- `native/build/build-report.json`, including source hashes, compiler commands, test counts and comparison with the published DLL hash.

Expected tests: 31 score-filter + 38 XP-gate + 299 reward-policy + 865 native-bridge checks = **1,233 native checks**. Tests run in their own processes with controlled fixtures; the native-bridge suite exercises real detours only inside its own test process. The full mod's previously recorded 1,998 checks also include Lua suites; this build script runs the native subset.

Do not assume a build is byte-identical merely because the source matches. Compare the report's `matches_published_dll_bytes` and SHA-256 fields. Build-path/debug/linker metadata can differ. An independent build is not automatically installed or substituted into the published ZIP.

## Dependency license

MinHook copyright and redistribution conditions are in `third_party/minhook/LICENSE.txt`; the HDE headers retain their own notices. Upstream source archive: https://github.com/TsudaKageyu/minhook/releases/tag/v1.3.4. Its downloaded source ZIP hash is recorded in `published-build.json`.

## Verified independent rebuild (2026-10-24)

The documented script passed all **1,233 native checks**. The rebuilt DLL is 199,168 bytes, SHA-256 `5362be7a4be467cb407a81cf967a847291b21f50bf7686999a4771d8f7641e61`. Its `.text`, `.rdata`, `.data`, `.pdata`, `.tls` and `.reloc` sections are byte-identical to the published DLL. The 20 differing bytes are confined to the COFF timestamp and `.buildid` section. The published ZIP/DLL was not changed. See [build-verification.json](build-verification.json) for exact hashes and ranges.
