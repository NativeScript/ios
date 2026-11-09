"use strict";

// The `ns:interop/ios` builtin module (also reachable as `ns:interop/visionos`
// and `ns:interop/macos`): the Apple-only interop helpers and the Objective-C
// types. See docs/ns-builtin-modules.md.

const { adopt, bufferFromData, types } = binding;
const { ObjectFreeze } = primordials;

exports.adopt = adopt;
exports.bufferFromData = bufferFromData;
exports.types = ObjectFreeze(types);
ObjectFreeze(exports);
