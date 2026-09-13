#!/usr/bin/env python3
"""Build the tvOS review stack in an isolated, revision-pinned workspace."""
import argparse
import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
RUNTIME = HERE.parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('step', choices=['doctor', 'checkout', 'runtime', 'packages', 'canvas', 'helpers', 'app', 'test', 'all'])
parser.add_argument('--workspace', type=Path, required=True)
parser.add_argument('--simulator', help='Apple TV simulator UDID, required for test')
parser.add_argument('--jobs', type=int, default=6)
args = parser.parse_args()
work = args.workspace.expanduser().resolve()
if work == RUNTIME or RUNTIME in work.parents:
    parser.error('Use a workspace outside the runtime checkout.')
work.mkdir(parents=True, exist_ok=True)
marker = work / '.tvos-review-workspace'
if not marker.exists() and any(work.iterdir()):
    parser.error('The initial workspace must be empty.')
marker.touch()
logs = work / 'logs'
logs.mkdir(exist_ok=True)
env = dict(os.environ, NX_DAEMON='false', NX_NO_CLOUD='true', DEPOT_TOOLS_UPDATE='0', CARGO_BUILD_JOBS=str(args.jobs))
env['PATH'] = str(work / 'host-tooling/node_modules/.bin') + ':' + str(work / 'depot_tools/.cipd_bin') + ':' + str(work / 'depot_tools') + ':' + str(Path.home() / '.cargo/bin') + ':' + env['PATH']
if not env.get('SSL_CERT_FILE'):
    try:
        import certifi
        env['SSL_CERT_FILE'] = certifi.where()
    except ImportError:
        pass

def run(label, cmd, cwd=work, extra=None):
    print(label, flush=True)
    with (logs / (label + '.log')).open('w') as log:
        result = subprocess.run(list(map(str, cmd)), cwd=cwd, env=dict(env, **(extra or {})), stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f'{label} failed ({result.returncode}); see {log.name}')

def doctor():
    if sys.platform != 'darwin':
        raise RuntimeError('The native build requires macOS.')
    for command in ['git', 'node', 'npm', 'python3', 'swift', 'xcodebuild', 'rustup', 'cargo', 'cbindgen', 'pod', 'cmake', 'jq']:
        if not shutil.which(command, path=env['PATH']):
            raise RuntimeError(f'Missing prerequisite: {command}. See README.md.')
    for sdk in ['iphoneos', 'iphonesimulator', 'appletvos', 'appletvsimulator']:
        run('sdk-' + sdk, ['xcrun', '--sdk', sdk, '--show-sdk-version'])
    run('node-version', ['node', '--version'])
    run('pods-version', ['pod', '--version'])
    run('xcode-version', ['xcodebuild', '-version'])
    print('Prerequisites found. Physical signing is configured separately.', flush=True)

def checkout():
    manifest = json.loads((HERE / 'revisions.json').read_text())
    # The runtime revision is exactly the checkout providing this script.
    manifest['runtime'] = {'url': 'https://github.com/LorenzGit/ios.git', 'rev': subprocess.check_output(['git', '-C', str(RUNTIME), 'rev-parse', 'HEAD'], text=True).strip()}
    for name, spec in manifest.items():
        dest = work / name
        created = not dest.exists()
        if created:
            run('clone-' + name, ['git', 'clone', '--filter=blob:none', '--no-checkout', spec['url'], dest])
        current = subprocess.run(['git', '-C', str(dest), 'status', '--porcelain'], capture_output=True, text=True)
        if not created and current.stdout.strip():
            raise RuntimeError(f'{dest} has local changes; use a new workspace instead of overwriting them')
        run('fetch-' + name, ['git', 'fetch', '--no-tags', 'origin', spec['rev']], dest)
        run('checkout-' + name, ['git', 'checkout', '--detach', spec['rev']], dest)
    run('depot-bootstrap', [work / 'depot_tools/ensure_bootstrap'])
    run('depot-gclient', ['gclient', '--version'])
    run('depot-ninja', ['ninja', '--version'])
    (work / 'resolved-revisions.json').write_text(json.dumps(manifest, indent=2) + '\n')
    for revision in json.loads((HERE / 'canvas-extras.json').read_text()):
        run('fetch-canvas-' + revision[:8], ['git', 'fetch', 'origin', revision], work / 'canvas')
        run('apply-canvas-' + revision[:8], ['git', 'cherry-pick', revision], work / 'canvas')
    cargo = work / 'canvas/Cargo.toml'
    skia = manifest['rust-skia']
    cargo.write_text(cargo.read_text() + '\n[patch."https://github.com/triniwiz/rust-skia"]\n' + '\n'.join(f'{name} = {{ git = "{skia["url"].removesuffix(".git")}", rev = "{skia["rev"]}" }}' for name in ['skia-safe', 'skia-bindings']) + '\n')

def runtime():
    v8 = work / 'v8-buildscripts'
    run('v8-fetch', ['scripts/matrix/fetch.sh', '--platform', 'ios', '--no-history'], v8)
    for variant in ['arm64-tvdevice', 'arm64-tvsimulator']:
        run('v8-' + variant, ['scripts/matrix/build-ios.sh', '--variant', variant, '--', '-j' + str(args.jobs)], v8)
    run('runtime-install', ['npm', 'install', '--ignore-scripts'], work / 'runtime')
    run('runtime-build', ['./build_all_tvos.sh'], work / 'runtime', {'V8_TVOS_BUILD': str(v8)})
    for name in ['NativeScript', 'TKLiveSync']:
        framework = work / 'runtime/dist' / (name + '.xcframework')
        for library in plistlib.loads((framework / 'Info.plist').read_bytes())['AvailableLibraries']:
            identifier = library['LibraryIdentifier']
            platform = 'TVOSSIMULATOR' if library.get('SupportedPlatformVariant') == 'simulator' else 'TVOS'
            run('audit-' + name + '-' + identifier, [sys.executable, HERE / 'audit-binaries.py', framework / identifier, '--platform', platform])

def host_npm():
    # CLI host fixtures still exercise npm 10 semantics. App dependency
    # resolution separately uses npm 12 (see app.py).
    tooling = work / 'host-tooling'
    if not (tooling / 'node_modules/.bin/npm').exists():
        run('host-npm', ['npm', 'install', '--prefix', tooling, '--ignore-scripts', '--no-audit', '--no-fund', 'npm@10.9.8'])

def packages():
    host_npm()
    for name in ['core', 'canvas', 'cli', 'simulator', 'test-runner']:
        cwd = work / name
        run(name + '-install', ['npm', 'ci' if (cwd / 'package-lock.json').exists() else 'install', '--ignore-scripts'], cwd)
    run('core-ts-patch', ['npx', 'ts-patch', 'install'], work / 'core')
    run('core-build', ['npx', 'nx', 'run-many', '--target=build', '--projects=core,webpack5'], work / 'core')
    run('canvas-build', ['npx', 'nx', 'run', 'canvas:build.all'], work / 'canvas')
    run('test-runner-pack', ['npm', 'pack'], work / 'test-runner')
    run('simulator-pack', ['npm', 'pack'], work / 'simulator')
    simulator = next((work / 'simulator').glob('ios-sim-portable-*.tgz'))
    run('cli-simulator-install', ['npm', 'install', '--no-save', simulator], work / 'cli')
    run('cli-build', ['npm', 'run', 'build'], work / 'cli')

def canvas():
    cwd = work / 'canvas'
    run('rust-toolchain', ['rustup', 'toolchain', 'install', 'nightly-2026-09-07', '--profile', 'minimal', '--component', 'rust-src'])
    env['CANVAS_RUST_TOOLCHAIN'] = 'nightly-2026-09-07'
    env['RUSTFLAGS'] = '-Zlocation-detail=none -Zunstable-options -Cpanic=immediate-abort'
    # The Xcode prebuild phase compiles Rust with the selected SDK and toolchain.
    native = cwd / 'packages/canvas/src-native/canvas-ios'
    for sdk, platform in [('appletvos', 'tvOS'), ('appletvsimulator', 'tvOS Simulator')]:
        run('canvas-native-' + sdk, ['xcodebuild', '-project', 'CanvasNative.xcodeproj', '-scheme', 'CanvasNative', '-sdk', sdk, '-destination', 'generic/platform=' + platform, '-configuration', 'Release', 'build', 'BUILD_DIR=' + str(native / 'dist-review'), 'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=NO', 'SKIP_INSTALL=NO', 'BUILD_LIBRARY_FOR_DISTRIBUTION=YES', 'CODE_SIGNING_ALLOWED=NO', '-quiet'], native)
    output = work / 'artifacts/CanvasNative.xcframework'
    output.parent.mkdir(exist_ok=True)
    if output.exists():
        shutil.rmtree(output)
    run('canvas-xcframework', ['xcodebuild', '-create-xcframework', '-framework', native / 'dist-review/Release-appletvos/CanvasNative.framework', '-framework', native / 'dist-review/Release-appletvsimulator/CanvasNative.framework', '-output', output])

def helpers():
    run('helpers', [sys.executable, HERE / 'helpers.py', work])

def app():
    run('app', [sys.executable, HERE / 'app.py', work])

def test():
    host_npm()
    if not args.simulator:
        parser.error('--simulator is required for test')
    run('core-tests', ['npx', 'nx', 'run', 'core:test'], work / 'core')
    run('template-tests', [sys.executable, work / 'runtime/tests/tvos/template.py'], extra={'TVOS_REVIEW_CLI': str(work / 'cli')})
    run('runner-tests', ['npm', 'test'], work / 'test-runner')
    run('webpack-tests', ['npx', 'nx', 'run', 'webpack5:test', '--runInBand'], work / 'core')
    run('cli-tests', ['npm', 'test'], work / 'cli')
    run('app-tests', ['node', work / 'cli/bin/tns', 'test', 'tvos', '--device', args.simulator, '--no-local-cli'], work / 'app', extra={'PATH': str(work / 'tooling/node_modules/.bin') + ':' + env['PATH']})

steps = ['doctor', 'checkout', 'runtime', 'packages', 'canvas', 'helpers', 'app', 'test'] if args.step == 'all' else [args.step]
for step in steps:
    globals()[step]()
