"""Generate a local research-only SDK overlay, preserving the installed SDK."""
from pathlib import Path
import subprocess

source_dir = Path(__file__).resolve().parent
root = source_dir.parents[1] / '.build'
sdk = Path(subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip())
source = sdk / 'System/Library/Frameworks/Network.framework/Versions/A/Modules/Network.swiftmodule/arm64e-apple-macos.swiftinterface'
output = root / 'research-modules/Network.swiftmodule'
output.mkdir(parents=True, exist_ok=True)
interface = output / 'arm64-apple-macos.swiftinterface'
text = source.read_text().replace('-target arm64e-apple-macos14.0', '-target arm64-apple-macos14.0')
interface.write_text(text + '\n' + (source_dir / 'network-actor-declarations.swiftinterface').read_text())
subprocess.run([
    'xcrun', 'swiftc', '-frontend', '-compile-module-from-interface', str(interface),
    '-o', str(output / 'arm64-apple-macos.swiftmodule'), '-target', 'arm64-apple-macos14.0',
    '-sdk', str(sdk), '-module-name', 'Network', '-module-cache-path', str(root / 'research-module-cache'),
], check=True)
print('Local Network research module built')
rapport = root / 'research-modules/Rapport.swiftmodule'
rapport.mkdir(parents=True, exist_ok=True)
subprocess.run([
    'xcrun', 'swiftc', '-frontend', '-compile-module-from-interface', str(source_dir / 'rapport-ratchet.swiftinterface'),
    '-o', str(rapport / 'arm64-apple-macos.swiftmodule'), '-target', 'arm64-apple-macos14.0',
    '-sdk', str(sdk), '-module-name', 'Rapport', '-module-cache-path', str(root / 'research-module-cache'),
], check=True)
print('Local Rapport research module built')
