// Tells the parent the entry is running, then never returns: only a
// termination interrupt can end this worker.
postMessage("spinning");
for (;;) {}
