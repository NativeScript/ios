// Test ES module for HTTP ESM loader validation (HMR-specific)
export const testValue = "http-esm-loaded";
export const timestamp = Date.now();

export default function testFunction() {
    return "HTTP ESM loader working at " + new Date().toISOString();
}

export { testFunction as namedExport };

// For HMR testing
export function getRandomValue() {
    return Math.random();
}

console.log("Test ESM module loaded via HTTP loader (HMR)");