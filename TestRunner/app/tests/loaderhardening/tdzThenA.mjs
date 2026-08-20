// Half of a cycle that exports `then`. B evaluates before this body runs, so
// while B is running `then` is a `const` still in its temporal dead zone.
import "./tdzThenB.mjs";
export const then = undefined;
export const marker = "tdz-a";
