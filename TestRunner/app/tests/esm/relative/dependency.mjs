// Dependency module used to exercise relative import resolution in the HTTP ESM loader tests
export const relativeValue = "relative-import-success";

export function getDependencyPayload() {
    return {
        from: "dependency",
        timestamp: Date.now(),
    };
}

export default relativeValue;
