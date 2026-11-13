// ns:runtime's leak diagnostics (WrapperLifetimeLeaks.mm) against cycle shapes
// planted per wrapper lifetime mode.
describe("Wrapper lifetime leak cycles", function () {
    var runtime = require("ns:runtime");
    var mode = runtime.getConfig("wrapperLifetimeMode");
    var rooted = mode === "rooted";
    var canary = mode === "canary";

    // One class per shape, so a report names the shape.
    function shape(name) {
        return NSObject.extend({}, { name: name });
    }
    var SelfRef = shape("TNSLeakSelfRef");
    var Closure = shape("TNSLeakClosure");
    var NativeCycle = shape("TNSLeakNativeCycle");
    var BlockCycle = shape("TNSLeakBlockCycle");
    var OwnedSelfRef = shape("TNSLeakOwnedSelfRef");
    var WeakBackRef = shape("TNSLeakWeakBackRef");
    var Unexplained = shape("TNSLeakUnexplained");
    var Counted = shape("TNSLeakCounted");

    // Which shapes leak, per mode: state referencing its own object only under
    // canary, a cycle through a native retain under both new modes, and a JS
    // block's callback (a strong handle) under every mode.
    var leaks = {
        TNSLeakSelfRef: canary,
        TNSLeakClosure: canary,
        TNSLeakNativeCycle: rooted || canary,
        TNSLeakBlockCycle: true,
        TNSLeakOwnedSelfRef: false,
        TNSLeakWeakBackRef: false,
        TNSLeakUnexplained: false,
    };

    function scrub(n) {
        return n > 0 ? scrub(n - 1) + n : 0;
    }

    function settle(rounds, callback) {
        scrub(300);
        __collect();
        __collect();
        setTimeout(function () {
            NSObject.new();
            if (rounds > 1) {
                settle(rounds - 1, callback);
            } else {
                callback();
            }
        }, 10);
    }

    function cyclesNaming(report, name) {
        return report.cycles.filter(function (cycle) {
            return cycle.members.some(function (member) {
                return member.className.indexOf(name) !== -1;
            });
        });
    }

    it("counts live wrappers and states per class", function () {
        var held = [Counted.new(), Counted.new(), Counted.new()];
        held.forEach(function (o, i) {
            o.index = i;
        });
        var counts = runtime.getWrapperClassCounts();
        var name = Object.keys(counts).filter(function (n) {
            return n.indexOf("TNSLeakCounted") !== -1;
        })[0];
        expect(name).toBeDefined();
        expect(counts[name].wrappers).toBe(3);
        expect(counts[name].states).toBe(canary ? 3 : 0);
        expect(held.length).toBe(3);
    });

    it("rejects a non-object argument", function () {
        expect(function () {
            runtime.findLeakCycles(true);
        }).toThrowError(TypeError);
    });

    describe("planted shapes", function () {
        var owner = NSMutableArray.new();
        // Holds its element strongly, but the probe treats it as a weak
        // container: an owner it cannot see.
        var hiddenOwner = NSHashTable.hashTableWithOptions(0 /* NSPointerFunctionsStrongMemory */);
        // Weak watchers, to reach the leaked objects again and break their cycles.
        var watched = NSHashTable.weakObjectsHashTable();
        var reports = {};

        beforeAll(function (done) {
            (function () {
                var selfRef = SelfRef.new();
                selfRef.me = selfRef;

                var closure = Closure.new();
                closure.onTap = function () {
                    return closure;
                };

                var nativeCycle = NativeCycle.new();
                var list = NSMutableArray.new();
                list.addObject(nativeCycle);
                nativeCycle.list = list;

                var blockCycle = BlockCycle.new();
                blockCycle.op = NSBlockOperation.blockOperationWithBlock(function () {
                    return blockCycle;
                });

                var ownedSelfRef = OwnedSelfRef.new();
                ownedSelfRef.me = ownedSelfRef;
                owner.addObject(ownedSelfRef);

                var weakBackRef = WeakBackRef.new();
                weakBackRef.me = new WeakRef(weakBackRef);

                // Two non-owning pointers (NSValue's storage) explain more
                // retains than the object has.
                var unexplained = Unexplained.new();
                hiddenOwner.addObject(unexplained);
                unexplained.values = [
                    NSValue.valueWithNonretainedObject(unexplained),
                    NSValue.valueWithNonretainedObject(unexplained),
                ];

                [selfRef, closure, nativeCycle, blockCycle, ownedSelfRef, weakBackRef, unexplained].forEach(
                    function (o) {
                        watched.addObject(o);
                    }
                );
            })();
            settle(3, function () {
                reports.default = runtime.findLeakCycles();
                reports.strict = runtime.findLeakCycles({ strict: true });
                done();
            });
        });

        afterAll(function () {
            watched.allObjects.enumerateObjectsUsingBlock(function (o) {
                delete o.me;
                delete o.onTap;
                delete o.values;
                if (o.list) {
                    o.list.removeAllObjects();
                    delete o.list;
                }
                delete o.op;
            });
            owner.removeAllObjects();
            hiddenOwner.removeAllObjects();
        });

        it("describe the run", function () {
            [reports.default, reports.strict].forEach(function (report) {
                expect(report.mode).toBe(mode);
                expect(report.nativeObjects).toBeGreaterThan(0);
                expect(report.snapshotNodes).toBeGreaterThan(0);
                expect(report.truncated).toBe(false);
            });
            expect(reports.default.strict).toBe(false);
            expect(reports.strict.strict).toBe(true);
        });

        Object.keys(leaks).forEach(function (name) {
            it("reports " + name + " by default only when it leaks under this mode", function () {
                var found = cyclesNaming(reports.default, name);
                expect(found.length > 0).toBe(leaks[name]);
                found.forEach(function (cycle) {
                    expect(cycle.uncertain).toBe(false);
                    expect(cycle.signature).not.toMatch(/0x[0-9a-f]+/);
                });
            });
        });

        it("reports an over-explained object's cycle only when strict, marked uncertain", function () {
            var found = cyclesNaming(reports.strict, "TNSLeakUnexplained");
            expect(found.length > 0).toBe(rooted || canary);
            found.forEach(function (cycle) {
                expect(cycle.uncertain).toBe(true);
                expect(cycle.reasons.join("\n")).toMatch(/TNSLeakUnexplained 0x[0-9a-f]+: retainCount \d+ is less than the \d+ retains/);
            });
        });

        it("reports every default cycle when strict, and only uncertain ones besides", function () {
            var strictSignatures = reports.strict.cycles.map(function (c) {
                return c.signature;
            });
            reports.default.cycles.forEach(function (cycle) {
                expect(strictSignatures).toContain(cycle.signature);
            });
            var defaultSignatures = reports.default.cycles.map(function (c) {
                return c.signature;
            });
            reports.strict.cycles.forEach(function (cycle) {
                if (defaultSignatures.indexOf(cycle.signature) === -1) {
                    expect(cycle.uncertain).toBe(true);
                }
            });
        });

        it("keeps the controls alive", function () {
            expect(owner.count).toBe(1);
            expect(hiddenOwner.count).toBe(1);
        });
    });

    it("logs class counts on a memory warning", function () {
        expect(function () {
            NSNotificationCenter.defaultCenter.postNotificationNameObject(
                "UIApplicationDidReceiveMemoryWarningNotification",
                null
            );
        }).not.toThrow();
    });
});
