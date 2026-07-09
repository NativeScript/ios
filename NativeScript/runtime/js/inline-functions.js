const {
    ArrayPrototypeConcat,
    ArrayPrototypeSlice,
    FunctionPrototypeApply,
    ObjectAssign,
    ObjectDefineProperty,
    ObjectGetOwnPropertyDescriptor,
    ObjectKeys,
} = primordials;

ObjectAssign(global, {
    CGPointMake(x, y) {
        return new CGPoint({ x, y });
    },
    CGRectMake(x, y, width, height) {
        return new CGRect({ origin: { x, y }, size: { width, height } });
    },
    CGSizeMake(width, height) {
        return new CGSize({ width, height });
    },
    UIEdgeInsetsMake(top, left, bottom, right) {
        return new UIEdgeInsets({ top, left, bottom, right });
    },
    NSMakeRange(location, length) {
        return new NSRange({ location, length });
    },

    __decorate(decorators, target, key, desc) {
        var c = arguments.length, r = c < 3 ? target : desc === null ? desc = ObjectGetOwnPropertyDescriptor(target, key) : desc, d;
        if (typeof Reflect === "object" && typeof Reflect.decorate === "function") r = Reflect.decorate(decorators, target, key, desc);
        else for (var i = decorators.length - 1; i >= 0; i--) if (d = decorators[i]) r = (c < 3 ? d(r) : c > 3 ? d(target, key, r) : d(target, key)) || r;
        return c > 3 && r && ObjectDefineProperty(target, key, r), r;
    },
    __param(paramIndex, decorator) {
        return function (target, key) { decorator(target, key, paramIndex); }
    },

    ObjCClass() {
        // Index loop, not ArrayFrom/spread: this runs at class-definition
        // time, when user code could already have tampered the array
        // iterator protocol.
        var protocols = [];
        for (var pi = 0; pi < arguments.length; pi++) {
            protocols[pi] = arguments[pi];
        }
        return function (target) {
            if (protocols.length > 0) {
                target.ObjCProtocols = (target.ObjCProtocols && target.ObjCProtocols instanceof Array ? ArrayPrototypeConcat(target.ObjCProtocols, protocols) : protocols);
            }
        }
    },
    NativeClass(arg) {
        // Bare `@NativeClass` on a plain ES class: the class needs no
        // transformation — the runtime registers its Objective-C subclass
        // lazily on first native use (ClassBuilder::EnsureExtendedClass).
        if (typeof arg === 'function') {
            return arg;
        }
        // `@NativeClass({ protocols: [...] })`: record protocols for the
        // lazy registration, then hand the class back unchanged.
        var options = arg || {};
        return function (target) {
            if (options.protocols && options.protocols.length > 0) {
                target.ObjCProtocols = (target.ObjCProtocols && target.ObjCProtocols instanceof Array ? ArrayPrototypeConcat(target.ObjCProtocols, options.protocols) : ArrayPrototypeSlice(options.protocols, 0));
            }
            return target;
        }
    },
    ObjCMethod() {
        var name = arguments[0];
        var hasName = (name !== undefined && typeof name === "string");
        var returnType = (hasName ? arguments[1] : arguments[0]);

        return function (target, propertyKey, descriptor) {
            if (!target.constructor.ObjCExposedMethods) {
                target.constructor.ObjCExposedMethods = {};
            }
            if (!target.constructor.ObjCExposedMethods[propertyKey]) {
                target.constructor.ObjCExposedMethods[propertyKey] = {};
            }
            target.constructor.ObjCExposedMethods[propertyKey].returns = returnType || interop.types.void;

            if (hasName && name !== propertyKey) {
                target.constructor.ObjCExposedMethods[name] = target.constructor.ObjCExposedMethods[propertyKey];
                delete target.constructor.ObjCExposedMethods[propertyKey];

                target[name] = function () { 
                    return FunctionPrototypeApply(this[propertyKey], this, arguments);
                }
            }
        }
    },
    ObjC() {
        var args = [];
        for (var ai = 0; ai < arguments.length; ai++) {
            args[ai] = arguments[ai];
        }

        return function (target, propertyKey, descriptor) {
            if (propertyKey === undefined) {
                return FunctionPrototypeApply(ObjCClass, this, args)(target);
            }

            FunctionPrototypeApply(ObjCMethod, this, args)(target, propertyKey, descriptor);
        };
    },
    ObjCParam(type) {
        return function (target, propertyKey, parameterIndex) {
            if (!target.constructor.ObjCExposedMethods) {
                target.constructor.ObjCExposedMethods = {};
            }
            if (!target.constructor.ObjCExposedMethods[propertyKey]) {
                target.constructor.ObjCExposedMethods[propertyKey] = {};
            }
            var exposedMethod = target.constructor.ObjCExposedMethods[propertyKey];
            if (!exposedMethod.params) {
                exposedMethod.params = [];
            }
            exposedMethod.params[parameterIndex] = type || interop.types.void;
        };
    },

});

ObjectDefineProperty(global, "__tsEnum", {
    writable: false,
    enumerable: false,
    configurable: false,
    value: function(obj) {
        var result = {};
        // Index loop, not for...of: enum globals evaluate lazily on first
        // access, after user code could have tampered the array iterator.
        var keys = ObjectKeys(obj);
        for (var i = 0; i < keys.length; i++) {
            var key = keys[i];
            result[key] = obj[key];
            result[obj[key]] = key;
        }
        return result;
    }
});
