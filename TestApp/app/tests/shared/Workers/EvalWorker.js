onmessage = function(msg) {
    var value = msg.data.value;
    eval(msg.data.eval || "");
}