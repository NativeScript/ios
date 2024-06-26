const path = require('path');
const fs = require('fs');

const cmdArgs = process.argv.slice(2);
const target = cmdArgs[0]; // ios, tvos or visionos

const packagePath = path.join('package.json');
const packageJson = JSON.parse(fs.readFileSync(packagePath));

packageJson.name = `@nativescript/${target}`;
let targetName = 'iOS';
switch (target) {
    case 'tvos':
        targetName = 'tvOS';
        break;
    case 'visionos':
        targetName = 'visionOS';
        break;

}
packageJson.description = `NativeScript Runtime for ${targetName}`;

fs.writeFileSync(packagePath, JSON.stringify(packageJson, null, 2));