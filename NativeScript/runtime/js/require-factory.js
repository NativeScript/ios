function require_factory(requireInternal, dirName, policy) {
    return function require(modulePath) {
        if (global.__pauseOnNextRequire) {
            debugger;
            global.__pauseOnNextRequire = false;
        }
        // `policy` is an opaque native token selecting how an ES module graph
        // is evaluated; undefined means the strict default.
        return requireInternal(modulePath, dirName, policy);
    };
}
module.exports = require_factory;
