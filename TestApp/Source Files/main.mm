#import <UIKit/UIKit.h>
#import <NativeScript.h>

extern char startOfMetadataSection __asm("section$start$__DATA$__TNSMetadata");

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSString* resourcePath = [[NSBundle mainBundle] resourcePath];
        NSArray* components = [NSArray arrayWithObjects:resourcePath, @"app", nil];
        NSString* path = [NSString pathWithComponents:components];

        tns::Runtime::InitializeMetadata(&startOfMetadataSection);
        tns::Runtime* runtime = new tns::Runtime();
        std::string baseDir = [path UTF8String];
        runtime->InitAndRunMainScript(baseDir);

        return 0;
    }
}
