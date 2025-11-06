// Entry module that re-exports values from a relative dependency
import defaultValue, { relativeValue, getDependencyPayload } from "./dependency.mjs";

export const viaDefault = defaultValue;
export const viaNamed = relativeValue;

export function readDependencyPayload() {
    const payload = getDependencyPayload();
    return typeof payload === "object" && payload.from === "dependency";
}
