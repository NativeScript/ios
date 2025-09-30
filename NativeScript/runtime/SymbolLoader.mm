#include <Foundation/Foundation.h>
#include "SymbolLoader.h"
#include "Helpers.h"
#include <dlfcn.h>
#include <os/log.h>

namespace tns {

// Unified logging: create a dedicated log for the SymbolLoader
static os_log_t ns_symbolloader_log() {
    // Function-local static initialization is thread-safe in C++11+.
    static os_log_t log = os_log_create("@nativescript/ios", "SymbolLoader");
    return log;
}

class SymbolResolver {
public:
    virtual void* loadFunctionSymbol(const char* symbolName) = 0;
    virtual void* loadDataSymbol(const char* symbolName) = 0;
    virtual bool load() = 0;
    virtual ~SymbolResolver() {}
};

class CFBundleSymbolResolver : public SymbolResolver {
public:
    CFBundleSymbolResolver(CFBundleRef bundle) : _bundle(bundle) { }

    virtual void* loadFunctionSymbol(const char* symbolName) override {
        CFStringRef cfName = CFStringCreateWithCStringNoCopy(kCFAllocatorDefault, symbolName, kCFStringEncodingUTF8, kCFAllocatorNull);
        void* functionPointer = CFBundleGetFunctionPointerForName(this->_bundle, cfName);
        CFRelease(cfName);
        return functionPointer;
    }

    virtual void* loadDataSymbol(const char* symbolName) override {
        CFStringRef cfName = CFStringCreateWithCStringNoCopy(kCFAllocatorDefault, symbolName, kCFStringEncodingUTF8, kCFAllocatorNull);
        void* dataPointer = CFBundleGetDataPointerForName(this->_bundle, cfName);
        CFRelease(cfName);
        return dataPointer;
    }

    virtual bool load() override {
        CFErrorRef error = nullptr;
        bool loaded = CFBundleLoadExecutableAndReturnError(this->_bundle, &error);
        if (error) {
            os_log_error(ns_symbolloader_log(), "%{public}s", [[(NSError*)error localizedDescription] UTF8String]);
        }

        return loaded;
    }

private:
    CFBundleRef _bundle;
};

class DlSymbolResolver : public SymbolResolver {
public:
    DlSymbolResolver(void* libraryHandle) : _libraryHandle(libraryHandle) { }

    virtual void* loadFunctionSymbol(const char* symbolName) override {
        return dlsym(this->_libraryHandle, symbolName);
    }

    virtual void* loadDataSymbol(const char* symbolName) override {
        return dlsym(this->_libraryHandle, symbolName);
    }

    virtual bool load() override {
        return !!this->_libraryHandle;
    }

private:
    void* _libraryHandle;
};

SymbolLoader& SymbolLoader::instance() {
    static SymbolLoader loader;
    return loader;
}

SymbolResolver* SymbolLoader::resolveModule(const ModuleMeta* module) {
    if (!module) {
        return nullptr;
    }

    auto it = this->_cache.find(module);
    if (it != this->_cache.end()) {
        return it->second.get();
    }

    std::unique_ptr<SymbolResolver> resolver;
    if (module->isFramework()) {
        NSString* frameworkPathStr = [NSString stringWithFormat:@"%s.framework", module->getName()];
        NSURL* baseUrl = nil;
        if (module->isSystem()) {
#if TARGET_IPHONE_SIMULATOR
            NSBundle* foundation = [NSBundle bundleForClass:[NSString class]];
            NSString* foundationPath = [foundation bundlePath];
            NSString* basePathStr = [foundationPath substringToIndex:[foundationPath rangeOfString:@"Foundation.framework"].location];
            baseUrl = [NSURL fileURLWithPath:basePathStr isDirectory:YES];
#else
            baseUrl = [NSURL fileURLWithPath:@"/System/Library/Frameworks" isDirectory:YES];
#endif
        } else {
            baseUrl = [[NSBundle mainBundle] privateFrameworksURL];
        }

        NSURL* bundleUrl = [NSURL URLWithString:frameworkPathStr relativeToURL:baseUrl];
        if (CFBundleRef bundle = CFBundleCreate(kCFAllocatorDefault, (CFURLRef)bundleUrl)) {
            resolver = std::make_unique<CFBundleSymbolResolver>(bundle);
        }
    } else if (module->libraries->count == 1) {
        if (module->isSystem()) {
            // NSObject is in /usr/lib/libobjc.dylib, so we get that
            NSString* libsPath = [[NSBundle bundleForClass:[NSObject class]] bundlePath];
            NSString* libraryPath = [NSString stringWithFormat:@"%@/lib%s.dylib", libsPath, module->libraries->first()->value().getName()];

            if (void* library = dlopen(libraryPath.UTF8String, RTLD_LAZY | RTLD_LOCAL)) {
                resolver = std::make_unique<DlSymbolResolver>(library);
            } else if (const char* libraryError = dlerror()) {
                os_log_debug(ns_symbolloader_log(), "NativeScript could not load library %{public}s, error: %{public}s", libraryPath.UTF8String, libraryError);
            }
        }
    }

    return this->_cache.emplace(module, std::move(resolver)).first->second.get();
}

void* SymbolLoader::loadFunctionSymbol(const ModuleMeta* module, const char* symbolName) {
    if (auto resolver = this->resolveModule(module)) {
        return resolver->loadFunctionSymbol(symbolName);
    }

    return dlsym(RTLD_DEFAULT, symbolName);
}

void* SymbolLoader::loadDataSymbol(const ModuleMeta* module, const char* symbolName) {
    if (auto resolver = this->resolveModule(module)) {
        return resolver->loadDataSymbol(symbolName);
    }

    return dlsym(RTLD_DEFAULT, symbolName);
}

bool SymbolLoader::ensureModule(const ModuleMeta* module) {
    if (auto resolver = this->resolveModule(module)) {
        return resolver->load();
    }

    return false;
}

}
