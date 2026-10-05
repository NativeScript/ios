describe(module.id, function () {
    function findAccessor(proto, name) {
        while (proto) {
            var descriptor = Object.getOwnPropertyDescriptor(proto, name);
            if (descriptor) {
                return descriptor;
            }
            proto = Object.getPrototypeOf(proto);
        }
        return undefined;
    }

    it("calls an instance method on the proxy target", function () {
        var target = NSMutableString.alloc().init();
        var proxy = new Proxy(target, {});

        proxy.appendString("abc");

        expect(target.toString()).toBe("abc");
        expect(proxy.length).toBe(3);
    });

    it("calls an instance method through nested proxies", function () {
        var target = NSMutableString.alloc().init();
        var proxy = new Proxy(new Proxy(target, {}), {});

        proxy.appendString("ab");
        proxy.appendString("c");

        expect(target.toString()).toBe("abc");
    });

    it("reads a native property through the proxy", function () {
        var target = NSMutableArray.alloc().init();
        target.addObject(1);
        target.addObject(2);
        var proxy = new Proxy(target, {});

        expect(proxy.count).toBe(2);
    });

    it("writes a native property through the proxy", function () {
        var target = NSOperation.alloc().init();
        var proxy = new Proxy(target, {});

        proxy.name = "proxied";

        expect(target.name).toBe("proxied");
        expect(proxy.name).toBe("proxied");
    });

    it("converts the proxy to the native description", function () {
        var target = NSMutableString.stringWithString("hello");
        var proxy = new Proxy(target, {});

        expect(String(proxy)).toBe("hello");
        expect("" + proxy).toBe("hello");
        expect(proxy.toString()).toBe("hello");
    });

    it("calls a class method through a proxied class constructor", function () {
        var proxy = new Proxy(NSString, {});

        var result = proxy.stringWithString("x");

        expect(result instanceof NSString).toBe(true);
        expect(result.toString()).toBe("x");
    });

    it("passes a proxied native object as a method argument", function () {
        var array = NSMutableArray.alloc().init();
        var object = NSObject.alloc().init();

        array.addObject(new Proxy(object, {}));

        expect(array.count).toBe(1);
        expect(array.objectAtIndex(0)).toBe(object);
    });

    it("passes a proxied JS array of native objects as an NSArray", function () {
        var a = NSObject.alloc().init();
        var b = NSObject.alloc().init();

        var array = NSArray.arrayWithArray(new Proxy([a, b], {}));

        expect(array.count).toBe(2);
        expect(array.objectAtIndex(0)).toBe(a);
        expect(array.objectAtIndex(1)).toBe(b);
    });

    it("passes a proxied plain object as an NSDictionary", function () {
        var dictionary = NSDictionary.dictionaryWithDictionary(new Proxy({ key: "value" }, {}));

        expect(dictionary.count).toBe(1);
        expect(dictionary.objectForKey("key")).toBe("value");
    });

    it("passes proxied structs and struct initializers by value", function () {
        var fromStruct = NSValue.valueWithRange(new Proxy(NSMakeRange(1, 2), {}));
        expect(fromStruct.rangeValue.location).toBe(1);
        expect(fromStruct.rangeValue.length).toBe(2);

        var fromObject = NSValue.valueWithRange(new Proxy({ location: 3, length: 4 }, {}));
        expect(fromObject.rangeValue.location).toBe(3);
        expect(fromObject.rangeValue.length).toBe(4);
    });

    it("throws a TypeError for a revoked proxy receiver", function () {
        var revocable = Proxy.revocable(NSMutableString.alloc().init(), {});
        revocable.revoke();

        expect(function () {
            NSMutableString.prototype.appendString.call(revocable.proxy, "x");
        }).toThrowError(TypeError, /revoked Proxy/);
        expect(function () {
            findAccessor(NSMutableString.prototype, "length").get.call(revocable.proxy);
        }).toThrowError(TypeError, /revoked Proxy/);
    });

    it("throws a TypeError for a revoked proxy argument", function () {
        var array = NSMutableArray.alloc().init();
        var revocable = Proxy.revocable(NSObject.alloc().init(), {});
        revocable.revoke();

        expect(function () {
            array.addObject(revocable.proxy);
        }).toThrowError(TypeError, /revoked Proxy/);
        expect(array.count).toBe(0);
    });

    it("throws a TypeError for a proxy whose target is not a native object", function () {
        var proxy = new Proxy({}, {});

        expect(function () {
            findAccessor(NSString.prototype, "length").get.call(proxy);
        }).toThrowError(TypeError, /not a native object/);
        expect(function () {
            NSMutableString.prototype.appendString.call(proxy, "x");
        }).toThrowError(TypeError, /not a native object/);
        expect(function () {
            findAccessor(NSOperation.prototype, "name").set.call(proxy, "x");
        }).toThrowError(TypeError, /not a native object/);
        expect(function () {
            NSString.stringWithString.call(new Proxy(function () {}, {}), "x");
        }).toThrowError(TypeError, /not a native object/);
    });

    it("releases the native counterpart of the proxy target", function () {
        var target = NSMutableString.alloc().init();
        var proxy = new Proxy(target, {});

        __releaseNativeCounterpart(proxy);

        expect(function () {
            __releaseNativeCounterpart(target);
        }).toThrowError(/not a native wrapper/);
        expect(function () {
            __releaseNativeCounterpart(proxy);
        }).toThrowError(/not a native wrapper/);
    });

    it("consults proxy traps for the lookup and calls the target natively", function () {
        var target = NSMutableString.alloc().init();
        var accessed = [];
        var proxy = new Proxy(target, {
            get: function (obj, key, receiver) {
                accessed.push(key);
                return Reflect.get(obj, key, receiver);
            }
        });

        proxy.appendString("abc");

        expect(accessed).toContain("appendString");
        expect(target.toString()).toBe("abc");
        expect(proxy.length).toBe(3);
        expect(accessed).toContain("length");
    });
});
