"""Copy release workers byte-for-byte into a separate LaunchServices test host."""
import hashlib
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'dist/AimDrop.app'
APP = ROOT / '.build/discovery-chain/AimDropDiscoveryProbe.app'
binary = APP / 'Contents/MacOS/AimDropDiscoveryProbe'
processes = subprocess.check_output(['/bin/ps', '-axo', 'comm='], text=True).splitlines()
if str(binary) in (line.strip() for line in processes):
    raise SystemExit('Quit the discovery chain test before rebuilding it')
if APP.exists():
    previous = plistlib.loads((APP / 'Contents/Info.plist').read_bytes())
    if previous.get('AimDropDiscoveryChain') is not True:
        raise SystemExit('Refusing to replace an unknown bundle')
    shutil.rmtree(APP)
shutil.copytree(SOURCE, APP, symlinks=True)
info = plistlib.loads((APP / 'Contents/Info.plist').read_bytes())
info.update(CFBundleIdentifier='pl.aimdrop.discovery-probe', CFBundleName='AimDrop Discovery Probe',
            CFBundleDisplayName='AimDrop Discovery Probe', CFBundleExecutable=binary.name,
            AimDropDiscoveryChain=True, AimDropResearchState=str(ROOT / '.build/self-discovery/live'))
(APP / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
(APP / 'Contents/MacOS/AimDrop').unlink()
subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(ROOT / '.build/module-cache'),
                *[str(ROOT / 'Sources' / (name + '.swift')) for name in
                  ('Localization', 'Branding', 'ActionButtonStyle', 'PairingWindowController')],
                str(ROOT / 'scripts/research/production-discovery-host.swift'), '-o', str(binary)], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(APP)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(APP)], check=True)
for name in ('AimDropReceiver', 'AimDropTrash'):
    relative = Path('Contents/MacOS') / name
    assert (APP / relative).read_bytes() == (SOURCE / relative).read_bytes()
for path in (SOURCE / 'Contents/Resources/receiver').glob('*.py'):
    assert path.read_bytes() == (APP / 'Contents/Resources/receiver' / path.name).read_bytes()
state = ROOT / '.build/self-discovery/live/Pairing/identity.json'
if state.exists():
    (ROOT / '.build/self-discovery/production-pairing-before.sha256').write_text(hashlib.sha256(state.read_bytes()).hexdigest())
print('PASS: release native helpers and Python receiver are unchanged in the isolated app → Python → native test chain')
print(APP)
