#!/usr/bin/env python3
"""Reject mislabeled or too-new tvOS Mach-O binaries in a framework/app tree."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('tree', type=Path)
parser.add_argument('--platform', choices=['TVOS', 'TVOSSIMULATOR'], required=True)
parser.add_argument('--minimum', help='Maximum minimum OS version; defaults to 13.0 device / 14.0 simulator')
args = parser.parse_args()
args.minimum = args.minimum or ('14.0' if args.platform == 'TVOSSIMULATOR' else '13.0')
if not args.tree.is_dir():
    parser.error(f'Directory does not exist: {args.tree}')
def version(text):
    return tuple(int(n) for n in (text.split('.') + ['0', '0'])[:3])
records = []
for path in sorted(args.tree.rglob('*')):
    if not path.is_file() or path.is_symlink():
        continue
    with path.open('rb') as file:
        magic = file.read(4)
    if magic not in [b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca']:
        continue
    output = subprocess.check_output(['xcrun', 'vtool', '-show-build', path], text=True)
    platforms = re.findall(r'^\s+platform (\S+)', output, re.M)
    minima = re.findall(r'^\s+minos (\S+)', output, re.M)
    valid = bool(platforms and minima) and all(p == args.platform for p in platforms) and all(version(v) <= version(args.minimum) for v in minima)
    records.append({'file': str(path.relative_to(args.tree)), 'platforms': platforms, 'minimumOS': minima, 'passed': valid})
print(json.dumps(records, indent=2))
sys.exit(not records or any(not record['passed'] for record in records))
