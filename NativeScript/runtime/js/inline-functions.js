const {
    ArrayPrototypeConcat,
    FunctionPrototypeApply,
    ObjectAssign,
    ObjectDefineProperty,
    ObjectGetOwnPropertyDescriptor,
    ObjectKeys,
} = primordials;

function applyNativeClass(target, context, options) {
    if (options.name) {
        // Read back by ClassBuilder::EnsureExtendedClass. Survives minifiers,
        // which mangle the inferred constructor name and with it every
        // name-based native lookup.
        target.ObjCClassName = options.name;
    }

    if (options.protocols && options.protocols.length > 0) {
        target.ObjCProtocols = (target.ObjCProtocols && target.ObjCProtocols instanceof Array ? ArrayPrototypeConcat(target.ObjCProtocols, options.protocols) : ArrayPrototypeConcat([], options.protocols));
    }

    if (options.exposedMethods) {
        // Fresh object: ObjCExposedMethods may be inherited through the static
        // chain, and assigning into it would edit the base class's.
        target.ObjCExposedMethods = ObjectAssign({}, target.ObjCExposedMethods, options.exposedMethods);
    }

    if (options.eager) {
        // Standard decorators run before static field initializers, so a class
        // whose protocols/exposedMethods come from `static` fields would be
        // registered without them. addInitializer defers to after the class is
        // fully defined. Legacy decorators and plain calls already run late.
        if (context && typeof context.addInitializer === 'function') {
            context.addInitializer(function () { __registerNativeClass(this); });
        } else {
            __registerNativeClass(target);
        }
    }

    return target;
}

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

    NativeClass(arg, maybeContext) {
        // Usable three ways, and the shapes are indistinguishable at the call
        // site: `@NativeClass` / `@NativeClass({...})` under either decorator
        // proposal, and the plain call `NativeClass(class X {})`. A standard
        // (TC39) decorator is handed (value, context); a legacy one and a plain
        // call are handed just the class.
        if (typeof arg === 'function') {
            return applyNativeClass(arg, maybeContext, {});
        }
        var options = arg || {};
        return function (target, context) {
            return applyNativeClass(target, context, options);
        }
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
