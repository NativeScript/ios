// https://github.com/NativeScript/NativeScript/blob/master/tns-core-modules/timer/timer.ios.ts

var timeoutCallbacks = new Map();
var timerId = 0;

var TimerTargetImpl = (function (_super) {
    __extends(TimerTargetImpl, _super);
    function TimerTargetImpl() {
        return _super !== null && _super.apply(this, arguments) || this;
    }
    TimerTargetImpl.initWithCallback = function (callback, id, shouldRepeat) {
        var handler = TimerTargetImpl.new();
        handler.callback = callback;
        handler.id = id;
        handler.shouldRepeat = shouldRepeat;
        return handler;
    };
    TimerTargetImpl.prototype.tick = function (timer) {
        if (!this.disposed) {
            this.callback();
        }
        if (!this.shouldRepeat) {
            this.unregister();
        }
    };
    TimerTargetImpl.prototype.unregister = function () {
        if (!this.disposed) {
            this.disposed = true;
            var timer = timeoutCallbacks.get(this.id).k;
            timer.invalidate();
            timeoutCallbacks.delete(this.id);
        }
    };
    TimerTargetImpl.ObjCExposedMethods = {
        "tick": { returns: interop.types.void, params: [NSTimer] }
    };
    return TimerTargetImpl;
}(NSObject));
function createTimerAndGetId(callback, milliseconds, shouldRepeat) {
    timerId++;
    var id = timerId;
    var timerTarget = TimerTargetImpl.initWithCallback(callback, id, shouldRepeat);
    var timer = NSTimer.scheduledTimerWithTimeIntervalTargetSelectorUserInfoRepeats(milliseconds / 1000, timerTarget, "tick", null, shouldRepeat);
    NSRunLoop.currentRunLoop.addTimerForMode(timer, NSRunLoopCommonModes);
    var pair = { k: timer, v: timerTarget };
    timeoutCallbacks.set(id, pair);
    return id;
}

function setTimeout(callback, milliseconds) {
    if (milliseconds === void 0) { milliseconds = 0; }
    var args = [];
    for (var _i = 2; _i < arguments.length; _i++) {
        args[_i - 2] = arguments[_i];
    }
    var invoke = function () { return callback.apply(void 0, args); };
    return createTimerAndGetId(invoke, milliseconds, false);
}

function clearTimeout(id) {
    var pair = timeoutCallbacks.get(id);
    if (pair) {
        pair.v.unregister();
    }
}

global.setTimeout = setTimeout;
global.clearTimeout = clearTimeout;
