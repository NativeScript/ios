// Static `import` of the builtins, so the ES module resolve callback is
// exercised too (dynamic import() has its own fast path).
import interopDefault, { Pointer, types } from "ns:interop";
import { adopt, types as appleTypes } from "ns:interop/ios";
import visionosDefault from "ns:interop/visionos";
import * as iosNamespace from "ns:interop/ios";
import * as macosNamespace from "ns:interop/macos";

export { interopDefault, Pointer, types, adopt, appleTypes, visionosDefault, iosNamespace, macosNamespace };
