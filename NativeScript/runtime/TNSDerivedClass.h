#ifndef TNSDerivedClass_h
#define TNSDerivedClass_h

@protocol TNSDerivedClass

@end

// Adopted by a derived class whose -retain and -release tell its instance's
// wrapper when native code starts and stops owning the object. Subclasses
// inherit those methods but not the conformance.
@protocol TNSRetainTrackedClass

@end

#endif /* TNSDerivedClass_h */
