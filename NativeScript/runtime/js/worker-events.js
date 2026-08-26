"use strict";
// Worker (HTML Standard §10.2.6) and the worker global scope (§10.2.1) as
// EventTargets: both deliver MessageEvents instead of the runtime's historical
// direct call of an `onmessage` property.
//
// Eager, because the handler attributes have to exist before app code assigns
// one. MessageEvent itself is pulled in on the first delivery, so a worker
// nobody talks to never runs that builtin.
const { ObjectDefineProperty, ObjectSetPrototypeOf } = primordials;

const {
  EventTarget,
  defineEventHandler,
  dispatchEventRethrowing,
  globalEventTarget,
} = require("internal/events");

const g = globalThis;

let MessageEvent;
function getMessageEvent() {
  if (MessageEvent === undefined) {
    ({ MessageEvent } = require("internal/message-event"));
  }
  return MessageEvent;
}

// The delivery callout, invoked by native with the receiving target as `this`:
// the Worker object on the parent isolate, the global scope's EventTarget
// inside a worker. `ports` is the array of MessagePorts the message
// transferred, or undefined when it carried none.
//
// A handler that throws propagates back into the calling native frame: that
// is what feeds the worker's onerror chain — the worker scope's handler
// first, then the parent's — which the cross-runtime worker suite asserts.
function emitMessage(data, ports, type) {
  const MessageEventCtor = getMessageEvent();
  dispatchEventRethrowing(this, new MessageEventCtor(type, { data, ports }));
}

ObjectSetPrototypeOf(g.Worker.prototype, EventTarget.prototype);
defineEventHandler(g.Worker.prototype, "message");
defineEventHandler(g.Worker.prototype, "messageerror");
// `error` is a handler attribute and nothing more: the worker error path still
// reads `onerror` off the worker object and calls it with a plain error
// record, so no event is ever dispatched for it and addEventListener("error")
// on a Worker stays inert.
defineEventHandler(g.Worker.prototype, "error");

// The global scope's handler attributes are defined against the EventTarget
// backing the global listener methods, which is what native dispatches on and
// what globalThis.addEventListener registers with — so a handler and an
// addEventListener registration interleave in assignment order. globalThis
// only forwards.
defineEventHandler(globalEventTarget, "message");
defineEventHandler(globalEventTarget, "messageerror");
for (const name of ["onmessage", "onmessageerror"]) {
  ObjectDefineProperty(g, name, {
    __proto__: null,
    get() {
      return globalEventTarget[name];
    },
    set(value) {
      globalEventTarget[name] = value;
    },
    enumerable: true,
    configurable: true,
  });
}

module.exports = { emitMessage };
