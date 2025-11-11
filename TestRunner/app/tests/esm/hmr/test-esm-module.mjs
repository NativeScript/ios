// Test ES module for HTTP ESM loader validation (HMR-specific)
export const testValue = "http-esm-loaded";
export const timestamp = Date.now();

const hotContext = (typeof import.meta !== "undefined" && import.meta) ? import.meta.hot : undefined;

if (typeof globalThis !== "undefined") {
    globalThis.__nsLastHttpEsmHotContext = hotContext;
}

export function getHotContext() {
    return hotContext;
}

export function callInvalidateSafe() {
    if (!hotContext || typeof hotContext.invalidate !== "function") {
        return false;
    }
    hotContext.invalidate();
    return true;
}

export default function testFunction() {
    return "HTTP ESM loader working at " + new Date().toISOString();
}

export { testFunction as namedExport };

// For HMR testing
export function getRandomValue() {
    return Math.random();
}

console.log("Test ESM module loaded via HTTP loader (HMR)");