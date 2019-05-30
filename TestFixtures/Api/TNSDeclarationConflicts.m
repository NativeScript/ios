#import "TNSDeclarationConflicts.h"

@implementation TNSInterfaceProtocolConflict
@end

void TNSStructFunctionConflict(struct TNSStructFunctionConflict str) {
    TNSLog(@(str.x).stringValue);
}

const int TNSStructVarConflict = 42;
