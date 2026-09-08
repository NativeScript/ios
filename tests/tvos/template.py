#!/usr/bin/env python3
"""Check the generated project with Apple's plist reader and the CLI parser."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class Template(unittest.TestCase):
    def test_generated_template_preserves_upstream_objects(self):
        with tempfile.TemporaryDirectory() as tmp:
            template = Path(tmp) / 'template'
            shutil.copytree(ROOT / 'project-template-ios', template)
            project = template / '__PROJECT_NAME__.xcodeproj/project.pbxproj'
            def read():
                return json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', project]))
            before = read()
            command = ['swift', ROOT / 'scripts/prepare-tvos-template.swift', template]
            subprocess.run(command, check=True)
            after = read()
            self.assertEqual(set(before['objects']), set(after['objects']))
            self.assertEqual(before['rootObject'], after['rootObject'])
            for item in after['objects'].values():
                if item['isa'] == 'XCBuildConfiguration':
                    settings = item['buildSettings']
                    self.assertEqual(settings['TARGETED_DEVICE_FAMILY'], '3')
                    self.assertNotIn('IPHONEOS_DEPLOYMENT_TARGET', settings)
                    if 'SDKROOT' in settings:
                        self.assertEqual(settings['SDKROOT'], 'appletvos')
                    if 'TVOS_DEPLOYMENT_TARGET' in settings:
                        self.assertEqual(settings['TVOS_DEPLOYMENT_TARGET'], '13.0')
            local = [o for o in after['objects'].values() if o['isa'] == 'XCLocalSwiftPackageReference']
            self.assertTrue(any(o.get('relativePath') == 'internal/local-spm' for o in local))
            first = project.read_bytes()
            config = (template / 'internal/nativescript-build.xcconfig').read_bytes()
            subprocess.run(command, check=True)
            self.assertEqual(project.read_bytes(), first)
            self.assertEqual((template / 'internal/nativescript-build.xcconfig').read_bytes(), config)
            if os.environ.get('TVOS_REVIEW_CLI'):
                subprocess.run(['node', '-e', '''
const assert = require('node:assert/strict');
const xcode = require(require.resolve('nativescript-dev-xcode', { paths: [process.argv[1]] }));
const project = xcode.project(process.argv[2]); project.parseSync();
const target = project.getFirstTarget(); assert(target.uuid);
assert(project.pbxFrameworksBuildPhaseObj(target.uuid));
''', os.environ['TVOS_REVIEW_CLI'], str(project)], check=True)

if __name__ == '__main__':
    unittest.main()
