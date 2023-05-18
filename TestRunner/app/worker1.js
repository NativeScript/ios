//require("./tests");
require("./tests/Infrastructure/timers");

// console.log("hello, this is worker 1");

// if(global.Worker) {
//     global.myObj = NSObject.new();
//     console.log('has worker');
//     global.postMessage('hello');
//     global.worker = new global.Worker('./worker2.js');
//     global.worker.onerror = (e) => {
//         console.log(e);
//     }
//     global.worker.onmessage = (v) => {
//         console.log('worker1.js onmessage', v);
//     }
//     global.worker.postMessage('hello from worker1.js');
//     global.worker.postMessage('hello2 from worker1.js');
//     // worker.terminate();
//     setTimeout(() => global.worker = null, 100);
//     setTimeout(() => gc(), 101);
// }
// (function() {
//     console.log('creating worker2');
//   let w = new Worker("./worker2.js");
//   // w.onmessage = (v) => {
//   //   console.log("worker1.js onmessage", v);
//   // };
//   // w.postMessage({ data: "hello from worker1.js" });
//   // setTimeout(() => gc());
//   // setTimeout(() => {
//   //   w = null;
//   //   gc();
//   // }, 400);
// })();
//UIApplicationMain();

close();
