// Entry of a local->local->http graph whose HTTP leaf answers only after a
// multi-second transform delay (ModuleTestServer /esm/slow/req-leaf.mjs).
// Exercises the pumped graph walk's fetch budget through require(): the leaf
// must arrive within the walk's deadline on its first request.
import { leaf as leafValue } from "./slow-mid.mjs";

export const leaf = leafValue;
