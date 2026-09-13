#!/usr/bin/env python3
"""generate-spm-manifest.mjs emits each optional platform whole, or not at all.

Runs the generator with synthetic checksum files the way the release
workflow does (--checksums-dir over the merged spm-artifacts download) and
checks the channel rules: "next" ships iOS only, a real release must carry
every platform its build matrix produces, and a half-present platform is
rejected rather than shipped.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
GENERATOR = ROOT / 'scripts/generate-spm-manifest.mjs'
KEYS = {
    'ios': ['NS_CHECKSUM_NATIVESCRIPT_IOS', 'NS_CHECKSUM_TKLIVESYNC_IOS'],
    'visionos': ['NS_CHECKSUM_NATIVESCRIPT_VISIONOS', 'NS_CHECKSUM_TKLIVESYNC_VISIONOS'],
    'tvos': ['NS_CHECKSUM_NATIVESCRIPT_TVOS', 'NS_CHECKSUM_TKLIVESYNC_TVOS'],
}
TVOS_FRAGMENTS = [
    '.tvOS(.v13),',
    '.library(name: "NativeScriptTvOS", targets: ["NativeScriptTvOS", "TKLiveSyncTvOS"])',
    'name: "NativeScriptTvOS",\n            url: "\\(releaseBase)/NativeScript.tvos.xcframework.zip"',
    'name: "TKLiveSyncTvOS",\n            url: "\\(releaseBase)/TKLiveSync.tvos.xcframework.zip"',
]
VISION_FRAGMENTS = ['.visionOS(.v1),', '.library(name: "NativeScriptVisionOS"', 'NativeScript.visionos.xcframework.zip']


def checksum(key):
    return format(abs(hash(key)) % (1 << 64), '016x') * 4


class Manifest(unittest.TestCase):
    def generate(self, platforms, channel, keys=None):
        with tempfile.TemporaryDirectory() as tmp:
            checksums = Path(tmp) / 'spm-artifacts'
            checksums.mkdir()
            for platform in platforms:
                lines = [f'{k}={checksum(k)}' for k in (keys or KEYS)[platform]]
                (checksums / f'checksums-{platform}.env').write_text('\n'.join(lines) + '\n')
            manifest = Path(tmp) / 'Package.swift'
            result = subprocess.run(
                ['node', GENERATOR, '--package', manifest, '--version', '9.9.9', '--checksums-dir', checksums, '--channel', channel],
                capture_output=True, text=True)
            return result, manifest.read_text() if manifest.exists() else ''

    def test_release_carries_every_platform(self):
        result, manifest = self.generate(['ios', 'visionos', 'tvos'], 'latest')
        self.assertEqual(result.returncode, 0, result.stderr)
        for fragment in TVOS_FRAGMENTS + VISION_FRAGMENTS:
            self.assertIn(fragment, manifest)
        for key in KEYS['tvos']:
            self.assertIn(checksum(key), manifest)
        self.assertIn('let nsVersion = "9.9.9"', manifest)
        self.assertLess(manifest.index('.visionOS(.v1)'), manifest.index('.tvOS(.v13)'))
        self.dump_package(manifest)

    def test_next_channel_is_ios_only(self):
        result, manifest = self.generate(['ios'], 'next')
        self.assertEqual(result.returncode, 0, result.stderr)
        for fragment in TVOS_FRAGMENTS + VISION_FRAGMENTS:
            self.assertNotIn(fragment, manifest)
        self.dump_package(manifest)

    def test_release_without_tvos_is_rejected(self):
        result, _ = self.generate(['ios', 'visionos'], 'latest')
        self.assertEqual(result.returncode, 1)
        self.assertIn('requires the tvOS checksums', result.stderr)

    def test_release_without_visionos_is_rejected(self):
        result, _ = self.generate(['ios', 'tvos'], 'latest')
        self.assertEqual(result.returncode, 1)
        self.assertIn('requires the visionOS checksums', result.stderr)

    def test_partial_tvos_is_rejected_on_every_channel(self):
        partial = dict(KEYS, tvos=KEYS['tvos'][:1])
        for channel in ['next', 'latest']:
            result, _ = self.generate(['ios', 'visionos', 'tvos'], channel, keys=partial)
            self.assertEqual(result.returncode, 1, channel)
            self.assertIn('partial tvOS checksums', result.stderr)

    def dump_package(self, manifest):
        """The emitted Swift must load as a package manifest, not merely look like one."""
        if 'CI' not in os.environ and not os.environ.get('SPM_DUMP_PACKAGE'):
            return
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / 'Package.swift').write_text(manifest)
            subprocess.run(['swift', 'package', 'dump-package', '--package-path', tmp], check=True, capture_output=True)


if __name__ == '__main__':
    unittest.main()
