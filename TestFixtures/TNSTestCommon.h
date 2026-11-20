#if defined __cplusplus
extern "C" {
#endif

bool TNSIsConfigurationDebug();

bool TNSIsAddressSanitizerEnabled();

// Isolates that start while set run without NativeScriptLeakProbe.framework,
// as in an app that does not embed it. False when the framework is absent.
bool TNSLeakProbeDeclineIsolates(bool decline);

NSString* TNSGetOutput();

void TNSLog(NSString*);

void TNSClearOutput();

void TNSSaveResults(NSString*);

#if defined __cplusplus
}
#endif
