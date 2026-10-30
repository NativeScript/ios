#ifndef StdioForwarder_h
#define StdioForwarder_h

namespace tns {

// Sends what the app writes to stdout and stderr (print(), NSLog on devices) to
// os_log. Without a console those go to /dev/null, and a process can't be
// attached to later: its stdio is fixed at launch. Only debug builds whose CLI
// asks for it through the forwardStdio key of the app's package.json do this.
void StartStdioForwarding();

}  // namespace tns

#endif /* StdioForwarder_h */
