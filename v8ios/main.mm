#import <UIKit/UIKit.h>
#include "Runtime.h"

int main(int argc, char * argv[]) {
    // TODO: Statically ensure that the UIKit.framework is loaded. This needs to be moved in a SymbolResolver class later
    // to ensure that the required protocols are dynamically loaded at runtime
    assert(@protocol(UIApplicationDelegate));

    @autoreleasepool {
        NSString* resourcePath = [[NSBundle mainBundle] resourcePath];
        NSArray* components = [NSArray arrayWithObjects:resourcePath, @"app", nil];
        NSString* path = [NSString pathWithComponents:components];

        tns::Runtime* runtime = new tns::Runtime();
        std::string baseDir = [path UTF8String];
        runtime->Init(baseDir);
        runtime->RunScript("index.js");

        return 0;
    }
}
