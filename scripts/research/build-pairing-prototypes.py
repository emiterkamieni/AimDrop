"""Build research executables; all generated artifacts stay in .build/."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
SOURCE = 'scripts/research'
subprocess.run([sys.executable, str(ROOT / SOURCE / 'build-network-research-module.py')], cwd=ROOT, check=True)

subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror', '-c',
                f'{SOURCE}/pake-bridge.m', '-o', '.build/pake-bridge.o'], cwd=ROOT, check=True)
subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror', '-c',
                f'{SOURCE}/pair-verify-bridge.m', '-o', '.build/pair-verify-bridge.o'], cwd=ROOT, check=True)
for name in ['actor-loopback-probe', 'airfolder-pairing-prototype']:
    extra = [f'{SOURCE}/{file}.swift' for file in ['native-file-service', 'streaming-upload', 'pair-verify', 'pairing-store', 'pair-verify-client-check']] if name == 'airfolder-pairing-prototype' else []
    if name == 'airfolder-pairing-prototype':
        extra.append('Sources/ReceiverAvatar.swift')
        extra.append('Sources/Localization.swift')
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-name', 'rapportd',
        '-target', 'arm64-apple-macos14.0', '-I', '.build/research-modules',
        '-module-cache-path', '.build/research-module-cache', '-import-objc-header',
        f'{SOURCE}/pake-bridge.h', f'{SOURCE}/{name}.swift', *extra, '.build/pake-bridge.o', '.build/pair-verify-bridge.o',
        '-Xlinker', '-undefined', '-Xlinker', 'dynamic_lookup', '-o', f'.build/{name}'], cwd=ROOT, check=True)
