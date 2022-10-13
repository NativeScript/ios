describe(module.id, function () {
    afterEach(function () {
        TNSClearOutput();
    });

    it("Constructor", function () {
        var str = new NSString();
        expect(str.isKindOfClass(NSString)).toBe(true);
    });

    it("Init", function () {
        var str = NSString.alloc().init();
        expect(str.isKindOfClass(NSString)).toBe(true);
    });

    it("InitWithString", function () {
        var str = NSString.alloc().initWithString('hello hello');
        expect(str.isKindOfClass(NSString)).toBe(true);
    });
    
    it("Marshals NSString with null character", function() {
        var JSObject = NSObject.extend({
            'x': function () {
                return this._x;
            }, 'setX:': function (x) {
                this._x = x;
            }
        }, {
            exposedMethods: {
                x: { returns: NSString },
                'setX:': { returns: interop.types.void, params: [NSString] }
            }
        });

        const data = 'null coming up: ' + String.fromCharCode(0) + ' and extra';

        var instance = JSObject.alloc().init();
        instance.setValueForKey(data, 'x');
        expect(instance.valueForKey('x')).toBe(data);
    });

    it("String", function () {
        var str = NSString.string();
        expect(str.isKindOfClass(NSString)).toBe(true);
    });

    it("StringWithString", function () {
        var str = NSString.stringWithString('hello hello');
        expect(str.isKindOfClass(NSString)).toBe(true);
    });

    it("PathWithComponents", function () {
        var str = NSString.pathWithComponents(['/', 'myPath', 'myFolder']);
        expect(typeof str).toBe('string');
        expect(str).toBe('/myPath/myFolder');
    });


    it("Constructor_MutableString", function () {
        var str = new NSMutableString();
        expect(str.isKindOfClass(NSString)).toBe(true);
        str.appendString('Test string');
    });

    it("Init_MutableString", function () {
        var str = NSMutableString.alloc().init();
        expect(str.isKindOfClass(NSString)).toBe(true);
        str.appendString('Test string');
    });

    it("InitWithString_MutableString", function () {
        var str = NSMutableString.alloc().initWithString('hello hello');
        expect(str.isKindOfClass(NSString)).toBe(true);
        str.appendString('Test string');
    });

    it("String_MutableString", function () {
        var str = NSMutableString.string();
        expect(str.isKindOfClass(NSString)).toBe(true);
        str.appendString('Test string');
    });

    it("StringWithString_MutableString", function () {
        var str = NSMutableString.stringWithString('hello hello');
        expect(str.isKindOfClass(NSString)).toBe(true);
        str.appendString('Test string');
    });

    it("PathWithComponents_MutableString", function () {
        var str = NSMutableString.pathWithComponents(['/', 'myPath', 'myFolder']);
        expect(typeof str == 'string', 'NSMutableString was not converted to javascript string');
        expect(str == '/myPath/myFolder');
    });

    it("StringWithCapacity", function () {
        var str = NSMutableString.stringWithCapacity(10);
        expect(str.isKindOfClass(NSString)).toBe(true);
        str.appendString('Test string');
        expect(str.toString()).toBe('Test string');
    });

    it("InitWithNSString_MutableString", function () {
        var str = NSMutableString.alloc().initWithString(NSString.stringWithString('Test string'));
        expect(str.isKindOfClass(NSString)).toBe(true);
        str.appendString('Test string');
    });

    it("InstanceStringMethod", function () {
        var str = NSString.stringWithString('Test string').stringByStandardizingPath;
        expect(str).toBe('Test string');
    });

    it("NSMutableAttributedString", function () {
        var str = NSMutableAttributedString.alloc().initWithString('hello');
        expect(str.string).toBe('hello');
    });

    it("NSMutableStringMarshalling", function () {
        var JSObject = NSObject.extend({
            'x': function () {
                return this._x;
            }, 'setX:': function (x) {
                this._x = x;
            }
        }, {
            exposedMethods: {
                x: { returns: NSMutableString },
                'setX:': { returns: interop.types.void, params: [NSMutableString] }
            }
        });

        var instance = JSObject.alloc().init();
        instance.setValueForKey(NSMutableString.alloc().initWithString('test'), 'x');

        // TODO
        expect(instance.valueForKey('x') instanceof NSMutableString).toBe(false);
        expect(instance.valueForKey('x').description).toBeUndefined();

        // expect(instance.x() instanceof NSMutableString).toBe(true);
        // expect(instance.x().description).toBe('test');

        // expect(instance.x().copy()).toBe('test');
    });
});
