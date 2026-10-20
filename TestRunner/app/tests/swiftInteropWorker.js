// SwiftDemo from a worker isolate: calls work there, main-actor members are
// refused off the main thread, and async results come back to the worker.
var SwiftDemo = require("ns:swift/SwiftDemo");
var result = { greeting: new SwiftDemo.Demo().greet("worker") };
try {
    new SwiftDemo.Palette();
    result.palette = "constructed";
} catch (e) {
    result.palette = e.message;
}
SwiftDemo.makeTrackerLater(5).then(function (tracker) {
    result.trackerId = tracker.id;
    return SwiftDemo.delayedEcho("from worker", 0.001);
}).then(function (text) {
    result.echo = text;
    postMessage(result);
}, function (error) {
    result.echo = "error: " + error.message;
    postMessage(result);
});
