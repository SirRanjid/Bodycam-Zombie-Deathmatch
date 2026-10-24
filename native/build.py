"""Build and test the native companion in an isolated directory; never install it."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zig', default=shutil.which('zig'), help='Path to Zig 0.15.2 zig.exe')
    args = parser.parse_args()
    if os.name != 'nt':
        parser.error('Use Windows x64; the native tests are Windows executables.')
    if not args.zig:
        parser.error('Supply --zig with the path to Zig 0.15.2 zig.exe.')
    zig = Path(args.zig).resolve(strict=True)
    version = subprocess.check_output([str(zig), 'version'], text=True).strip()
    if version != '0.15.2':
        parser.error('This source snapshot requires Zig 0.15.2, found ' + version)
    inputs = json.loads((ROOT / 'source-manifest.json').read_text(encoding='utf-8'))
    for name, expected in inputs.items():
        if digest(ROOT / name) != expected:
            raise RuntimeError('Source checksum differs from reviewed snapshot: ' + name)
    build = ROOT / 'build'
    output = build / 'bin'
    output.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    for name, folder in [('ZIG_GLOBAL_CACHE_DIR', 'global'), ('ZIG_LOCAL_CACHE_DIR', 'local'), ('TEMP', 'tmp'), ('TMP', 'tmp')]:
        path = build / 'cache' / folder
        path.mkdir(parents=True, exist_ok=True)
        env[name] = str(path)
    platform = ROOT / 'native-platform'
    score = ROOT / 'native-score'
    mh = ROOT / 'third_party/minhook'
    common = ['-std=c11', '-Wall', '-Wextra', '-I' + str(mh / 'include'), '-I' + str(score), '-I' + str(platform)]
    sources = [mh / 'src/hook.c', mh / 'src/buffer.c', mh / 'src/trampoline.c', mh / 'src/hde/hde64.c', score / 'score_filter.c', score / 'xp_gate.c', score / 'reward_policy.c']
    commands = []
    def compile_native(arguments):
        command = [str(zig), 'cc', '-target', 'x86_64-windows-gnu', *map(str, arguments)]
        commands.append(command)
        subprocess.run(command, cwd=platform, env=env, check=True)
    dll = output / 'bodycam_variants_native.dll'
    compile_native([*common, '-O2', '-shared', platform / 'native_bridge.c', *sources, '-lbcrypt', '-o', dll])
    suites = [
        ('score_filter_tests', '-O1', [score / 'score_filter_tests.c', score / 'score_filter.c'], [], 31),
        ('xp_gate_tests', '-O1', [score / 'xp_gate_tests.c', score / 'xp_gate.c'], [], 38),
        ('reward_policy_tests', '-O1', [score / 'reward_policy_tests.c', score / 'reward_policy.c', score / 'score_filter.c'], [], 299),
        ('native_bridge_tests', '-O0', [platform / 'native_bridge_tests.c', *sources], ['-lbcrypt'], 865),
    ]
    tests = []
    for name, optimization, source_files, libraries, expected in suites:
        executable = output / (name + '.exe')
        compile_native([*common, optimization, *source_files, *libraries, '-o', executable])
        result = subprocess.run([str(executable)], cwd=output, env=env, check=True, text=True, capture_output=True, encoding='utf-8')
        match = re.search(r'(\d+)\s+(?:native |checks passed|XP|xp)', result.stdout)
        if not match or int(match.group(1)) != expected:
            raise RuntimeError('Unexpected check count: ' + result.stdout)
        print(result.stdout.strip(), flush=True)
        tests.append({'suite': name, 'passed': expected, 'failed': 0})
    shutil.copy2(mh / 'LICENSE.txt', output / 'MinHook-LICENSE.txt')
    published = json.loads((ROOT / 'published-build.json').read_text(encoding='utf-8'))
    report = {'compiler': version, 'target': 'x86_64-windows-gnu', 'source_sha256': inputs,
              'dll_sha256': digest(dll), 'dll_bytes': dll.stat().st_size,
              'matches_published_dll_bytes': digest(dll) == published['published_dll_sha256'],
              'passed': sum(t['passed'] for t in tests), 'failed': 0, 'tests': tests,
              'commands': commands, 'game_accessed': False, 'installed': False}
    (build / 'build-report.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({k: report[k] for k in ['dll_sha256', 'matches_published_dll_bytes', 'passed', 'failed', 'installed']}), flush=True)

if __name__ == '__main__':
    main()
