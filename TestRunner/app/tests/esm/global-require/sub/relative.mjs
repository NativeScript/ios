// An ES module has no require of its own: `require` here is the global one.
export function load(specifier) {
    return require(specifier);
}
