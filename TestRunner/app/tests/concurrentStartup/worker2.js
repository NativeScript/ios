// Entry for WorkerConcurrentStartupTests: loads the fixture modules the
// parent already compiled (so their code caches are warm) and reports the
// values it observed, keyed by module name. Each entry uses a different
// load order so workers starting together read different files at once.
var values = {};
values.modC = require("./modC").value;
values.modD = require("./modD").value;
values.modE = require("./modE").value;
values.modF = require("./modF").value;
values.modA = require("./modA").value;
values.modB = require("./modB").value;

postMessage({ values: values });
