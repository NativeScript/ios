// Named re-export through the local->HTTP boundary: "ns-slow-leaf" is a bare
// specifier the spec's import map points at a delayed ModuleTestServer URL,
// so this file needs no baked-in origin.
export { value as leaf } from "ns-slow-leaf";
