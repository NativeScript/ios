// Tests for native ES class support: plain `class X extends NativeType {}` without ES5
// downleveling. The Objective-C class is registered lazily by the runtime on first use
// (construction, alloc/new, static dispatch or Class marshalling), or eagerly via
// NativeClass({ eager: true }).
describe(module.id, function () {
    afterEach(function () {
        TNSClearOutput();
    });

    it('ESClassLazyRegistration', function () {
        class ESLazyObject extends NSObject {
        }

        // Defining the class must not register anything with the Objective-C runtime
        expect(NSClassFromString('ESLazyObject')).toBeNull();

        var instance = new ESLazyObject();
        expect(instance instanceof ESLazyObject).toBe(true);

        // First construction registers the class under the ES class name
        expect(NSClassFromString('ESLazyObject')).toBe(ESLazyObject);
    });

    it('ESClassSimpleInheritance', function () {
        class ESSimpleObject extends TNSDerivedInterface {
        }

        var object = new ESSimpleObject();
        expect(object.constructor).toBe(ESSimpleObject);
        expect(object instanceof ESSimpleObject).toBe(true);
        expect(object instanceof TNSDerivedInterface).toBe(true);
        expect(object instanceof NSObject).toBe(true);
        expect(object.class()).toBe(ESSimpleObject);
        expect(object.superclass).toBe(TNSDerivedInterface);
        expect(ESSimpleObject.class()).toBe(ESSimpleObject);
        expect(ESSimpleObject.superclass()).toBe(TNSDerivedInterface);
        expect(NSStringFromClass(ESSimpleObject)).toBe('ESSimpleObject');
    });

    it('ESClassConstructorLogicAndFields', function () {
        class ESConstructorObject extends NSObject {
            field = 42;

            constructor() {
                super();
                this.initialized = true;
            }
        }

        var object = new ESConstructorObject();
        // The receiver created by super() must be the native-backed instance, with class
        // fields and constructor logic applied to it
        expect(object.field).toBe(42);
        expect(object.initialized).toBe(true);
        expect(object instanceof ESConstructorObject).toBe(true);
        expect(object instanceof NSObject).toBe(true);
        expect(NSStringFromClass(object.class())).toBe('ESConstructorObject');
    });

    it('ESClassSuperTokenObjectSelectsInitializer', function () {
        class ESCtorArgsObject extends TNSCInterface {
            constructor(name, x) {
                // The token object names one selector outright. Arguments passed to `new` are
                // only seen by the JS constructor.
                super({ primitive: x });
                this.name = name;
            }
        }

        var object = new ESCtorArgsObject('first', 7);
        expect(object instanceof ESCtorArgsObject).toBe(true);
        expect(object.name).toBe('first');
        expect(TNSGetOutput()).toBe('initWithPrimitive:7 called');
        TNSClearOutput();

        class ESCtorTwoArgsObject extends TNSCInterface {
            constructor(a, b) {
                super({ int: a, andInt: b });
            }
        }

        var object2 = new ESCtorTwoArgsObject(5, 10);
        expect(object2 instanceof ESCtorTwoArgsObject).toBe(true);
        expect(TNSGetOutput()).toBe('initWithInt:andInt: 5 10 called');
        TNSClearOutput();

        // super() with no arguments falls back to plain [[Class alloc] init]
        class ESCtorNoArgsObject extends TNSCInterface {
            constructor() {
                super();
            }
        }

        var object3 = new ESCtorNoArgsObject();
        expect(object3 instanceof ESCtorNoArgsObject).toBe(true);
        expect(TNSGetOutput()).toBe('init called');
    });

    it('ESClassPositionalSuperArgsThrow', function () {
        class ESPositionalSuperObject extends TNSCInterface {
            constructor() {
                super(7);
            }
        }

        // Positional args match on JS value shape, so initWithInt: and initWithPrimitive:
        // are indistinguishable. The token form is the only supported spelling.
        expect(function () {
            new ESPositionalSuperObject();
        }).toThrowError(/initializer-token object/);

        class ESPositionalSuperTwoObject extends TNSCInterface {
            constructor() {
                super(5, 10);
            }
        }

        expect(function () {
            new ESPositionalSuperTwoObject();
        }).toThrowError(/initializer-token object/);
    });

    it('ESClassInstanceMethodsAndSuper', function () {
        class ESMethodsObject extends TNSDerivedInterface {
            baseMethod() {
                TNSLog('js baseMethod called');
                super.baseMethod();
            }
            derivedMethod() {
                TNSLog('js derivedMethod called');
                super.derivedMethod();
            }
        }

        var object = new ESMethodsObject();
        object.baseMethod();
        object.derivedMethod();
        expect(TNSGetOutput()).toBe('js baseMethod called' +
            'instance baseMethod called' +
            'js derivedMethod called' +
            'instance derivedMethod called');
    });

    it('ESClassPropertyAccessorsAndSuper', function () {
        class ESPropertyObject extends TNSDerivedInterface {
            get baseProperty() {
                TNSLog('js getBaseProperty called');
                return super.baseProperty;
            }
            set baseProperty(x) {
                TNSLog('js setBaseProperty called');
                super.baseProperty = x;
            }
        }

        var object = new ESPropertyObject();
        object.baseProperty = 0;
        UNUSED(object.baseProperty);
        expect(TNSGetOutput()).toBe('js setBaseProperty called' +
            'instance setBaseProperty: called' +
            'js getBaseProperty called' +
            'instance baseProperty called');
    });

    it('ESClassAllocInitBeforeConstruction', function () {
        class ESAllocObject extends NSObject {
            getAnswer() {
                return 42;
            }
        }

        // alloc().init() without ever calling `new` must register and use the derived class
        var object = ESAllocObject.alloc().init();
        expect(object instanceof ESAllocObject).toBe(true);
        expect(object.getAnswer()).toBe(42);
        expect(NSStringFromClass(object.class())).toBe('ESAllocObject');
    });

    it('ESClassAllocInitDoesNotRunJsConstructor', function () {
        var constructorRuns = 0;

        class ESAllocNoCtorObject extends NSObject {
            field = 42;

            constructor() {
                super();
                constructorRuns++;
                this.initializedFromJs = true;
            }
        }

        // Objects Objective-C allocates - alloc/init here, but equally cell reuse,
        // storyboards or NSCoding - are handed to JS as a bare object with the class
        // prototype grafted on. They never run [[Construct]], so class fields and the
        // constructor body are absent. Override init() (below) to run on both paths.
        var allocated = ESAllocNoCtorObject.alloc().init();
        expect(constructorRuns).toBe(0);
        expect(allocated.field).toBe(undefined);
        expect(allocated.initializedFromJs).toBe(undefined);
        expect(allocated instanceof ESAllocNoCtorObject).toBe(true);
        expect(NSStringFromClass(allocated.class())).toBe('ESAllocNoCtorObject');

        var constructed = new ESAllocNoCtorObject();
        expect(constructorRuns).toBe(1);
        expect(constructed.field).toBe(42);
        expect(constructed.initializedFromJs).toBe(true);
    });

    it('ESClassInitOverrideRunsOnNativeAllocation', function () {
        class ESInitOverrideObject extends NSObject {
            init() {
                var self = super.init();
                self.readyFromInit = true;
                return self;
            }
        }

        // init() is the one construction hook both paths share
        var allocated = ESInitOverrideObject.alloc().init();
        expect(allocated.readyFromInit).toBe(true);
        expect(allocated instanceof ESInitOverrideObject).toBe(true);

        var constructed = new ESInitOverrideObject();
        expect(constructed.readyFromInit).toBe(true);
        expect(constructed instanceof ESInitOverrideObject).toBe(true);
    });

    it('ESClassNewBeforeConstruction', function () {
        class ESNewObject extends NSObject {
        }

        var object = ESNewObject.new();
        expect(object instanceof ESNewObject).toBe(true);
        expect(NSStringFromClass(object.class())).toBe('ESNewObject');
    });

    it('ESClassStaticMethodDispatch', function () {
        class ESStaticMethodObject extends TNSDerivedInterface {
        }

        ESStaticMethodObject.baseMethod();
        ESStaticMethodObject.derivedMethod();
        expect(TNSGetOutput()).toBe('static baseMethod called' +
            'static derivedMethod called');
    });

    it('ESClassStaticPropertyDispatch', function () {
        class ESStaticPropertyObject extends TNSDerivedInterface {
        }

        ESStaticPropertyObject.baseProperty = 1;
        UNUSED(ESStaticPropertyObject.baseProperty);
        expect(TNSGetOutput()).toBe('static setBaseProperty: called' +
            'static baseProperty called');
    });

    it('ESClassPassedAsClassArgument', function () {
        class ESClassArgObject extends NSObject {
        }

        // Passing the class to a native API before any instance exists must register it
        expect(NSStringFromClass(ESClassArgObject)).toBe('ESClassArgObject');

        var object = new ESClassArgObject();
        expect(object.isKindOfClass(ESClassArgObject)).toBe(true);
        expect(object.isMemberOfClass(ESClassArgObject)).toBe(true);
        expect(object.isKindOfClass(NSObject)).toBe(true);
    });

    it('ESClassProtocolImplementation', function () {
        class ESProtocolObject extends NSObject {
            static ObjCProtocols = [TNSBaseProtocol2];

            baseProtocolMethod1() {
                TNSLog('baseProtocolMethod1 called');
            }
            baseProtocolMethod2() {
                TNSLog('baseProtocolMethod2 called');
            }
        }

        var object = ESProtocolObject.alloc().init();
        TNSTestNativeCallbacks.protocolImplementationProtocolInheritance(object);
        expect(TNSGetOutput()).toBe('baseProtocolMethod1 called' +
            'baseProtocolMethod2 called');
    });

    it('ESClassExposedMethods', function () {
        class ESExposedObject extends NSObject {
            static ObjCExposedMethods = {
                'voidSelector': { returns: interop.types.void },
                'variadicSelector:x:': { returns: NSObject, params: [NSString, interop.types.int32] }
            };

            voidSelector() {
                TNSLog('voidSelector called');
            }
            ['variadicSelector:x:'](a, b) {
                TNSLog('variadicSelector:' + a + ' x:' + b + ' called');
                return a;
            }
        }

        var object = new ESExposedObject();
        TNSTestNativeCallbacks.inheritanceVoidSelector(object);
        expect(TNSTestNativeCallbacks.inheritanceVariadicSelector(object)).toBe('native');
        expect(TNSGetOutput()).toBe('voidSelector called' +
            'variadicSelector:native x:9 called');
    });

    it('ESClassDescriptionOverrideFromNative', function () {
        class ESDescriptionObject extends NSObject {
            get description() {
                return 'js description';
            }
        }

        // Throws (native assert) if [object description] does not dispatch to the JS getter
        TNSTestNativeCallbacks.apiDescriptionOverride(new ESDescriptionObject());
    });

    it('ESClassMultiLevelInheritance', function () {
        class ESLevelA extends TNSDerivedInterface {
            baseMethod() {
                TNSLog('A baseMethod called');
                super.baseMethod();
            }
            derivedMethod() {
                TNSLog('A derivedMethod called');
                super.derivedMethod();
            }
        }

        class ESLevelB extends ESLevelA {
            baseMethod() {
                TNSLog('B baseMethod called');
                super.baseMethod();
            }
        }

        var b = new ESLevelB();
        expect(b instanceof ESLevelB).toBe(true);
        expect(b instanceof ESLevelA).toBe(true);
        expect(b instanceof TNSDerivedInterface).toBe(true);

        b.baseMethod();
        b.derivedMethod();
        expect(TNSGetOutput()).toBe('B baseMethod called' +
            'A baseMethod called' +
            'instance baseMethod called' +
            'A derivedMethod called' +
            'instance derivedMethod called');
        TNSClearOutput();

        // The intermediate class works standalone too, with its own registration
        var a = new ESLevelA();
        expect(a instanceof ESLevelA).toBe(true);
        expect(a instanceof ESLevelB).toBe(false);
        a.baseMethod();
        expect(TNSGetOutput()).toBe('A baseMethod called' +
            'instance baseMethod called');
    });

    it('ESClassPlainJsSubclassUnaffected', function () {
        class PlainBase {
        }
        class PlainDerived extends PlainBase {
        }

        // Classes with no native type in their prototype chain stay plain JS
        var object = new PlainDerived();
        expect(object instanceof PlainDerived).toBe(true);
        expect(object instanceof PlainBase).toBe(true);
    });

    it('ESClassExtendingLegacyExtendClassThrows', function () {
        var LegacyBase = NSObject.extend({
            legacyMethod: function () {
                TNSLog('legacyMethod called');
            }
        }, { name: 'ESLegacyBaseForChaining' });

        class ESFromLegacy extends LegacyBase {
            legacyMethod() {
                TNSLog('overridden');
            }
        }

        // Falling back to the parent's class would register nothing and silently dispatch
        // this class's overrides to the parent's implementations
        expect(function () {
            new ESFromLegacy();
        }).toThrowError(/legacy \.extend\(\) API/);
    });

    it('NativeClassPlainCallForm', function () {
        expect(typeof global.NativeClass).toBe('function');

        const ESDecoratedPlain = NativeClass(class ESDecoratedPlainObject extends NSObject {
        });
        var instance = new ESDecoratedPlain();
        expect(instance instanceof ESDecoratedPlain).toBe(true);
        expect(NSStringFromClass(instance.class())).toBe('ESDecoratedPlainObject');
    });

    it('NativeClassProtocolsOption', function () {
        const ESDecoratedProtocols = NativeClass({ protocols: [TNSBaseProtocol2] })(
            class ESDecoratedProtocolsObject extends NSObject {
                baseProtocolMethod1() {
                    TNSLog('baseProtocolMethod1 called');
                }
                baseProtocolMethod2() {
                    TNSLog('baseProtocolMethod2 called');
                }
            }
        );

        var object = new ESDecoratedProtocols();
        TNSTestNativeCallbacks.protocolImplementationProtocolInheritance(object);
        expect(TNSGetOutput()).toBe('baseProtocolMethod1 called' +
            'baseProtocolMethod2 called');
    });

    it('NativeClassExposedMethodsOption', function () {
        const ESDecoratedExposed = NativeClass({
            exposedMethods: {
                'voidSelector': { returns: interop.types.void }
            }
        })(class ESDecoratedExposedObject extends NSObject {
            voidSelector() {
                TNSLog('voidSelector called');
            }
        });

        var object = new ESDecoratedExposed();
        TNSTestNativeCallbacks.inheritanceVoidSelector(object);
        expect(TNSGetOutput()).toBe('voidSelector called');
    });

    it('NativeClassNameOption', function () {
        // An explicit name survives minification, which mangles the inferred ctor name
        const ESRenamed = NativeClass({ name: 'ESExplicitlyNamedObject' })(
            class WouldBeMangled extends NSObject {
            }
        );

        var object = new ESRenamed();
        expect(NSStringFromClass(object.class())).toBe('ESExplicitlyNamedObject');
        expect(NSClassFromString('ESExplicitlyNamedObject')).toBe(ESRenamed);
    });

    it('NativeClassEagerOption', function () {
        const ESEager = NativeClass({ eager: true, name: 'ESEagerlyRegistered' })(
            class ESEagerSource extends NSObject {
            }
        );

        // Registered at definition time, with no instance and no other native touch,
        // so name-based native lookup (storyboards, NSClassFromString) resolves it
        expect(NSClassFromString('ESEagerlyRegistered')).toBe(ESEager);
    });

    it('NativeClassLegacyDecoratorEmit', function () {
        // What TypeScript emits for `@NativeClass({...})` with experimentalDecorators
        class ESLegacyDecorated extends NSObject {
            baseProtocolMethod1() {
                TNSLog('baseProtocolMethod1 called');
            }
            baseProtocolMethod2() {
                TNSLog('baseProtocolMethod2 called');
            }
        }
        var Decorated = __decorate([NativeClass({ protocols: [TNSBaseProtocol2] })], ESLegacyDecorated);

        var object = new Decorated();
        TNSTestNativeCallbacks.protocolImplementationProtocolInheritance(object);
        expect(TNSGetOutput()).toBe('baseProtocolMethod1 called' +
            'baseProtocolMethod2 called');
    });

    it('NativeClassStandardDecoratorEmit', function () {
        // What a TC39 class decorator is handed: (value, context). Class decorators run
        // before static field initializers, so eager registration defers via addInitializer.
        var initializers = [];
        var context = {
            kind: 'class',
            name: 'ESStandardDecorated',
            addInitializer: function (fn) { initializers.push(fn); }
        };

        class ESStandardDecorated extends NSObject {
        }

        var result = NativeClass({ eager: true, name: 'ESStandardDecoratedNamed' })(
            ESStandardDecorated, context);
        expect(result).toBe(ESStandardDecorated);

        // Deferred, not run yet
        expect(initializers.length).toBe(1);
        expect(NSClassFromString('ESStandardDecoratedNamed')).toBeNull();

        initializers[0].call(ESStandardDecorated);
        expect(NSClassFromString('ESStandardDecoratedNamed')).toBe(ESStandardDecorated);
    });
});
