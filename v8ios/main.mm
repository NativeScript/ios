#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#include "Runtime.h"
#include <string>

int main(int argc, char * argv[]) {
    @autoreleasepool {
        //return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));

        NSString* resourcePath = [[NSBundle mainBundle] resourcePath];
        tns::Runtime* runtime = new tns::Runtime();
        std::string baseDir = [resourcePath UTF8String];
        runtime->Init(baseDir);
        runtime->RunScript("index.js");

        return 0;
    }
}
