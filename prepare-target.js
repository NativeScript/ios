const path = require('path');
const fs = require('fs');

const cmdArgs = process.argv.slice(2);
const target = cmdArgs[0]; // ios or visionos

const packagePath = path.join('package.json');
const packageJson = JSON.parse(fs.readFileSync(packagePath));

packageJson.name = `@nativescript/${target}`;
packageJson.description = `NativeScript Runtime for ${target === 'ios' ? 'iOS' : 'visionOS'}`;

fs.writeFileSync(packagePath, JSON.stringify(packageJson, null, 2));