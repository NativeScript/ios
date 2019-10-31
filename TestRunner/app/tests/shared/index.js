exports.runImportTests = function() {
    require("./Import/index");
}

exports.runRequireTests = function() {
    require("./Require/index");
}

exports.runWeakRefTests = function() {
    require("./WeakRef");
}

exports.runRuntimeTests = function() {
    require("./RuntimeTests");
}

exports.runWorkerTests = function() {
    require("./Workers/index");
}

exports.runAllTests = function() {
//    exports.runImportTests();
    exports.runRequireTests();
    exports.runWeakRefTests();
    exports.runRuntimeTests();
    exports.runWorkerTests();
}
