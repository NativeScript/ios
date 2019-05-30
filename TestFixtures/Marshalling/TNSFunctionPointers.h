#include "TNSRecords.h"

long long (*functionWhichReturnsSimpleFunctionPointer())(long long);

void functionWithSimpleFunctionPointer(int (*f)(int));
void functionWithComplexFunctionPointer(TNSNestedStruct (*f)(char p1, short p2, int p3, long p4, long long p5, unsigned char p6, unsigned short p7, unsigned int p8, unsigned long p9, unsigned long long p10, float p11, double p12, SEL p13, Class p14, Protocol* p15, NSObject* p16, TNSNestedStruct p17));
void* functionReturningFunctionPtrAsVoidPtr();
