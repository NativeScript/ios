//require("./tests");

console.log("App start");
require("./tests/Infrastructure/timers");

// require("./tests");

setTimeout(() => {
  console.time("test");
  const fixtures = TNSPrimitives.alloc().init();
  //   const fn = functionWithInt;
  for (let i = 0; i < 1e6; i++) {
    // CONSOLE INFO test: 2242.479ms
    // functionWithInt(i);

    // CONSOLE INFO test: 653.860ms
    // fn(i);

    fixtures.methodWithInt(i);
  }
  console.timeEnd("test");
}, 1600);

UIApplicationMain(0, null, null, null);
