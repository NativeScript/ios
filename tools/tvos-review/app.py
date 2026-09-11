#!/usr/bin/env python3
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

work = Path(sys.argv[1]).resolve()
if not (work / '.tvos-review-workspace').is_file():
    raise RuntimeError('Use review.py to initialize an isolated reviewer workspace first.')
here = Path(__file__).resolve().parent
# npm 10 crashes in peer resolution for this dependency graph. Keep the
# tested npm version local to the reviewer workspace, including CLI child calls.
tooling = work / 'tooling'
if not (tooling / 'node_modules/.bin/npm').exists():
    subprocess.run(['npm', 'install', '--prefix', str(tooling), '--ignore-scripts', '--no-audit', '--no-fund', 'npm@12.0.2'], check=True)
os.environ['PATH'] = str(tooling / 'node_modules/.bin') + ':' + os.environ['PATH']
packages = work / 'packages'
packages.mkdir(exist_ok=True)

def merge(source, dest):
    dest.mkdir(parents=True, exist_ok=True)
    old = plistlib.loads((dest / 'Info.plist').read_bytes()) if (dest / 'Info.plist').exists() else {'CFBundlePackageType': 'XFWK', 'XCFrameworkFormatVersion': '1.0', 'AvailableLibraries': []}
    new = plistlib.loads((source / 'Info.plist').read_bytes())
    ids = {item['LibraryIdentifier'] for item in new['AvailableLibraries']}
    old['AvailableLibraries'] = [item for item in old['AvailableLibraries'] if item['LibraryIdentifier'] not in ids] + new['AvailableLibraries']
    for item in new['AvailableLibraries']:
        identifier = item['LibraryIdentifier']
        shutil.copytree(source / identifier, dest / identifier, dirs_exist_ok=True, symlinks=True)
    (dest / 'Info.plist').write_bytes(plistlib.dumps(old))

def pack(name, source):
    dest = packages / name
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(source, dest, symlinks=True)
    if name == 'core':
        for framework in ['TNSWidgets', 'NSCWinterTC']:
            merge(work / ('artifacts/' + framework + '.xcframework'), dest / ('platforms/ios/' + framework + '.xcframework'))
    if name == 'canvas':
        # Include the exact native bridge sources being reviewed, even if Nx
        # considers its TypeScript output up to date.
        shutil.copytree(work / 'canvas/packages/canvas/platforms/ios/src', dest / 'platforms/ios/src', dirs_exist_ok=True)
        shutil.copy2(work / 'canvas/packages/canvas/platforms/ios/build.xcconfig', dest / 'platforms/ios/build.xcconfig')
        shutil.copy2(work / 'canvas/nativescript-v8/Package.swift', dest / 'platforms/ios/NativeScriptV8/Package.swift')
        merge(work / 'artifacts/CanvasNative.xcframework', dest / 'platforms/ios/CanvasNative.xcframework')
    # npm peer ranges reject upstream prerelease versions. Give only these
    # local review artifacts a stable SemVer with the source revision attached.
    manifest_path = dest / 'package.json'
    manifest = json.loads(manifest_path.read_text())
    repository = {'webpack': 'core'}.get(name, name)
    revision = subprocess.check_output(['git', 'rev-parse', '--short=12', 'HEAD'], cwd=work / repository, text=True).strip()
    manifest['version'] = manifest['version'].split('-')[0].split('+')[0] + '+review.' + revision
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
    output = json.loads(subprocess.check_output(['npm', 'pack', '--json', '--pack-destination', str(packages)], cwd=dest, text=True))
    entry = output[0] if isinstance(output, list) else next(iter(output.values()))
    return '../packages/' + entry['filename']

core = pack('core', work / 'core/dist/packages/core')
webpack = pack('webpack', work / 'core/dist/packages/webpack5')
canvas = pack('canvas', work / 'canvas/dist/packages/canvas')
app = work / 'app'
if app.exists():
    raise RuntimeError('App already exists. Keep it for comparison; use a new workspace for another clean installation.')
shutil.copytree(here / 'app', app)
shutil.copy2(work / 'canvas/tools/tests/webgpu-map-progress.spec.js', app / 'app/webgpu-map-progress.spec.js')
shutil.copy2(work / 'canvas/tools/tests/imagedata-ownership.js', app / 'app/imagedata-ownership.js')
runtime = next((work / 'runtime/dist').glob('nativescript-tvos-*.tgz'))
runner = next((work / 'test-runner').glob('nativescript-unit-test-runner-*.tgz'))
manifest = {
    'name': 'tvosreview', 'version': '1.0.0', 'private': True,
    'dependencies': {'@nativescript/core': 'file:' + core, '@nativescript/canvas': 'file:' + canvas, '@nativescript/unit-test-runner': 'file:../test-runner/' + runner.name},
    'devDependencies': {'@nativescript/webpack': 'file:' + webpack, 'typescript': '5.8.3', 'vitest': '4.1.10', '@vitest/runner': '4.1.10', 'vite': '8.2.1'},
    'nativescript': {'id': 'org.nativescript.tvosreview'},
}
(app / 'package.json').write_text(json.dumps(manifest, indent=2) + '\n')
subprocess.run(['npm', 'install', '--package-lock-only', '--ignore-scripts'], cwd=app, check=True)
subprocess.run(['npm', 'ci'], cwd=app, check=True)
cli = ['node', str(work / 'cli/bin/tns')]
subprocess.run(cli + ['platform', 'add', 'tvos', '--frameworkPath', str(runtime), '--no-local-cli'], cwd=app, check=True)
subprocess.run(cli + ['build', 'tvos', '--emulator', '--release', '--env.production', '--no-hmr', '--no-local-cli'], cwd=app, check=True)
