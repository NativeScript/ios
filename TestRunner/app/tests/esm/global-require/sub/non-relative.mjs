// The global require, reached from an ES module that only ever passes it
// non-relative specifiers.
export function load(specifier) {
    return require(specifier);
}
