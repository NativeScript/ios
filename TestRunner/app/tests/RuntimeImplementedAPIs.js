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

describe("Performance object", () => {
  it("should be available", () => {
    expect(performance).toBeDefined();
  });
  it("should have a now function", () => {
    expect(performance.now).toBeDefined();
  });
  it("should have a now function that returns a number", () => {
    expect(typeof performance.now()).toBe("number");
  });
  it("should have timeOrigin", () => {
    expect(performance.timeOrigin).toBeDefined();
  });
  it("should have timeOrigin that is a number", () => {
    expect(typeof performance.timeOrigin).toBe("number");
  });
  it("should have timeOrigin that is greater than 0", () => {
    expect(performance.timeOrigin).toBeGreaterThan(0);
  });
  it("should be close to the current time", () => {
    const dateNow = Date.now();
    const performanceNow = performance.now();
    const timeOrigin = performance.timeOrigin;
    const performanceAccurateNow = timeOrigin + performanceNow;
    expect(Math.abs(dateNow - performanceAccurateNow)).toBeLessThan(10);
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
