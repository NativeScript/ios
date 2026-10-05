#if defined __cplusplus
extern "C" {
#endif

bool TNSIsConfigurationDebug();

bool TNSIsAddressSanitizerEnabled();

NSString* TNSGetOutput();

void TNSLog(NSString*);

void TNSClearOutput();

void TNSSaveResults(NSString*);

#if defined __cplusplus
}
#endif
