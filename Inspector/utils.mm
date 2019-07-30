#include <Foundation/Foundation.h>
#include "utils.h"
#include <codecvt>
#include <locale>

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

std::string v8_inspector::ToStdString(const StringView& value) {
    std::vector<uint16_t> buffer(value.length());
    for (size_t i = 0; i < value.length(); i++) {
        if (value.is8Bit()) {
            buffer[i] = value.characters8()[i];
        } else {
            buffer[i] = value.characters16()[i];
        }
    }

    std::u16string value16(buffer.begin(), buffer.end());

    std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t> convert;
    std::string result = convert.to_bytes(value16);

    return result;
}

std::vector<uint16_t> v8_inspector::ToVector(const std::string& value) {
    std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t> convert;
    std::u16string valueu16 = convert.from_bytes(value);

    const uint16_t *begin = reinterpret_cast<uint16_t const*>(valueu16.data());
    const uint16_t *end = reinterpret_cast<uint16_t const*>(valueu16.data() + valueu16.size());
    std::vector<uint16_t> vector(begin, end);
    return vector;
}
