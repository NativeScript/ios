// HMR hot.data test module (.mjs)

export function getHot() {
    return (typeof import.meta !== "undefined" && import.meta) ? import.meta.hot : undefined;
}

export function getHotData() {
    const hot = getHot();
    return hot ? hot.data : undefined;
}

export function setHotValue(value) {
    const hot = getHot();
    if (!hot || !hot.data) {
        throw new Error("import.meta.hot.data is not available");
    }
    hot.data.value = value;
    return hot.data.value;
}

export function getHotValue() {
    const hot = getHot();
    return hot && hot.data ? hot.data.value : undefined;
}

export function testHotApi() {
    const hot = getHot();
    const result = {
        ok: false,
        hasHot: !!hot,
        hasData: !!(hot && hot.data),
        hasAccept: !!(hot && typeof hot.accept === "function"),
        hasDispose: !!(hot && typeof hot.dispose === "function"),
        hasDecline: !!(hot && typeof hot.decline === "function"),
        hasInvalidate: !!(hot && typeof hot.invalidate === "function"),
        pruneIsFalse: !!(hot && hot.prune === false),
    };

    try {
        if (hot && typeof hot.accept === "function") {
            hot.accept(function () {});
        }
        if (hot && typeof hot.dispose === "function") {
            hot.dispose(function () {});
        }
        if (hot && typeof hot.decline === "function") {
            hot.decline();
        }
        if (hot && typeof hot.invalidate === "function") {
            hot.invalidate();
        }
        result.ok =
            result.hasHot &&
            result.hasData &&
            result.hasAccept &&
            result.hasDispose &&
            result.hasDecline &&
            result.hasInvalidate &&
            result.pruneIsFalse;
    } catch (e) {
        result.error = (e && e.message) ? e.message : String(e);
    }

    return result;
}

console.log("HMR hot.data ext module loaded (.mjs)");
