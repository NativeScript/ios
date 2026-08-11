describe("Runtime exposes", function () {
  it("__time a low overhead, high resolution, time in ms.", function() {
    var dateTimeStart = Date.now();
    var timeStart = __time();
    var acc = 0;
    var s = CACurrentMediaTime();
     
    while (Date.now() - dateTimeStart < 5)
    {
    }
     
    var dateTimeEnd = Date.now();
    var timeEnd = __time();
    var dateDelta = dateTimeEnd - dateTimeStart;
    var timeDelta = timeEnd - timeStart;
    expect(Math.abs(dateDelta - timeDelta)).toBeLessThan(dateDelta * 0.25);
  });
});

// The shared Performance suite (submodule) gates itself on the API being
// present and skips otherwise; this unguarded canary makes absence on THIS
// runtime a failure rather than a silent skip.
describe("Performance API canary", () => {
  it("implements the Performance API", () => {
    expect(typeof performance.mark).toBe("function");
    expect(typeof PerformanceObserver).toBe("function");
  });
});

describe("queueMicrotask", () => {
  it("should be defined as a function", () => {
    expect(typeof queueMicrotask).toBe("function");
  });

  it("should throw TypeError when callback is not a function", () => {
    expect(() => queueMicrotask(null)).toThrow();
    expect(() => queueMicrotask(42)).toThrow();
    expect(() => queueMicrotask({})).toThrow();
  });

  it("runs after current stack but before setTimeout(0)", (done) => {
    const order = [];
    queueMicrotask(() => order.push("microtask"));
    setTimeout(() => {
      order.push("timeout");
      expect(order).toEqual(["microtask", "timeout"]);
      done();
    }, 0);
    expect(order.length).toBe(0);
  });

  it("preserves ordering with Promise microtasks", (done) => {
    const order = [];
    queueMicrotask(() => order.push("qm1"));
    Promise.resolve().then(() => order.push("p"));
    queueMicrotask(() => order.push("qm2"));
    setTimeout(() => {
      expect(order).toEqual(["qm1", "p", "qm2"]);
      done();
    }, 0);
  });
});

// The shared StructuredClone suite skips itself where the API is missing, which
// would turn this runtime losing structuredClone into a green run. This spec is
// deliberately unguarded so that regression fails instead.
describe("structuredClone canary", () => {
  it("is implemented by this runtime", () => {
    expect(typeof structuredClone).toBe("function");
  });
});
