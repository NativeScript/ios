#!/usr/bin/env python3
"""project-template-tvos is the iOS template plus an enumerated tvOS delta.

Checks that the checked-in tvOS template parses with Apple's plist reader,
differs from project-template-ios only in the settings tvOS needs, agrees with
the local SwiftPM package it is bundled with, and comes out of both packaging
stamps (released ios-spm pin / embedded local package) still parseable. Set
TVOS_REVIEW_CLI to a nativescript-cli checkout to also parse the stamped
projects with the CLI's own pbxproj parser.
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
IOS = ROOT / 'project-template-ios'
TVOS = ROOT / 'project-template-tvos'
LOCAL_SPM = ROOT / 'spm-templates/local-spm-tvos/Package.swift'
PBXPROJ = '__PROJECT_NAME__.xcodeproj/project.pbxproj'
XCCONFIG = 'internal/nativescript-build.xcconfig'
PRODUCT = 'NativeScriptTvOS'
PLATFORMS = 'appletvos appletvsimulator'
CLI = os.environ.get('TVOS_REVIEW_CLI')


def template_files(template):
    """Relative paths of the template's files, minus per-machine leftovers."""
    files = set()
    for path in template.rglob('*'):
        rel = path.relative_to(template)
        if not path.is_file() or any(part.startswith('.') or part == 'project.xcworkspace' for part in rel.parts):
            continue
        files.add(rel.as_posix())
    return files


def read_pbxproj(path):
    return json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', path]))


def as_tvos(obj):
    """The tvOS counterpart of an iOS template object: the complete allowed delta."""
    obj = json.loads(json.dumps(obj))
    if obj.get('isa') == 'XCSwiftPackageProductDependency' and obj.get('productName') == 'NativeScript':
        obj['productName'] = PRODUCT
    if obj.get('isa') == 'XCBuildConfiguration':
        settings = obj['buildSettings']
        if settings.pop('IPHONEOS_DEPLOYMENT_TARGET', None) is not None:
            settings['TVOS_DEPLOYMENT_TARGET'] = '13.0'
        if 'SDKROOT' in settings:
            settings['SDKROOT'] = 'appletvos'
        settings.pop('SUPPORTS_UIKITFORMAC', None)
        settings['SUPPORTED_PLATFORMS'] = PLATFORMS
        settings['SUPPORTS_MACCATALYST'] = 'NO'
        settings['TARGETED_DEVICE_FAMILY'] = '3'
    return obj


SETTING = re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]*\])?)\s*=\s*(.*?)\s*$')


def xcconfig_settings(path):
    settings = {}
    for line in path.read_text().splitlines():
        match = SETTING.match(line)
        if match and not line.lstrip().startswith('//'):
            settings[match.group(1)] = match.group(2)
    return settings


def objects_of(pbxproj, isa):
    return [o for o in pbxproj['objects'].values() if o['isa'] == isa]


def parse_with_cli(project):
    subprocess.run(['node', '-e', '''
const assert = require('node:assert/strict');
const xcode = require(require.resolve('nativescript-dev-xcode', { paths: [process.argv[1]] }));
const project = xcode.project(process.argv[2]); project.parseSync();
const target = project.getFirstTarget(); assert(target.uuid);
assert(project.pbxFrameworksBuildPhaseObj(target.uuid));
''', CLI, str(project)], check=True)


class Template(unittest.TestCase):
    def test_files_match_ios_template(self):
        self.assertEqual(template_files(TVOS), template_files(IOS))
        for rel in sorted(template_files(IOS) - {PBXPROJ, XCCONFIG}):
            self.assertEqual((TVOS / rel).read_bytes(), (IOS / rel).read_bytes(), rel)

    def test_project_is_ios_project_with_tvos_settings(self):
        ios, tvos = read_pbxproj(IOS / PBXPROJ), read_pbxproj(TVOS / PBXPROJ)
        self.assertEqual(tvos['rootObject'], ios['rootObject'])
        self.assertEqual(set(tvos['objects']), set(ios['objects']))
        for identifier, obj in ios['objects'].items():
            self.assertEqual(tvos['objects'][identifier], as_tvos(obj), identifier)
        for config in objects_of(tvos, 'XCBuildConfiguration'):
            settings = config['buildSettings']
            self.assertEqual(settings['TARGETED_DEVICE_FAMILY'], '3')
            self.assertEqual(settings['SUPPORTED_PLATFORMS'], PLATFORMS)
            self.assertNotIn('IPHONEOS_DEPLOYMENT_TARGET', settings)
        self.assertEqual([o['productName'] for o in objects_of(tvos, 'XCSwiftPackageProductDependency')], [PRODUCT])
        text = (TVOS / PBXPROJ).read_text()
        self.assertNotIn('/* NativeScript */', text)
        self.assertNotIn('/* NativeScript in Frameworks */', text)
        self.assertIn('XCRemoteSwiftPackageReference "ios-spm"', text)
        self.assertIn('__NS_RUNTIME_VERSION__', text)

    def test_build_xcconfig_keeps_linker_setup_in_step(self):
        ios, tvos = xcconfig_settings(IOS / XCCONFIG), xcconfig_settings(TVOS / XCCONFIG)
        for key in ['OTHER_LDFLAGS[sdk=*]', 'FRAMEWORK_SEARCH_PATHS[sdk=*]', 'LD', 'LDPLUSPLUS', 'VALIDATE_WORKSPACE']:
            self.assertEqual(tvos[key], ios[key], key)
        self.assertEqual(tvos['TARGETED_DEVICE_FAMILY'], '3')
        for sdk in ['appletvos', 'appletvsimulator']:
            excluded = tvos[f'EXCLUDED_ARCHS[sdk={sdk}*]'].split()
            self.assertIn('x86_64', excluded)
            self.assertIn('i386', excluded)
            self.assertNotIn('arm64', excluded)
        self.assertFalse([k for k in tvos if 'iphone' in k or 'macosx' in k], 'iOS-only settings in the tvOS xcconfig')

    def test_local_spm_package_matches_template_product(self):
        manifest = LOCAL_SPM.read_text()
        self.assertIn(f'.library(name: "{PRODUCT}", targets: ["NativeScriptTvOS", "TKLiveSyncTvOS"])', manifest)
        self.assertIn('.binaryTarget(name: "NativeScriptTvOS", path: "NativeScript.tvos.xcframework.zip")', manifest)
        self.assertIn('.binaryTarget(name: "TKLiveSyncTvOS", path: "TKLiveSync.tvos.xcframework.zip")', manifest)
        self.assertIn('.tvOS(.v13)', manifest)

    def test_remote_stamp(self):
        with tempfile.TemporaryDirectory() as tmp:
            template = Path(tmp) / 'framework'
            shutil.copytree(TVOS, template)
            project = template / PBXPROJ
            subprocess.run(['node', ROOT / 'scripts/stamp-template-version.mjs', project, '9.9.9'], check=True)
            self.assertNotIn('__NS_RUNTIME_VERSION__', project.read_text())
            stamped = read_pbxproj(project)
            [reference] = objects_of(stamped, 'XCRemoteSwiftPackageReference')
            self.assertIn('NativeScript/ios-spm', reference['repositoryURL'])
            self.assertEqual(reference['requirement'], {'kind': 'exactVersion', 'version': '9.9.9'})
            if CLI:
                parse_with_cli(project)

    def test_embedded_stamp(self):
        with tempfile.TemporaryDirectory() as tmp:
            template = Path(tmp) / 'framework'
            shutil.copytree(TVOS, template)
            project = template / PBXPROJ
            local = template / 'internal/local-spm'
            local.mkdir()
            shutil.copy2(LOCAL_SPM, local)
            subprocess.run(['node', ROOT / 'scripts/stamp-template-local-spm.mjs', project, 'internal/local-spm', '--package-dir', local], check=True)
            stamped = read_pbxproj(project)
            self.assertEqual(objects_of(stamped, 'XCRemoteSwiftPackageReference'), [])
            [reference] = objects_of(stamped, 'XCLocalSwiftPackageReference')
            self.assertEqual(reference['relativePath'], 'internal/local-spm')
            [dependency] = objects_of(stamped, 'XCSwiftPackageProductDependency')
            self.assertEqual(stamped['objects'][dependency['package']], reference)
            self.assertEqual(dependency['productName'], PRODUCT)
            if CLI:
                parse_with_cli(project)


if __name__ == '__main__':
    unittest.main()
