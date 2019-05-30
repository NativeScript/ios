typedef const struct CF_BRIDGED_TYPE(id) __TNSObject* TNSObjectRef;
TNSObjectRef TNSObjectGet() CF_RETURNS_RETAINED;

typedef struct CF_BRIDGED_MUTABLE_TYPE(id) __TNSMutableObject* TNSMutableObjectRef;
TNSMutableObjectRef TNSMutableObjectGet() CF_RETURNS_RETAINED;

// TODO: Handle CF_RELATED_TYPE, too
