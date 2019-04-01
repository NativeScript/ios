#include <Foundation/NSBundle.h>
#include "Runtime.h"

int main(int argc, char * argv[]) {
    @autoreleasepool {
        NSString* resourcePath = [[NSBundle mainBundle] resourcePath];
        tns::Runtime* runtime = new tns::Runtime();
        std::string baseDir = [resourcePath UTF8String];
        runtime->Init(baseDir);
        runtime->RunScript("index.js");
        return 0;
    }
}
