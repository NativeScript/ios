// //require("./tests");
// // require("./tests/Infrastructure/timers");
require("./tests/Infrastructure/timers");

// // console.log('hello');
// if(global.Worker) {
//     console.log('has worker2');
//     global.postMessage('hello');

//     // worker.terminate();

//     // setTimeout(() => worker.terminate(), 1000);
// }

// global.onmessage = (v) => {
//     console.log('worker2.js onmessage', v);
//     global.postMessage('hello from worker2.js');
//     setTimeout(() => {
//         self.close();
//         console.log('after close');
//         global.postMessage('hello from worker2.js after close');
//     }, 500)
//     self.close();
//     // console.log('after close');
//     // global.postMessage('hello from worker2.js after close');
// }
// const setInterval2 = (fn, time) => {
//     const repeater = () => {
//         fn();
//         setTimeout(repeater, time);
//     };
//     setTimeout(repeater, time);
// };
// setInterval2(() => console.log(`worker2 timeout`), 100);
// //UIApplicationMain("abc", null, null, null);

// onmessage = (msg) => {
//   postMessage(msg.data + " pong");
// };
// // onerror = (err) => {
// //   postMessage("pong");
// //   return false;
// // };
// // onclose = () => {
// //   throw new Error("error thrown from close()");
// // };

// console.log('this is worker 2');

// // setInterval(() => {
// //     console.log('running pong')
// //     postMessage("pong");
// // }, 100);

// const setInterval = (fn, time) => {
//     const repeater = () => {
//         fn();
//         setTimeout(repeater, time);
//     };
//     setTimeout(repeater, time);
// };

// setInterval(() => {
//     postMessage("pong");
// }, 100);

// setTimeout(() => {
//     close();
//     postMessage("pong");
//     postMessage("pong");
//     postMessage("pong");
//     postMessage("pong");
// }, 3000)

// setTimeout(() => {
//     close();
// })


close();