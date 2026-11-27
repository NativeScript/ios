// The require() call sits in a classic script (a Function body) that this ES
// module merely creates and exports.
export const load = new Function("specifier", "return require(specifier);");
