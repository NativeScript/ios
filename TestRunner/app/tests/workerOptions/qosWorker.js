// Entry for WorkerOptionsTests: reports the quality of service the runtime
// gave this worker's thread, which is the only observable effect of the
// `ios.priority` option.
postMessage({ qos: NSThread.currentThread.qualityOfService });
