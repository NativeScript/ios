#!/usr/bin/env python3
import pathlib
import subprocess
import sys
work = pathlib.Path(sys.argv[1]).resolve()
if not (work / '.tvos-review-workspace').is_file():
    raise RuntimeError('Use review.py to initialize an isolated reviewer workspace first.')
artifacts = work / 'artifacts'
artifacts.mkdir(exist_ok=True)
for relative, name in [('packages/ui-mobile-base/ios/TNSWidgets', 'TNSWidgets'), ('packages/winter-tc/ios/NSCWinterTC', 'NSCWinterTC')]:
    directory = work / 'core' / relative
    output = work / 'build' / name
    for sdk, platform in [('appletvos', 'tvOS'), ('appletvsimulator', 'tvOS Simulator')]:
        subprocess.run(['xcodebuild', '-project', str(directory / (name + '.xcodeproj')), '-scheme', name, '-sdk', sdk, '-configuration', 'Release', '-destination', 'generic/platform=' + platform, 'build', 'BUILD_DIR=' + str(output), 'SKIP_INSTALL=NO', 'BUILD_LIBRARY_FOR_DISTRIBUTION=YES', 'CODE_SIGNING_ALLOWED=NO', '-quiet'], check=True)
    subprocess.run(['xcodebuild', '-create-xcframework', '-framework', str(output / ('Release-appletvos/' + name + '.framework')), '-framework', str(output / ('Release-appletvsimulator/' + name + '.framework')), '-output', str(artifacts / (name + '.xcframework'))], check=True)
