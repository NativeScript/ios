#import <Foundation/Foundation.h>

// Test-only access to NativeScriptDevTunnel.framework through the runtime's
// connector (NativeScript/runtime/DevTunnel.h), and the Mac side of its
// protocol played from inside the app. Sockets give up after 5 s.

#ifdef __cplusplus
extern "C" {
#endif

bool TNSDevTunnelAvailable(void);

// "<bundleId> <tunnelPort> <name>=<port>,...|-", or "" without the framework.
NSString* TNSDevTunnelInfo(void);

// `spec` is "<name>=<port>,..."; tunnelPort 0 takes the default; a nil token
// leaves authentication as it is. "OK <tunnelPort> <name>=<port>,...|-" or
// "ERROR <message>".
NSString* TNSDevTunnelRequest(NSString* spec, int tunnelPort, NSString* token);

// Posts "<bundleId>:NativeScript.Debug.TunnelRequest", as the Mac-side tool does.
void TNSDevTunnelPostTunnelRequest(void);

// A control connection without a token: the READY line, then the answer to
// `command` when it is not empty, separated by "\n". "ERROR <message>" on failure.
NSString* TNSDevTunnelControl(int tunnelPort, NSString* command);

// Opens a pool connection (no token) and an app connection to `appPort`,
// sends `payload` from the app, answers "echo:<payload>" from the pool side.
// "<PAIR line>|<what the pool received>|<what the app received>" or
// "ERROR <message>".
NSString* TNSDevTunnelRoundTrip(int tunnelPort, int appPort, NSString* payload);

#ifdef __cplusplus
}
#endif
