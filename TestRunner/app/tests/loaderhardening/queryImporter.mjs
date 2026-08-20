// A cache-busted specifier of the kind a dev server emits. The query is URL
// syntax, so this names queryLeaf.mjs — not a file called "queryLeaf.mjs?v=1".
import { leaf } from "./queryLeaf.mjs?v=1";
export const value = leaf;
