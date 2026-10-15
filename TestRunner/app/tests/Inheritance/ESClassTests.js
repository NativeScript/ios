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

    it('ESClassInitializerArgsSelectInitializer', function () {
        class ESCtorArgsObject extends TNSCInterface {
            constructor(args) {
                // The user's own keys never pick an initializer; only interop.initializer.args does.
                super({ ...args, [interop.initializer.args]: { primitive: args.x } });
                this.name = args.name;
            }
        }

        var object = new ESCtorArgsObject({ name: 'first', x: 7 });
        expect(object instanceof ESCtorArgsObject).toBe(true);
        expect(object.name).toBe('first');
        expect(TNSGetOutput()).toBe('initWithPrimitive:7 called');
        TNSClearOutput();

        // Keys match as a set, in any order
        class ESCtorTwoArgsObject extends TNSCInterface {
            constructor() {
                super({ [interop.initializer.args]: { andInt: 10, int: 5 } });
            }
        }

        var object2 = new ESCtorTwoArgsObject();
        expect(object2 instanceof ESCtorTwoArgsObject).toBe(true);
        expect(TNSGetOutput()).toBe('initWithInt:andInt: 5 10 called');
        TNSClearOutput();

        // No initializer named: plain [[Class alloc] init]
        class ESCtorNoArgsObject extends TNSCInterface {
        }

        var object3 = new ESCtorNoArgsObject({ unrelated: 1 });
        expect(object3 instanceof ESCtorNoArgsObject).toBe(true);
        expect(TNSGetOutput()).toBe('init called');
        TNSClearOutput();

        // An error-out initializer never exposes its NSError** as a token
        class ESCtorErrorOutObject extends TNSCInterface {
            constructor() {
                super({ [interop.initializer.args]: { parameter1: 'a', parameter2: 'b' } });
            }
        }

        new ESCtorErrorOutObject();
        expect(TNSGetOutput()).toBe('initWithParameter1:parameter2:error: a b called');
        TNSClearOutput();

        // A parameterless initializer is named by its token alone
        class ESCtorEmptyObject extends TNSCInterface {
            constructor() {
                super({ [interop.initializer.args]: { empty: undefined } });
            }
        }

        new ESCtorEmptyObject();
        expect(TNSGetOutput()).toBe('initWithEmpty called');
    });

    it('ESClassSuperArgumentErrors', function () {
        class ESPositionalSuperObject extends TNSCInterface {
            constructor() {
                super(7);
            }
        }

        expect(function () {
            new ESPositionalSuperObject();
        }).toThrowError(/takes no arguments or a single options object/);

        class ESClassInstanceSuperObject extends TNSCInterface {
            constructor(owner) {
                super(owner);
            }
        }

        expect(function () {
            new ESClassInstanceSuperObject(new (class Owner { })());
        }).toThrowError(/takes no arguments or a single options object/);

        // The pre-contract spelling would silently run init instead of initWithPrimitive:
        class ESBareTokensSuperObject extends TNSCInterface {
            constructor() {
                super({ primitive: 7 });
            }
        }

        expect(function () {
            new ESBareTokensSuperObject();
        }).toThrowError(/initWithPrimitive:.*interop\.initializer\.args/);

        class ESUnknownTokensObject extends TNSCInterface {
            constructor() {
                super({ [interop.initializer.args]: { primitve: 7 } });
            }
        }

        expect(function () {
            new ESUnknownTokensObject();
        }).toThrowError(/No initializer of ESUnknownTokensObject takes \{ primitve \}/);

        class ESForgedNativeObject extends TNSCInterface {
            constructor() {
                super({ [interop.initializer.native]: { selector: 'init', args: [] } });
            }
        }

        expect(function () {
            new ESForgedNativeObject();
        }).toThrowError(/belongs to the construction Objective-C started/);
        expect(TNSGetOutput()).toBe('');
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

    it('ESClassAllocInitRunsJsConstructor', function () {
        var constructorRuns = 0;

        class ESAllocCtorObject extends NSObject {
            field = 42;
            #secret = 'private';

            constructor(args) {
                super(args);
                constructorRuns++;
                this.initializedFromJs = true;
            }

            secret() {
                return this.#secret;
            }
        }

        // alloc().init() is an initializer Objective-C sends, like cell reuse, storyboards or
        // NSCoding: the constructor runs inside it, so fields and #private exist on both paths
        var allocated = ESAllocCtorObject.alloc().init();
        expect(constructorRuns).toBe(1);
        expect(allocated.field).toBe(42);
        expect(allocated.secret()).toBe('private');
        expect(allocated.initializedFromJs).toBe(true);
        expect(allocated instanceof ESAllocCtorObject).toBe(true);
        expect(NSStringFromClass(allocated.class())).toBe('ESAllocCtorObject');

        var constructed = new ESAllocCtorObject();
        expect(constructorRuns).toBe(2);
        expect(constructed.field).toBe(42);
        expect(constructed.secret()).toBe('private');
    });

    it('ESClassInitializerOverrideThrows', function () {
        class ESInitOverrideObject extends NSObject {
            init() {
                return super.init();
            }
        }

        // The constructor already runs for every initializer
        expect(function () {
            new ESInitOverrideObject();
        }).toThrowError(/defines init\(\), which overrides the initializer init/);
    });

    it('InteropInitializerSymbols', function () {
        expect(typeof interop.initializer.args).toBe('symbol');
        expect(typeof interop.initializer.native).toBe('symbol');
        expect(interop.initializer.args).not.toBe(Symbol.for('interop.initializer.args'));
        expect(Object.isFrozen(interop.initializer)).toBe(true);
    });

    it('ESClassNativeInitializerReachesConstructor', function () {
        var received = [];
        class ESNativeInitObject extends TNSCInterface {
            label = 'ready';
            constructor(args) {
                super(args);
                received.push(args && args[interop.initializer.native]);
            }
        }

        // The initializer Objective-C sent runs exactly once, with its own arguments
        var object = ESNativeInitObject.alloc().initWithPrimitive(7);
        expect(TNSGetOutput()).toBe('initWithPrimitive:7 called');
        expect(object instanceof ESNativeInitObject).toBe(true);
        expect(object.label).toBe('ready');
        expect(received.length).toBe(1);
        expect(received[0].selector).toBe('initWithPrimitive:');
        expect(received[0].args).toEqual([7]);
        expect(Object.isFrozen(received[0])).toBe(true);
        TNSClearOutput();

        new ESNativeInitObject();
        expect(received[1]).toBeUndefined();
        expect(TNSGetOutput()).toBe('init called');
    });

    it('ESClassNativeInitializerPrefillsTokens', function () {
        var seen;
        class ESPrefillObject extends TNSCInterface {
            constructor(args) {
                seen = args[interop.initializer.args];
                super(args);
            }
        }

        ESPrefillObject.alloc().initWithIntAndInt(1, 2);
        expect(seen).toEqual({ int: 1, andInt: 2 });
        // Frozen: super(...) forwards Objective-C's own arguments, so an edit in place would
        // otherwise be silently dropped
        expect(Object.isFrozen(seen)).toBe(true);
        expect(TNSGetOutput()).toBe('initWithInt:andInt: 1 2 called');
    });

    it('ESClassAllocInitBalancesReferences', function () {
        class ESRefCountObject extends NSObject {
        }

        // The JS instance holds exactly one reference; the one alloc/init returned is balanced
        expect(ESRefCountObject.alloc().init().retainCount()).toBe(1);
        expect(ESRefCountObject.new().retainCount()).toBe(1);
        expect(new ESRefCountObject().retainCount()).toBe(1);
    });

    it('ESClassInitializerRaisingBecomesJsError', function () {
        class ESRaisingObject extends TNSRaisingInitializerObject {
            constructor() {
                super({ [interop.initializer.args]: { raising: undefined } });
            }
        }

        var error;
        try {
            new ESRaisingObject();
        } catch (e) {
            error = e;
        }
        expect(error).toBeDefined();
        expect(error.name).toBe('TNSInitializerException');
        expect(error.message).toBe('initRaising raised');
    });

    it('ESClassDefaultAndForcedInitializer', function () {
        class ESDefaultInitObject extends TNSCInterface {
            constructor(args = {}) {
                super({ [interop.initializer.args]: { primitive: 1 }, ...args });
            }
        }

        new ESDefaultInitObject();
        expect(TNSGetOutput()).toBe('initWithPrimitive:1 called');
        TNSClearOutput();

        // Objective-C chose init; spread order lets its choice win over the class default
        ESDefaultInitObject.alloc().init();
        expect(TNSGetOutput()).toBe('init called');
        TNSClearOutput();

        class ESForcedInitObject extends TNSCInterface {
            constructor(args = {}) {
                super({ ...args, [interop.initializer.args]: { primitive: 2 } });
            }
        }

        // Like -init { return [super initWithPrimitive:2]; }
        var forced = ESForcedInitObject.alloc().init();
        expect(forced instanceof ESForcedInitObject).toBe(true);
        expect(TNSGetOutput()).toBe('initWithPrimitive:2 called');
    });

    it('ESClassMultiLevelConstruction', function () {
        var order = [];
        class ESConstructA extends TNSCInterface {
            a = 'A';
            constructor(args) {
                super(args);
                order.push('A');
            }
        }
        class ESConstructB extends ESConstructA {
            b = 'B';
            constructor(args) {
                super(args);
                order.push('B');
            }
        }

        var viaNew = new ESConstructB();
        var viaNative = ESConstructB.alloc().initWithPrimitive(3);
        expect(order).toEqual(['A', 'B', 'A', 'B']);
        expect(viaNew.a + viaNew.b).toBe('AB');
        expect(viaNative.a + viaNative.b).toBe('AB');
        expect(TNSGetOutput()).toBe('init called' + 'initWithPrimitive:3 called');
    });

    it('ESClassConstructedByObjectiveC', function () {
        var selectors = [];
        class ESObjCConstructed extends TNSDerivedInterface {
            constructor(args) {
                super(args);
                selectors.push(args[interop.initializer.native].selector);
            }
        }

        // [[cls alloc] initBaseMethod] and the rest, sent from Objective-C, which asserts every
        // result isKindOfClass: the class
        TNSTestNativeCallbacks.inheritanceConstructorCalls(ESObjCConstructed);
        expect(selectors).toContain('initBaseMethod');
        expect(selectors).toContain('initBaseProtocolMethod1');
    });

    it('ESClassAdoptedWhenInitializerIsNotInMetadata', function () {
        var constructorArgs;
        class ESPrivatelyCreated extends TNSPrivateInitializerObject {
            field = 'set';
            constructor(args) {
                super(args);
                constructorArgs = args;
            }
        }

        // createPrivately runs -initPrivately, which no hook sees: the constructor runs when the
        // object first reaches JS, here as the factory's return value
        var object = ESPrivatelyCreated.createPrivately();
        expect(TNSGetOutput()).toBe('initPrivately called');
        expect(object instanceof ESPrivatelyCreated).toBe(true);
        expect(object.initializedPrivately).toBe(true);
        expect(object.field).toBe('set');
        expect(constructorArgs[interop.initializer.native].selector).toBeNull();
        expect(constructorArgs[interop.initializer.args]).toBeUndefined();
    });

    it('ESClassConstructorThrowingOnNativePath', function () {
        var previousHook = global.__onUncaughtError;
        var uncaught = [];
        global.__onUncaughtError = function (error) {
            uncaught.push(error);
        };
        try {
            class ESThrowingCtor extends NSObject {
                constructor(args) {
                    super(args);
                    throw new Error('constructor failed');
                }
            }

            // An initializer cannot throw into Objective-C: the error is reported and init
            // answers nil
            expect(ESThrowingCtor.alloc().init()).toBeNull();
            expect(uncaught.length).toBe(1);
            expect(String(uncaught[0] && uncaught[0].message)).toContain('constructor failed');

            expect(function () {
                new ESThrowingCtor();
            }).toThrowError('constructor failed');
        } finally {
            global.__onUncaughtError = previousHook;
        }
    });

    it('ESClassFromLegacyConstructsThroughInitializers', function () {
        var LegacyCtorBase = TNSCInterface.extend({}, { name: 'ESLegacyCtorBase' });
        class ESFromLegacyCtor extends LegacyCtorBase {
            field = 1;
        }

        var object = ESFromLegacyCtor.alloc().initWithPrimitive(4);
        expect(object instanceof ESFromLegacyCtor).toBe(true);
        expect(object.field).toBe(1);
        expect(TNSGetOutput()).toBe('initWithPrimitive:4 called');
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

    it('ESClassMultiLevelMirrorsObjectiveCHierarchy', function () {
        class ESMirrorA extends TNSDerivedInterface {
            baseMethod() {
                TNSLog('A baseMethod called');
                super.baseMethod();
            }
            derivedMethod() {
                TNSLog('A derivedMethod called');
                super.derivedMethod();
            }
        }

        class ESMirrorB extends ESMirrorA {
            baseMethod() {
                TNSLog('B baseMethod called');
                super.baseMethod();
            }
        }

        var b = new ESMirrorB();
        expect(NSStringFromClass(b.class())).toBe('ESMirrorB');
        expect(NSStringFromClass(ESMirrorB.superclass())).toBe('ESMirrorA');
        expect(b.isKindOfClass(ESMirrorA)).toBe(true);
        expect(b.isKindOfClass(TNSDerivedInterface)).toBe(true);

        // Objective-C dispatch reaches each JS level, and every super call lands one level up
        TNSTestNativeCallbacks.inheritanceMethodCalls(b);
        var output = TNSGetOutput();
        expect(output.indexOf('B baseMethod called' +
            'A baseMethod called' +
            'instance baseMethod called')).toBe(0);
        expect(output).toContain('A derivedMethod called' +
            'instance derivedMethod called');
    });

    it('ESClassThreeLevelSuperChain', function () {
        class ESChainA extends TNSDerivedInterface {
            baseMethod() {
                TNSLog('A baseMethod called');
                super.baseMethod();
            }
        }
        class ESChainB extends ESChainA {
        }
        class ESChainC extends ESChainB {
            baseMethod() {
                TNSLog('C baseMethod called');
                super.baseMethod();
            }
        }

        var c = new ESChainC();
        expect(c.isKindOfClass(ESChainB)).toBe(true);
        expect(c.isKindOfClass(ESChainA)).toBe(true);

        c.baseMethod();
        expect(TNSGetOutput()).toBe('C baseMethod called' +
            'A baseMethod called' +
            'instance baseMethod called');
        TNSClearOutput();

        TNSTestNativeCallbacks.inheritanceMethodCalls(c);
        expect(TNSGetOutput().indexOf('C baseMethod called' +
            'A baseMethod called' +
            'instance baseMethod called')).toBe(0);
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

    it('ESClassExtendingLegacyExtendClass', function () {
        var LegacyBase = TNSDerivedInterface.extend({
            baseMethod: function () {
                TNSLog('legacy baseMethod called');
                this.super.baseMethod();
            }
        }, { name: 'ESLegacyBaseForChaining' });

        class ESFromLegacy extends LegacyBase {
            baseMethod() {
                TNSLog('es baseMethod called');
                super.baseMethod();
            }
        }

        var object = new ESFromLegacy();
        expect(object instanceof LegacyBase).toBe(true);
        expect(object.isKindOfClass(LegacyBase)).toBe(true);
        expect(NSStringFromClass(ESFromLegacy.superclass())).toBe('ESLegacyBaseForChaining');

        object.baseMethod();
        expect(TNSGetOutput()).toBe('es baseMethod called' +
            'legacy baseMethod called' +
            'instance baseMethod called');
        TNSClearOutput();

        TNSTestNativeCallbacks.inheritanceMethodCalls(object);
        expect(TNSGetOutput().indexOf('es baseMethod called' +
            'legacy baseMethod called' +
            'instance baseMethod called')).toBe(0);
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
