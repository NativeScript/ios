// A CommonJS module calling the global require rather than its own.
exports.load = function (specifier) {
    return globalThis.require(specifier);
};
