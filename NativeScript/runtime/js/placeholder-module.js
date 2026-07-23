// Completion value is a factory invoked by ModuleInternal::CreatePlaceholderModule
// with the per-module error message. Every touch of the returned exports object
// throws, so optional modules that are absent fail loudly only when actually used.
(function createPlaceholder(errorMessage) {
    const error = new Error(errorMessage);
    return new Proxy({}, {
        get: function (target, prop) {
            throw error;
        },
        set: function (target, prop, value) {
            throw error;
        },
        has: function (target, prop) {
            return false;
        },
        ownKeys: function (target) {
            return [];
        },
        getPrototypeOf: function (target) {
            return null;
        }
    });
})
