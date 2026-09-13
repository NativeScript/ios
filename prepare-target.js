const path = require('path');
const fs = require('fs');

const cmdArgs = process.argv.slice(2);
const target = cmdArgs[0]; // ios, visionos or tvos

const packagePath = path.join('package.json');
const packageJson = JSON.parse(fs.readFileSync(packagePath));

packageJson.name = `@nativescript/${target}`;
const names = { ios: 'iOS', visionos: 'visionOS', tvos: 'tvOS' };
packageJson.description = `NativeScript Runtime for ${names[target] || target}`;

fs.writeFileSync(packagePath, JSON.stringify(packageJson, null, 2));