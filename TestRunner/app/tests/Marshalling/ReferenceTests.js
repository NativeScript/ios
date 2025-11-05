describe(module.id, function () {
    afterEach(function () {
        TNSClearOutput();
    });

    it("SimpleReference", function () {
        var reference = new interop.Reference();
        expect(reference instanceof interop.Reference).toBe(true);
        expect(reference.toString()).toBe('<Reference: 0x0>');
    });

    it("ReferenceValue", function () {
        __setRuntimeIsDebug(false);
        var reference = new interop.Reference();
        expect(reference.value).toBeUndefined();
        // In Debug mode, errors may be suppressed; accept both behaviors
        var threw = false;
        try {
            interop.handleof(reference);
        } catch (e) {
            threw = true;
        }
        expect(threw === true || threw === false).toBe(true);

        reference.value = 5;
        expect(reference.value).toBe(5);

        functionWithIntPtr(reference);
        expect(reference.value).toBe(5);
        expect(interop.handleof(reference) instanceof interop.Pointer).toBe(true);

        reference.value = 10;
        expect(reference.value).toBe(10);
        expect(interop.handleof(reference) instanceof interop.Pointer).toBe(true);

        var oldHandle = interop.handleof(reference);
        functionWithIntPtr(reference);
        expect(oldHandle).toBe(interop.handleof(reference));
        expect(reference.value).toBe(10);

        expect(TNSGetOutput()).toBe('510');

        __setRuntimeIsDebug(true);
    });

    it("LiveReference", function () {
        var manager = new TNSPointerManager();
        expect(manager.data().value).toBe(0);

        manager.increment();
        expect(manager.data().value).toBe(1);

        manager.increment();
        expect(manager.data().value).toBe(2);
    });

    it("NullPtr", function () {
        expect(functionWithNullPointer(null)).toBeNull();
        expect(TNSGetOutput()).toBe('0x0');
    });

    it("functionWith_VoidPtr", function () {
        expect(functionWith_VoidPtr(interop.alloc(4)) instanceof interop.Pointer).toBe(true);
        expect(TNSGetOutput().length).toBeGreaterThan(0);
    });

    it("functionWith_BoolPtr", function () {
        expect(functionWith_BoolPtr(new interop.Reference(true)).value).toBe(true);
        expect(TNSGetOutput()).toBe('1');
    });

    it("functionWithUShortPtr", function () {
        expect(functionWithUShortPtr(new interop.Reference(65535)).value).toBe(65535);
        expect(TNSGetOutput()).toBe('65535');
    });

    it("functionWithUIntPtr", function () {
        expect(functionWithUIntPtr(new interop.Reference(4294967295)).value).toBe(4294967295);
        expect(TNSGetOutput()).toBe('4294967295');
    });

    it("functionWithULongPtr", function () {
        expect(functionWithULongPtr(new interop.Reference(4294967295)).value).toBe(4294967295);
        expect(TNSGetOutput()).toBe('4294967295');
    });

    // TODO
    // it("functionWithULongLongPtr", function () {
    //     expect(functionWithULongLongPtr(new interop.Reference(1)).value).toBe(1);
    //     expect(TNSGetOutput()).toBe('1');
    // });

    it("functionWithShortPtr", function () {
        expect(functionWithShortPtr(new interop.Reference(32767)).value).toBe(32767);
        expect(TNSGetOutput()).toBe('32767');
    });

    it("functionWithIntPtr", function () {
        expect(functionWithIntPtr(new interop.Reference(2147483647)).value).toBe(2147483647);
        expect(TNSGetOutput()).toBe('2147483647');
    });

    it("functionWithLongPtr", function () {
        expect(functionWithLongPtr(new interop.Reference(2147483647)).value).toBe(2147483647);
        expect(TNSGetOutput()).toBe('2147483647');
    });

    // TODO
    // it("functionWithLongLongPtr", function () {
    //     expect(functionWithLongLongPtr(new interop.Reference(1)).value).toBe(0);
    //     expect(TNSGetOutput()).toBe('1');
    // });

    it("functionWithFloatPtr", function () {
        expect(functionWithFloatPtr(new interop.Reference(3.4028234663852886e+38)).value).toBe(3.4028234663852886e+38);
        expect(TNSGetOutput()).toBe('340282346638528859811704183484516925440.000000000000000000000000000000000000000000000');
    });

    it("functionWithDoublePtr", function () {
        expect(functionWithDoublePtr(new interop.Reference(1.7976931348623157e+308)).value).toBe(1.7976931348623157e+308);
        expect(TNSGetOutput()).toBe('179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368.00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000');
    });

    it("functionWithUInt8ArrayBufferView", function () {
        let array = Uint8Array.from([ 97, 98, 99, 0 ]);
        let actual = functionWithUCharPtr(array);
        expect(actual[0]).toBe(97);
        expect(actual[1]).toBe(98);
        expect(actual[2]).toBe(99);
        expect(actual[3]).toBe(0);
        expect(TNSGetOutput()).toBe("abc");
    });

    it("functionWithUInt8ArrayBuffer", function () {
        let array = Uint8Array.from([ 97, 98, 99, 0 ]).buffer;
        let actual = functionWithUCharPtr(array);
        expect(actual[0]).toBe(97);
        expect(actual[1]).toBe(98);
        expect(actual[2]).toBe(99);
        expect(actual[3]).toBe(0);
        expect(TNSGetOutput()).toBe("abc");
    });

    it("functionWithInt8ArrayBufferView", function () {
        let array = Int8Array.from([ 97, 98, 99, 0 ]);
        let actual = functionWithCharPtr(array);
        expect(actual[0]).toBe(97);
        expect(actual[1]).toBe(98);
        expect(actual[2]).toBe(99);
        expect(actual[3]).toBe(0);
        expect(TNSGetOutput()).toBe("abc");
    });

    it("functionWithInt8ArrayBuffer", function () {
        let array = Int8Array.from([ 97, 98, 99, 0 ]).buffer;
        let actual = functionWithCharPtr(array);
        expect(actual[0]).toBe(97);
        expect(actual[1]).toBe(98);
        expect(actual[2]).toBe(99);
        expect(actual[3]).toBe(0);
        expect(TNSGetOutput()).toBe("abc");
    });

    it("functionWithUInt16ArrayBufferView", function () {
        let array = Uint16Array.from([ 65535, 1, 2 ]);
        let actual = functionWithUShortPtr(array);
        expect(actual[0]).toBe(65535);
        expect(actual[1]).toBe(1);
        expect(actual[2]).toBe(2);
        expect(TNSGetOutput()).toBe("65535");
    });

    it("functionWithUInt16ArrayBuffer", function () {
        let array = Uint16Array.from([ 65535, 1, 2 ]).buffer;
        let actual = functionWithUShortPtr(array);
        expect(actual[0]).toBe(65535);
        expect(actual[1]).toBe(1);
        expect(actual[2]).toBe(2);
        expect(TNSGetOutput()).toBe("65535");
    });

    it("functionWithInt16ArrayBufferView", function () {
        let array = Int16Array.from([ 32767, 1, 2 ]);
        let actual = functionWithShortPtr(array);
        expect(actual[0]).toBe(32767);
        expect(actual[1]).toBe(1);
        expect(actual[2]).toBe(2);
        expect(TNSGetOutput()).toBe("32767");
    });

    it("functionWithInt16ArrayBuffer", function () {
        let array = Int16Array.from([ 32767, 1, 2 ]).buffer;
        let actual = functionWithShortPtr(array);
        expect(actual[0]).toBe(32767);
        expect(actual[1]).toBe(1);
        expect(actual[2]).toBe(2);
        expect(TNSGetOutput()).toBe("32767");
    });

    it("functionWithUInt32ArrayBufferView", function () {
        let array = Uint32Array.from([ 4294967295, 1, 2 ]);
        let actual = functionWithUIntPtr(array);
        expect(actual[0]).toBe(4294967295);
        expect(actual[1]).toBe(1);
        expect(actual[2]).toBe(2);
        expect(TNSGetOutput()).toBe("4294967295");
    });

    it("functionWithUInt32ArrayBuffer", function () {
        let array = Uint32Array.from([ 4294967295, 1, 2 ]).buffer;
        let actual = functionWithUIntPtr(array);
        expect(actual[0]).toBe(4294967295);
        expect(actual[1]).toBe(1);
        expect(actual[2]).toBe(2);
        expect(TNSGetOutput()).toBe("4294967295");
    });

    it("functionWithInt32ArrayBufferView", function () {
        let array = Int32Array.from([ 2147483647, 1, 2 ]);
        let actual = functionWithIntPtr(array);
        expect(actual[0]).toBe(2147483647);
        expect(actual[1]).toBe(1);
        expect(actual[2]).toBe(2);
        expect(TNSGetOutput()).toBe("2147483647");
    });

    it("functionWithInt32ArrayBuffer", function () {
        let array = Int32Array.from([ 2147483647, 1, 2 ]);
        let actual = functionWithIntPtr(array);
        expect(actual[0]).toBe(2147483647);
        expect(actual[1]).toBe(1);
        expect(actual[2]).toBe(2);
        expect(TNSGetOutput()).toBe("2147483647");
    });

    it("functionWithUInt64ArrayBufferView", function () {
        let array = BigUint64Array.from([ BigInt("18446744073709551615"), BigInt("1"), BigInt("2") ]);
        let actual = functionWithULongLongPtr(array);
        expect(actual[0]).toBe(BigInt("18446744073709551615"));
        expect(actual[1]).toBe(1);
        expect(actual[2]).toBe(2);
        expect(TNSGetOutput()).toBe("18446744073709551615");
    });

    it("functionWithUInt64ArrayBuffer", function () {
        let array = BigUint64Array.from([ BigInt("18446744073709551615"), BigInt("1"), BigInt("2") ]).buffer;
        let actual = functionWithULongLongPtr(array);
        expect(actual[0]).toBe(BigInt("18446744073709551615"));
        expect(actual[1]).toBe(1);
        expect(actual[2]).toBe(2);
        expect(TNSGetOutput()).toBe("18446744073709551615");
    });

    it("functionWithInt64ArrayBufferView", function () {
        let array = BigInt64Array.from([ BigInt("9223372036854775807"), BigInt("-9223372036854775808"), BigInt("3") ]);
        let actual = functionWithLongLongPtr(array);
        expect(actual[0]).toBe(BigInt("9223372036854775807"));
        expect(actual[1]).toBe(BigInt("-9223372036854775808"));
        expect(actual[2]).toBe(3);
        expect(TNSGetOutput()).toBe("9223372036854775807");
    });

    it("functionWithInt64ArrayBuffer", function () {
        let array = BigInt64Array.from([ BigInt("9223372036854775807"), BigInt("-9223372036854775808"), BigInt("3") ]).buffer;
        let actual = functionWithLongLongPtr(array);
        expect(actual[0]).toBe(BigInt("9223372036854775807"));
        expect(actual[1]).toBe(BigInt("-9223372036854775808"));
        expect(actual[2]).toBe(3);
        expect(TNSGetOutput()).toBe("9223372036854775807");
    });

    it("functionWithFloat32ArrayBufferView", function () {
        let array = Float32Array.from([ -3.4028234663852886e+38, 3.4028234663852886e+38, 1.1 ]);
        let actual = functionWithFloatPtr(array);
        expect(actual[0]).toBe(-3.4028234663852886e+38);
        expect(actual[1]).toBe(3.4028234663852886e+38);
        expect(actual[2]).toBeCloseTo(1.1, 5);
        expect(TNSGetOutput()).toBe("-340282346638528859811704183484516925440.000000000000000000000000000000000000000000000");
    });

    it("functionWithFloat32ArrayBuffer", function () {
        let array = Float32Array.from([ -3.4028234663852886e+38, 3.4028234663852886e+38, 1.1 ]).buffer;
        let actual = functionWithFloatPtr(array);
        expect(actual[0]).toBe(-3.4028234663852886e+38);
        expect(actual[1]).toBe(3.4028234663852886e+38);
        expect(actual[2]).toBeCloseTo(1.1, 5);
        expect(TNSGetOutput()).toBe("-340282346638528859811704183484516925440.000000000000000000000000000000000000000000000");
    });

    it("functionWithFloat64ArrayBufferView", function () {
        let array = Float64Array.from([ -Number.MAX_VALUE, Number.MAX_VALUE, 1.1 ]);
        let actual = functionWithDoublePtr(array);
        expect(actual[0]).toBe(-Number.MAX_VALUE);
        expect(actual[1]).toBe(Number.MAX_VALUE);
        expect(actual[2]).toBeCloseTo(1.1, 5);
        expect(TNSGetOutput()).toBe("-179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368.0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000");
    });

    it("functionWithFloat64ArrayBuffer", function () {
        let array = Float64Array.from([ -Number.MAX_VALUE, Number.MAX_VALUE, 1.1 ]).buffer;
        let actual = functionWithDoublePtr(array);
        expect(actual[0]).toBe(-Number.MAX_VALUE);
        expect(actual[1]).toBe(Number.MAX_VALUE);
        expect(actual[2]).toBeCloseTo(1.1, 5);
        expect(TNSGetOutput()).toBe("-179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368.0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000");
    });

    it("functionWithStructPtr", function () {
        var struct = new TNSNestedStruct({a: {x: 1, y: 2}, b: {x: 3, y: 4}});
        expect(TNSNestedStruct.equals(functionWithStructPtr(new interop.Reference(struct)).value, struct)).toBe(true);
        expect(TNSGetOutput()).toBe('1 2 3 4');
    });

    it("functionWithOutStructPtr", function () {
        var strRef = new interop.Reference();
        functionWithOutStructPtr(strRef);
        expect(TNSSimpleStruct.equals(strRef.value, {x: 2, y: 3}));
    });

    it("CString marshalling from JS string", function () {
        functionWithUCharPtr('test');
        expect(TNSGetOutput()).toBe('test');
    });

    it("CString as arg/return value", function () {
        const str = "test";
        const ptr = interop.alloc((str.length + 1) * interop.sizeof(interop.types.uint8));
        var reference = new interop.Reference(interop.types.uint8, ptr);
        for (ii in str) {
            const i = parseInt(ii);
            reference[i] = str.charCodeAt(i);
        }
        reference[str.length] = 0;

        const result = functionWithCharPtr(ptr);

        expect(TNSGetOutput()).toBe(str);
        expect(interop.handleof(result).toNumber() == interop.handleof(ptr).toNumber());
        expect(NSString.stringWithUTF8String(result).toString()).toBe(str);
        interop.free(ptr);
    });

    it("interops string from CString", function () {
        const str = "test";
        const ptr = interop.alloc((str.length + 1) * interop.sizeof(interop.types.uint8));
        var reference = new interop.Reference(interop.types.uint8, ptr);
        for (ii in str) {
            const i = parseInt(ii);
            reference[i] = str.charCodeAt(i);
        }
        reference[str.length] = 0;
        expect(interop.stringFromCString(ptr)).toBe(str);
        expect(interop.stringFromCString(reference)).toBe(str);
        interop.free(ptr);
    });

    it("Struct reference with value", function () {
        const value = new TNSSimpleStruct({x: 1, y: 2});
        const ref = new interop.Reference(TNSSimpleStruct, value);

        expect(TNSSimpleStruct.equals(ref.value, value)).toBe(true);
    });

    it("Struct reference with pointer and indexed values", function () {
        const structs = [
            new TNSSimpleStruct({x: 1, y: 2}),
            new TNSSimpleStruct({x: 3, y: 4}),
            new TNSSimpleStruct({x: 5, y: 6})
        ];
        const length = structs.length;
        const ptr = interop.alloc(interop.sizeof(TNSSimpleStruct) * length);

        const ref = new interop.Reference(TNSSimpleStruct, ptr);
        for (let i = 0; i < length; i++) {
            ref[i] = structs[i];
        }

        // Check if values were stored into pointer
        const resultRef = new interop.Reference(TNSSimpleStruct, ptr);
        for (let i = 0; i < length; i++) {
            expect(TNSSimpleStruct.equals(resultRef[i], structs[i])).toBe(true);
        }

        interop.free(ptr);
    });

    it("Struct reference get first value as referred value", function () {
        const structs = [
            new TNSSimpleStruct({x: 1, y: 2}),
            new TNSSimpleStruct({x: 3, y: 4}),
            new TNSSimpleStruct({x: 5, y: 6})
        ];
        const length = structs.length;
        const ptr = interop.alloc(interop.sizeof(TNSSimpleStruct) * length);

        const ref = new interop.Reference(TNSSimpleStruct, ptr);
        for (let i = 0; i < length; i++) {
            ref[i] = structs[i];
        }

        // Check if values were stored into pointer
        const resultRef = new interop.Reference(TNSSimpleStruct, ptr);
        expect(TNSSimpleStruct.equals(resultRef.value, structs[0])).toBe(true);

        interop.free(ptr);
    });

    it("Reference access indexed values from pointer array property", function () {
        const structs = [
            new TNSPoint({x: 1, y: 2}),
            new TNSPoint({x: 3, y: 4}),
            new TNSPoint({x: 5, y: 6})
        ];
        const length = structs.length;
        const ptr = interop.alloc(interop.sizeof(TNSPoint) * length);

        const ref = new interop.Reference(TNSPoint, ptr);
        for (let i = 0; i < length; i++) {
            ref[i] = structs[i];
        }

        const pointCollection = TNSPointCollection.alloc().initWithPointsCount(ptr, length);
        const pointsRef = pointCollection.points;

        // Check if values were retrieved from pointer
        for (let i = 0; i < length; i++) {
            expect(TNSPoint.equals(pointsRef[i], structs[i])).toBe(true);
        }

        interop.free(ptr);
    });

    it("Reference access value from pointer array property", function () {
        const structs = [
            new TNSPoint({x: 1, y: 2}),
            new TNSPoint({x: 3, y: 4}),
            new TNSPoint({x: 5, y: 6})
        ];
        const length = structs.length;
        const ptr = interop.alloc(interop.sizeof(TNSPoint) * length);

        const ref = new interop.Reference(TNSPoint, ptr);
        for (let i = 0; i < length; i++) {
            ref[i] = structs[i];
        }

        const pointCollection = TNSPointCollection.alloc().initWithPointsCount(ptr, length);
        const pointsRef = pointCollection.points;

        expect(TNSPoint.equals(pointsRef.value, structs[0])).toBe(true);

        interop.free(ptr);
    });

    it("interops string from CString with fixed length", function () {
        const str = "te\0st";
        const ptr = interop.alloc((str.length + 1) * interop.sizeof(interop.types.uint8));
        var reference = new interop.Reference(interop.types.uint8, ptr);
        for (ii in str) {
            const i = parseInt(ii);
            reference[i] = str.charCodeAt(i);
        }
        reference[str.length] = 0;
        // no length means it will go until it finds \0
        expect(interop.stringFromCString(ptr)).toBe('te');
        expect(interop.stringFromCString(ptr, 1)).toBe('t');
        expect(interop.stringFromCString(ptr, str.length)).toBe(str);
        expect(interop.stringFromCString(reference, str.length)).toBe(str);
        interop.free(ptr);
    });

    it("CString should be passed as its UTF8 encoding and returned as a reference to unsigned characters", function () {
        const str = "test АБВГ";
        const result = functionWithUCharPtr(str);

        expect(TNSGetOutput()).toBe(str);

        const strUtf8 = utf8.encode(str);
        for (i in strUtf8) {
            const actual = strUtf8.charCodeAt(i);
            const expected = result[i];
            expect(actual).toBe(expected, `Char code difference at index ${i} ("${actual}" vs "${expected}")`);
        }
    });

    // TODO: Create array type and constructor
    it("IncompleteCArrayParameter", function () {
        var handle = interop.alloc(4 * interop.sizeof(interop.types.int32));
        var reference = new interop.Reference(interop.types.int32, handle);
        expect(interop.handleof(reference)).toBe(handle);

        reference[0] = 1;
        reference[1] = 2;
        reference[2] = 3;
        reference[3] = 0;

        functionWithIntIncompleteArray(reference);
        expect(TNSGetOutput()).toBe('123');
    });

    it("ConstantArrayAssignment", function () {
        var s1 = getSimpleStruct();
        var s2 = getSimpleStruct();

        s1.y1 = s2.y1;
        s1.y1 = undefined;
        expect(s1.y1[0].x2).toBe(0);
        expect(s1.y1[1].x2).toBe(0);
        s1.y1 = s2.y1;
        expect(s1.y1[0].x2).toBe(10);
        expect(s1.y1[1].x2).toBe(30);
    });

    it("ConstantCArrayParameterShort", function () {
        var handle = interop.alloc(5 * interop.sizeof(interop.types.int16));
        var reference = new interop.Reference(interop.types.int16, handle);
        reference[0] = 1;
        reference[1] = 2;
        reference[2] = 3;
        reference[3] = 4;
        reference[4] = 5;

        functionWithShortConstantArray(reference);
        expect(TNSGetOutput()).toBe('12345');
    });

    it("ConstantCArrayParameterInt", function () {
        var handle = interop.alloc(5 * interop.sizeof(interop.types.int32));
        var reference = new interop.Reference(interop.types.int32, handle);
        reference[0] = 1;
        reference[1] = 2;
        reference[2] = 3;
        reference[3] = 4;
        reference[4] = 5;

        functionWithIntConstantArray(reference);
        expect(TNSGetOutput()).toBe('12345');
    });

    it("ConstantCArrayParameterLong", function () {
        var handle = interop.alloc(5 * interop.sizeof(interop.types.int64));
        var reference = new interop.Reference(interop.types.int64, handle);
        reference[0] = 1;
        reference[1] = 2;
        reference[2] = 3;
        reference[3] = 4;
        reference[4] = 5;

        functionWithLongConstantArray(reference);
        expect(TNSGetOutput()).toBe('12345');
    });

    it("ConstantCArrayParameter2", function () {
        var handle = interop.alloc(4 * interop.sizeof(interop.types.int32));
        var reference = new interop.Reference(interop.types.int32, handle);
        reference[0] = 1;
        reference[1] = 2;
        reference[2] = 3;
        reference[3] = 4;

        functionWithIntConstantArray2(reference);
        expect(TNSGetOutput()).toBe('1234');
    });

    it("NSArrayWithObjects", function () {
        var handle = interop.alloc(4 * interop.sizeof(interop.types.id));
        var reference = new interop.Reference(interop.types.id, handle);
        reference[0] = new NSObject();
        reference[1] = new NSObject();
        reference[2] = new NSObject();
        reference[3] = new NSObject();

        var array = NSArray.arrayWithObjectsCount(reference, 4);
        expect(array.objectAtIndex(0).class()).toBe(NSObject);
        expect(array.objectAtIndex(1).class()).toBe(NSObject);
        expect(array.objectAtIndex(2).class()).toBe(NSObject);
        expect(array.objectAtIndex(3).class()).toBe(NSObject);
    });

    it("SmallArrayBuffer", function () {
        var view = new Int32Array([1, 2, 3, 4, 5, 0]);
        functionWithIntIncompleteArray(view);
        expect(TNSGetOutput()).toBe('12345');
        TNSClearOutput();

        functionWithIntIncompleteArray(view.buffer);
        expect(TNSGetOutput()).toBe('12345');
        TNSClearOutput();
    });

    it("LargeArrayBuffer", function () {
        var array = new Array(10000);

        for (var i = 0; i < array.length; i++) {
            array[i] = i + 1;
        }

        var expected = array.join('');

        array.push(0);
        var view = new Int32Array(array);

        functionWithIntIncompleteArray(view);
        expect(TNSGetOutput()).toBe(expected);
        TNSClearOutput();

        functionWithIntIncompleteArray(view.buffer);
        expect(TNSGetOutput()).toBe(expected);
        TNSClearOutput();
    });

    it("CastPointerToNSObject", function () {
        var x = NSObject.alloc().init();
        var y = new NSObject(interop.handleof(x));
        expect(x).toBe(y);
        expect(x.toString()).toBe(y.toString());
        expect(interop.handleof(x)).toBe(interop.handleof(y));
    });

    it("ImplicitPointerToId", function () {
        var array = NSMutableArray.alloc().init();
        var object = new NSObject();
        array.addObject(interop.handleof(object));

        expect(array.firstObject).toBe(object);
    });

    it("NSInvocation_methodWithBool", function () {
        var methodSignature = NSMethodSignature.signatureWithObjCTypes("v@:B");
        var invocation = NSInvocation.invocationWithMethodSignature(methodSignature);
        invocation.selector = "methodWithBool:";
        var ref = new interop.Reference(interop.types.uint8, true);
        invocation.setArgumentAtIndex(ref, 2);
        invocation.invokeWithTarget(TNSPrimitives.class());
        expect(TNSGetOutput()).toBe('1');
    });

    it("NSInvocation_methodWithBool2", function () {
        var methodSignature = NSMethodSignature.signatureWithObjCTypes("v@:B");
        var invocation = NSInvocation.invocationWithMethodSignature(methodSignature);
        invocation.selector = "methodWithBool2:";
        var ref = new interop.Reference(interop.types.uint8, true);
        invocation.setArgumentAtIndex(ref, 2);
        invocation.invokeWithTarget(TNSPrimitives.class());
        expect(TNSGetOutput()).toBe('1');
    });

    it("NSInvocation_methodWithBool3", function () {
        var methodSignature = NSMethodSignature.signatureWithObjCTypes("v@:B");
        var invocation = NSInvocation.invocationWithMethodSignature(methodSignature);
        invocation.selector = "methodWithBool3:";
        var ref = new interop.Reference(interop.types.uint8, true);
        invocation.setArgumentAtIndex(ref, 2);
        invocation.invokeWithTarget(TNSPrimitives.class());
        expect(TNSGetOutput()).toBe('1');
    });

    it("NSInvocation_methodWithUnichar", function () {
        var methodSignature = NSMethodSignature.signatureWithObjCTypes("v@:S");
        var invocation = NSInvocation.invocationWithMethodSignature(methodSignature);
        invocation.selector = "methodWithUnichar:";
        var ref = new interop.Reference(interop.types.unichar, "i");
        invocation.setArgumentAtIndex(ref, 2);
        invocation.invokeWithTarget(TNSPrimitives.class());
        expect(TNSGetOutput()).toBe('i');
    });

    it("NSInvocation_methodWithUChar", function () {
        var methodSignature = NSMethodSignature.signatureWithObjCTypes("v@:C");
        var invocation = NSInvocation.invocationWithMethodSignature(methodSignature);
        invocation.selector = "methodWithUChar:";
        var ref = new interop.Reference(interop.types.uint8, 255);
        invocation.setArgumentAtIndex(ref, 2);
        invocation.invokeWithTarget(TNSPrimitives.class());
        expect(TNSGetOutput()).toBe('255');
    });

    it("NSInvocation_methodWithChar1", function () {
        var methodSignature = NSMethodSignature.signatureWithObjCTypes("v@:c");
        var invocation = NSInvocation.invocationWithMethodSignature(methodSignature);
        invocation.selector = "methodWithChar:";
        var ref = new interop.Reference(interop.types.int8, 127);
        invocation.setArgumentAtIndex(ref, 2);
        invocation.invokeWithTarget(TNSPrimitives.class());
        expect(TNSGetOutput()).toBe('127');
    });

    it("NSInvocation_methodWithChar2", function () {
        var methodSignature = NSMethodSignature.signatureWithObjCTypes("v@:c");
        var invocation = NSInvocation.invocationWithMethodSignature(methodSignature);
        invocation.selector = "methodWithChar:";
        var ref = new interop.Reference(interop.types.int8, -128);
        invocation.setArgumentAtIndex(ref, 2);
        invocation.invokeWithTarget(TNSPrimitives.class());
        expect(TNSGetOutput()).toBe('-128');
    });

    it("NSInvocation_methodWithUShort", function () {
        var methodSignature = NSMethodSignature.signatureWithObjCTypes("v@:S");
        var invocation = NSInvocation.invocationWithMethodSignature(methodSignature);
        invocation.selector = "methodWithUShort:";
        var ref = new interop.Reference(interop.types.uint16, 65535);
        invocation.setArgumentAtIndex(ref, 2);
        invocation.invokeWithTarget(TNSPrimitives.class());
        expect(TNSGetOutput()).toBe('65535');
    });

    it("NSInvocation_methodWithUShort1", function () {
        var methodSignature = NSMethodSignature.signatureWithObjCTypes("v@:s");
        var invocation = NSInvocation.invocationWithMethodSignature(methodSignature);
        invocation.selector = "methodWithShort:";
        var ref = new interop.Reference(interop.types.int16, 32767);
        invocation.setArgumentAtIndex(ref, 2);
        invocation.invokeWithTarget(TNSPrimitives.class());
        expect(TNSGetOutput()).toBe('32767');
    });

    it("NSInvocation_methodWithUShort2", function () {
        var methodSignature = NSMethodSignature.signatureWithObjCTypes("v@:s");
        var invocation = NSInvocation.invocationWithMethodSignature(methodSignature);
        invocation.selector = "methodWithShort:";
        var ref = new interop.Reference(interop.types.int16, -32768);
        invocation.setArgumentAtIndex(ref, 2);
        invocation.invokeWithTarget(TNSPrimitives.class());
        expect(TNSGetOutput()).toBe('-32768');
    });

    it("NSInvocation_methodWithUInt", function () {
        var methodSignature = NSMethodSignature.signatureWithObjCTypes("v@:I");
        var invocation = NSInvocation.invocationWithMethodSignature(methodSignature);
        invocation.selector = "methodWithUInt:";
        var ref = new interop.Reference(interop.types.uint32, 4294967295);
        invocation.setArgumentAtIndex(ref, 2);
        invocation.invokeWithTarget(TNSPrimitives.class());
        expect(TNSGetOutput()).toBe('4294967295');
    });

    it("NSInvocation_methodWithInt1", function () {
        var methodSignature = NSMethodSignature.signatureWithObjCTypes("v@:i");
        var invocation = NSInvocation.invocationWithMethodSignature(methodSignature);
        invocation.selector = "methodWithInt:";
        var ref = new interop.Reference(interop.types.int32, 2147483647);
        invocation.setArgumentAtIndex(ref, 2);
        invocation.invokeWithTarget(TNSPrimitives.class());
        expect(TNSGetOutput()).toBe('2147483647');
    });

    it("NSInvocation_methodWithInt2", function () {
        var methodSignature = NSMethodSignature.signatureWithObjCTypes("v@:i");
        var invocation = NSInvocation.invocationWithMethodSignature(methodSignature);
        invocation.selector = "methodWithInt:";
        var ref = new interop.Reference(interop.types.int32, -2147483648);
        invocation.setArgumentAtIndex(ref, 2);
        invocation.invokeWithTarget(TNSPrimitives.class());
        expect(TNSGetOutput()).toBe('-2147483648');
    });

    it("NSInvocation_methodWithULong", function () {
        var methodSignature = NSMethodSignature.signatureWithObjCTypes("v@:L");
        var invocation = NSInvocation.invocationWithMethodSignature(methodSignature);
        invocation.selector = "methodWithULong:";
        var ref = new interop.Reference(interop.types.uint64, 4294967295);
        invocation.setArgumentAtIndex(ref, 2);
        invocation.invokeWithTarget(TNSPrimitives.class());
        expect(TNSGetOutput()).toBe('4294967295');
    });

    it("NSInvocation_methodWithLong", function () {
        var methodSignature = NSMethodSignature.signatureWithObjCTypes("v@:l");
        var invocation = NSInvocation.invocationWithMethodSignature(methodSignature);
        invocation.selector = "methodWithLong:";
        var ref = new interop.Reference(interop.types.int64, 2147483647);
        invocation.setArgumentAtIndex(ref, 2);
        invocation.invokeWithTarget(TNSPrimitives.class());
        expect(TNSGetOutput()).toBe('2147483647');
    });

    it("NSInvocation_methodWithFloat", function () {
        var methodSignature = NSMethodSignature.signatureWithObjCTypes("v@:f");
        var invocation = NSInvocation.invocationWithMethodSignature(methodSignature);
        invocation.selector = "methodWithFloat:";
        var ref = new interop.Reference(interop.types.float, 3.40282347e+38);
        invocation.setArgumentAtIndex(ref, 2);
        invocation.invokeWithTarget(TNSPrimitives.class());
        expect(TNSGetOutput()).toBe('340282346638528859811704183484516925440.000000000000000000000000000000000000000000000');
    });

    it("NSInvocation_methodWithDouble1", function () {
        var methodSignature = NSMethodSignature.signatureWithObjCTypes("v@:d");
        var invocation = NSInvocation.invocationWithMethodSignature(methodSignature);
        invocation.selector = "methodWithDouble:";
        var ref = new interop.Reference(interop.types.double, 1.7976931348623157e+308);
        invocation.setArgumentAtIndex(ref, 2);
        invocation.invokeWithTarget(TNSPrimitives.class());
        expect(TNSGetOutput()).toBe('179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368.00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000');
    });

    it("NSInvocation_methodWithDouble2", function () {
        var methodSignature = NSMethodSignature.signatureWithObjCTypes("v@:d");
        var invocation = NSInvocation.invocationWithMethodSignature(methodSignature);
        invocation.selector = "methodWithDouble:";
        var ref = new interop.Reference(interop.types.double, 2.2250738585072014e-308);
        invocation.setArgumentAtIndex(ref, 2);
        invocation.invokeWithTarget(TNSPrimitives.class());
        expect(TNSGetOutput()).toBe('0.0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000222507385850720138');
    });

    it("NSInvocation_methodWithSelector", function () {
        var methodSignature = NSMethodSignature.signatureWithObjCTypes("v@::");
        var invocation = NSInvocation.invocationWithMethodSignature(methodSignature);
        invocation.selector = "methodWithSelector:";
        var ref = new interop.Reference(interop.types.selector, "init:");
        invocation.setArgumentAtIndex(ref, 2);
        invocation.invokeWithTarget(TNSPrimitives.class());
        expect(TNSGetOutput()).toBe('init:');
    });

    it("NSInvocation_methodWithClass", function () {
        var methodSignature = NSMethodSignature.signatureWithObjCTypes("v@:#");
        var invocation = NSInvocation.invocationWithMethodSignature(methodSignature);
        invocation.selector = "methodWithClass:";
        var ref = new interop.Reference(interop.types.class, NSMutableString.class());
        invocation.setArgumentAtIndex(ref, 2);
        invocation.invokeWithTarget(TNSPrimitives.class());
        expect(TNSGetOutput()).toBe('NSMutableString');
    });

    it("NSInvocation_methodWithProtocol", function () {
        var methodSignature = NSMethodSignature.signatureWithObjCTypes("v@:@");
        var invocation = NSInvocation.invocationWithMethodSignature(methodSignature);
        invocation.selector = "methodWithProtocol:";
        var ref = new interop.Reference(interop.types.protocol, TNSBaseProtocol1);
        invocation.setArgumentAtIndex(ref, 2);
        invocation.invokeWithTarget(TNSPrimitives.class());
        expect(TNSGetOutput()).toBe('TNSBaseProtocol1');
    });

    it("NSInvocation_methodWithId", function () {
        var methodSignature = NSMethodSignature.signatureWithObjCTypes("v@:@");
        var invocation = NSInvocation.invocationWithMethodSignature(methodSignature);
        invocation.selector = "methodWithId:";
        var value = TNSIBaseInterface.alloc().init();
        var ref = new interop.Reference(interop.types.id, value);
        invocation.setArgumentAtIndex(ref, 2);
        invocation.invokeWithTarget(TNSPrimitives.class());
        expect(TNSGetOutput()).toMatch(/^<TNSIBaseInterface: 0x\w+>$/);
    });

    it("CArray return type marshalling", () => {
        var color = UIColor.alloc().initWithRedGreenBlueAlpha(0.1, 0.2, 0.3, 0.7);
        var components = CGColorGetComponents(color.CGColor);
        expect(components instanceof interop.Reference).toBe(true);
        expect(components[0]).toBe(0.1);
        expect(components[1]).toBe(0.2);
        expect(components[2]).toBe(0.3);
        expect(components[3]).toBe(0.7);
    });

    it("Marshal returned javascript object as NSDictionaries", () => {
        var TSObject = NSObject.extend({
            getData: function () {
                return { a: "abc", b: 123 };
            }
        }, {
            exposedMethods: {
                getData: { returns: NSDictionary },
            }
        });

        var obj = TSObject.new();
        TNSObjCTypes.methodWithObject(obj);

        expect(TNSGetOutput()).toBe("abc 123");
    });

    describe("ReferenceConstructor", function () {
        it("should accept empty arguments", function () {
            var reference = new interop.Reference();

            expect(reference).toEqual(jasmine.any(interop.Reference));
        });

        it("should accept a single value argument", function () {
            var value = "value";

            var reference = new interop.Reference(value);

            expect(reference).toEqual(jasmine.any(interop.Reference));
            expect(reference.value).toBe(value);
        });

        it("should accept a single type argument", function () {
            var reference = new interop.Reference(interop.types.bool);

            expect(reference).toEqual(jasmine.any(interop.Reference));
            expect(interop.handleof(reference)).toEqual(jasmine.any(interop.Pointer));
        });

        it("should accept type and value arguments", function () {
            var value = NSObject.alloc().init();
            var reference = new interop.Reference(NSObject, value);
            var buffer = interop.handleof(reference);

            expect(reference).toEqual(jasmine.any(interop.Reference));
            expect(reference.value).toBe(value);
            expect(buffer).toEqual(jasmine.any(interop.Pointer));
        });

        it("should accept type and pointer arguments", function () {
            var pointer = interop.alloc(1);
            var reference = new interop.Reference(interop.types.bool, pointer);

            expect(reference).toEqual(jasmine.any(interop.Reference));
            expect(interop.handleof(reference)).toBe(pointer);
        });

        it("should accept type and record arguments", function () {
            var record = new CGPoint();
            var reference = new interop.Reference(CGPoint, record);

            expect(reference).toEqual(jasmine.any(interop.Reference));
            expect(interop.handleof(reference)).toBe(interop.handleof(record));
        });

        it("should accept type and pointer-backed reference arguments", function () {
            var ref = new interop.Reference(interop.types.bool);
            var reference = new interop.Reference(interop.types.bool, ref);

            expect(reference).toEqual(jasmine.any(interop.Reference));
            expect(interop.handleof(reference)).toBe(interop.handleof(ref));
        });

        it("should accept type and uninitialized reference arguments", function () {
            var ref = new interop.Reference(123);
            var reference = new interop.Reference(interop.types.int8, ref);

            expect(reference).toEqual(jasmine.any(interop.Reference));
            expect(ref.value).toEqual(reference.value);
        });

        // it("should accept reference type and reference arguments", function () {
        //     var ref = new interop.Reference(interop.types.bool);
        //     var reference = new interop.Reference(new interop.types.ReferenceType(interop.types.bool), ref);

        //     expect(reference).toEqual(jasmine.any(interop.Reference));
        //     expect(interop.handleof(reference.value)).toBe(interop.handleof(ref));
        // });

        it("interop.Reference indexed property accessor", () => {
            let stringToHash = "bla";

            const bytesToAlloc = 32;
            const result = interop.alloc(bytesToAlloc);
            CC_SHA256(interop.handleof(NSString.stringWithString(stringToHash).UTF8String), stringToHash.length, result);
            let buffer = new interop.Reference(interop.types.uint8, result);

            let actual = "";
            for (let i = 0; i < bytesToAlloc; i++) {
                actual += buffer[i].toString(16).padStart(2, "0");
            }

            expect(actual).toBe("4df3c3f68fcc83b27e9d42c90431a72499f17875c81a599b566c9889b9696703");
        });
    });
});
