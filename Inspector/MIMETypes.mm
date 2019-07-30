#include <Foundation/Foundation.h>
#include "MIMETypes.h"

std::string v8_inspector::GetMIMEType(std::string filePath) {
    NSString* nsFilePath = [NSString stringWithUTF8String:filePath.c_str()];
    NSString* fullPath = [nsFilePath stringByExpandingTildeInPath];

    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL isDirectory;
    if (![fileManager fileExistsAtPath:fullPath isDirectory:&isDirectory] || isDirectory) {
        return std::string();
    }

    NSURL* fileUrl = [NSURL fileURLWithPath:fullPath];
    NSURLRequest* request = [[NSURLRequest alloc] initWithURL:fileUrl cachePolicy:NSURLRequestReloadRevalidatingCacheData timeoutInterval:.1];

    __block NSURLResponse *response = nil;

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSession* session = [NSURLSession sharedSession];
    NSURLSessionDataTask* task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *urlResponse, NSError *error) {
        if (error == nil) {
            response = urlResponse;
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

    if (response != nil) {
        NSString* mimeType = [response MIMEType];
        return [mimeType UTF8String];
    }

    return std::string();
}
