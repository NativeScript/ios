// Asks for A's namespace through import() while A is still evaluating.
// Settling that promise reads `then` off the namespace — and A's `then` is
// still in its temporal dead zone — so the read throws inside the runtime's
// own Resolve. That used to be a bare .Check(), i.e. a process abort reachable
// from ordinary user code; it must surface as a rejection instead.
export const pending = import("./tdzThenA.mjs").then(
    function (ns) { return "resolved:" + String(ns && ns.marker); },
    function (e) { return "rejected:" + (e && e.constructor && e.constructor.name); });
