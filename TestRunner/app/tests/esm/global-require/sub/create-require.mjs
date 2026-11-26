import { createRequire } from "ns:module";

const moduleRequire = createRequire(import.meta.url);

export function load(specifier) {
    return moduleRequire(specifier);
}
