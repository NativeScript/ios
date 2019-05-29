exports.runImportTests = function() {
    require("./tests/shared/Import/index");
}

exports.runRequireTests = function() {
    require("./tests/shared/Require/index");
}

exports.runWeakRefTests = function() {
    require("./tests/shared/WeakRef");
}

exports.runRuntimeTests = function() {
    require("./tests/shared/RuntimeTests");
}

exports.runWorkerTests = function() {
    require("./tests/shared/Workers/index");
}

exports.runAllTests = function() {
//    exports.runImportTests();
//    exports.runRequireTests();
//    exports.runWeakRefTests();
    exports.runRuntimeTests();
//    exports.runWorkerTests();
}
