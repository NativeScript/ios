var center = NSNotificationCenter.defaultCenter;
[{ answer: 42 }, new Map([["answer", 42]]), [1, 2], new Uint8Array([3, 4])].forEach(function (value) {
    center.postNotificationNameObjectUserInfo("adapter-teardown-read", value, null);
});
postMessage("sent");
