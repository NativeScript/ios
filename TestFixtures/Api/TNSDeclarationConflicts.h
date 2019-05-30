@protocol TNSInterfaceProtocolConflict <NSObject>
@end
@protocol TNSInterfaceProtocolConflictProtocol <NSObject>
@end
@interface TNSInterfaceProtocolConflict : NSObject <TNSInterfaceProtocolConflict, TNSInterfaceProtocolConflictProtocol>
@end

struct TNSStructFunctionConflict {
    int x;
};
void TNSStructFunctionConflict(struct TNSStructFunctionConflict);

struct TNSStructVarConflict {
    int x;
};
extern const int TNSStructVarConflict;
