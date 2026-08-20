// Inside the scope, but reaching the leaf through import(). The dynamic path
// must consult the same scope cascade the static one does: it used to resolve
// a second time with no referrer, which dropped every scope and handed back
// the top-level mapping instead.
export async function loadLeaf() {
    const mod = await import("ns-scoped-leaf");
    return mod.name;
}
