describe("AOT External Stubs", function () {
    it("should create a Swift AOT object via factory", function () {
        var obj = TNSAOTTestFactory.create();
        expect(obj).not.toBeNull();
        expect(obj instanceof TNSAOTTest).toBe(true);
    });

    it("should return UIEdgeInsets struct for padding property", function () {
        var obj = TNSAOTTestFactory.createWithPadding({top: 1, left: 2, bottom: 3, right: 4});
        var padding = obj.padding;
        expect(padding.top).toBe(1);
        expect(padding.left).toBe(2);
        expect(padding.bottom).toBe(3);
        expect(padding.right).toBe(4);
    });

    it("should return UIEdgeInsets struct for borderThickness property", function () {
        var obj = TNSAOTTestFactory.create();
        var bt = obj.borderThickness;
        expect(bt.top).toBe(0);
        expect(bt.left).toBe(0);
        expect(bt.bottom).toBe(0);
        expect(bt.right).toBe(0);
    });

    it("should return CGRect struct for bounds property", function () {
        var obj = TNSAOTTestFactory.create();
        var b = obj.bounds;
        expect(b.origin.x).toBe(0);
        expect(b.origin.y).toBe(0);
        expect(b.size.width).toBe(0);
        expect(b.size.height).toBe(0);
    });

    it("should return null for nil string property", function () {
        var obj = TNSAOTTestFactory.create();
        expect(obj.title).toBeNull();
    });

    it("should return string for title property", function () {
        var obj = TNSAOTTestFactory.create();
        obj.title = "hello";
        expect(obj.title).toBe("hello");
    });

    it("should return BOOL for enabled property", function () {
        var obj = TNSAOTTestFactory.create();
        expect(obj.enabled).toBe(false);
        obj.enabled = true;
        expect(obj.enabled).toBe(true);
    });

    it("should return double for value property", function () {
        var obj = TNSAOTTestFactory.create();
        expect(obj.value).toBe(0);
        obj.value = 42.5;
        expect(obj.value).toBe(42.5);
    });

    it("should handle addValue method with double arg", function () {
        var obj = TNSAOTTestFactory.create();
        obj.addValue(10);
        obj.addValue(5.5);
        expect(obj.value).toBe(15.5);
    });

    it("should handle stringForKey returning null", function () {
        var obj = TNSAOTTestFactory.create();
        var result = obj.stringForKey("missing");
        expect(result).toBeNull();
    });

    it("should handle stringForKey returning string", function () {
        var obj = TNSAOTTestFactory.create();
        obj.setStoreValueForKey("world", "hello");
        var result = obj.stringForKey("hello");
        expect(result).toBe("world");
    });

    it("should handle objectForKey returning null", function () {
        var obj = TNSAOTTestFactory.create();
        var result = obj.objectForKey("missing");
        expect(result).toBeNull();
    });

    it("should work with struct properties on JS subclass", function () {
        var MySubclass = TNSAOTTest.extend({});
        var obj = MySubclass.alloc().init();
        var padding = obj.padding;
        expect(padding.top).toBe(0);
        expect(padding.left).toBe(0);
        expect(padding.bottom).toBe(0);
        expect(padding.right).toBe(0);
    });

    it("should work with struct properties on JS subclass with custom padding", function () {
        var MySubclass = TNSAOTTest.extend({});
        var obj = MySubclass.alloc().initWithPadding({top: 10, left: 20, bottom: 30, right: 40});
        var padding = obj.padding;
        expect(padding.top).toBe(10);
        expect(padding.left).toBe(20);
        expect(padding.bottom).toBe(30);
        expect(padding.right).toBe(40);
    });
});
