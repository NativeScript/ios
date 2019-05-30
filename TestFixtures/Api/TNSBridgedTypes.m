#import "TNSBridgedTypes.h"

TNSObjectRef TNSObjectGet() {
    static NSObject* object;
    if (!object) {
        object = [[NSObject alloc] init];
    }
    return (__bridge TNSObjectRef)(object);
}

TNSMutableObjectRef TNSMutableObjectGet() {
    static NSObject* object;
    if (!object) {
        object = [[NSObject alloc] init];
    }
    return (__bridge TNSMutableObjectRef)(object);
}
