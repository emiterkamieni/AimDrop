#!/usr/bin/env python3
"""Run offline packet/lifecycle checks without requiring AWDL or network access."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
output = ROOT / '.build/AWDLAdvertisementChecks'
output.parent.mkdir(exist_ok=True)
subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(ROOT / '.build/module-cache'),
                str(ROOT / 'NativeReceiver/MDNSAnnouncement.swift'), str(ROOT / 'NativeReceiver/AWDLAdvertisement.swift'),
                str(ROOT / 'tests/AWDLAdvertisementChecks.swift'), '-o', str(output)], check=True)
subprocess.run([str(output)], check=True, timeout=15)
