TNSLog('main started');
require('tns-core-modules/shared/Require/RequirePriority/dependency1');
require('tns-core-modules/shared/Require/RequirePriority/dependency2');
require(__dirname + '/dependency3');
require(__dirname + '/dependency4');
require(__dirname + '/dependency5');
TNSLog(' main ended');
