"""Package the research receiver with its own local-network privacy identity."""
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / '.build/self-discovery/AimDropDiscoveryProbe.app'
contents = APP / 'Contents'
executable = str(contents / 'MacOS/AimDropDiscoveryProbe')
processes = subprocess.check_output(['/bin/ps', '-axo', 'comm='], text=True).splitlines()
if executable in (line.strip() for line in processes):
    raise SystemExit('Quit the research application before replacing its signed bundle')
(contents / 'MacOS').mkdir(parents=True, exist_ok=True)
(contents / 'Resources').mkdir(exist_ok=True)
metadata = dict(
    CFBundleIdentifier='pl.aimdrop.discovery-probe',
    CFBundleName='AimDrop Discovery Probe',
    CFBundleDisplayName='AimDrop Discovery Probe',
    CFBundleExecutable='AimDropDiscoveryProbe',
    CFBundlePackageType='APPL',
    CFBundleVersion='2',
    CFBundleShortVersionString='1.1',
    LSUIElement=True,
    NSLocalNetworkUsageDescription='Test odbiornika AimDrop widocznego przez AWDL tylko na innych urządzeniach.',
    NSBonjourServices=['_appSvcPrePair._tcp', '_applicationServicePairing._tcp', '_asquic._udp'],
    AimDropResearchProject=str(ROOT),
    AimDropResearchState=str(ROOT / '.build/self-discovery/live'),
)
(contents / 'Info.plist').write_bytes(plistlib.dumps(metadata))
shutil.copy2(ROOT / '.build/airfolder-pairing-prototype', contents / 'MacOS/AimDropDiscoveryProbe')
shutil.copy2(ROOT / '.build/artwork/AimDropAvatar.png', contents / 'Resources/AimDropAvatar.png')
subprocess.run(['codesign', '--force', '--sign', '-', str(APP)], check=True)
subprocess.run(['codesign', '--verify', '--strict', str(APP)], check=True)
print(APP)
