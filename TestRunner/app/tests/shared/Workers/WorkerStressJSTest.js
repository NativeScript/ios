function stress() {
    (new String("abc")) + (new Date).toGMTString() + null;
    new Array(new Number(0), 1, 2, 3);
    new RegExp("");
    "foo".match(/[a-z]+/);
    "a".localeCompare("A");
    try {
        throw 0;
    } catch (ex) {
    }
}

for (var i = 0; i < 10000; i++) {
    try {
        stress();
        eval("stress()");
    } catch (ex) {
        postMessage("Unexpected exception: " + ex);
    }
}