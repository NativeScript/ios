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
