// A worker entry declaring its own `const self`. The runtime used to prepend a
// six-line preamble that declared `self` too, which made this a SyntaxError and
// shifted every stack line number by six.
const self = { tag: "own-self" };

// Line 8 in this file, on purpose: the spec asserts the reported line number is
// this one and not this one plus the length of a preamble.
function throwHere() { throw new Error("line-probe"); }

globalThis.onmessage = function () {
    let line = -1;
    try {
        throwHere();
    } catch (e) {
        const match = /esmEntrySelfDeclWorker\.mjs:(\d+)/.exec(String(e.stack || ""));
        line = match ? Number(match[1]) : -1;
    }
    postMessage(self.tag + ":" + line);
};
