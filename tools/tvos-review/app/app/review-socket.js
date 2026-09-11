// The reviewer only needs text messages. Use Foundation directly because the
// default WebSocket plugin's published XCFramework has no tvOS slice.
const Delegate = NSObject.extend({
  URLSessionWebSocketTaskDidOpenWithProtocol(session, task, protocol) {
    const socket = this.socket;
    if (socket.readyState !== 0) return;
    socket.readyState = 1;
    socket.onopen?.();
    socket.receive();
  },
  URLSessionWebSocketTaskDidCloseWithCloseCodeReason(session, task, code, reason) {
    this.socket.closed();
  },
  URLSessionTaskDidCompleteWithError(session, task, error) {
    const socket = this.socket;
    if (error && socket.readyState !== 3 && !socket.finishedNormally()) socket.onerror?.({ message: error.localizedDescription });
    socket.closed();
  },
}, { protocols: [NSURLSessionWebSocketDelegate] });

export function createReviewSocket(url) {
  const socket = {
    readyState: 0,
    onopen: null,
    onmessage: null,
    onerror: null,
    onclose: null,
    finishedNormally() {
      return Number(this.task.valueForKey('closeCode')) === 1000;
    },
    receive() {
      if (this.readyState !== 1) return;
      NSURLSessionWebSocketTask.prototype.receiveMessageWithCompletionHandler.call(this.task, (message, error) => {
        if (this.readyState !== 1) return;
        if (error) {
          if (this.finishedNormally()) { this.closed(); return; }
          this.onerror?.({ message: error.localizedDescription });
          this.close();
          return;
        }
        this.onmessage?.({ data: message.string });
        this.receive();
      });
    },
    send(text) {
      if (this.readyState !== 1) throw new Error('Review socket is not open');
      NSURLSessionWebSocketTask.prototype.sendMessageCompletionHandler.call(this.task, NSURLSessionWebSocketMessage.alloc().initWithString(text), error => {
        if (error && this.readyState === 1) this.onerror?.({ message: error.localizedDescription });
      });
    },
    closed() {
      if (this.readyState === 3) return;
      this.readyState = 3;
      this.session.invalidateAndCancel();
      this.onclose?.();
    },
    close() {
      NSURLSessionWebSocketTask.prototype.cancelWithCloseCodeReason.call(this.task, 1000, null);
      this.closed();
    },
  };
  socket.delegate = Delegate.new();
  socket.delegate.socket = socket;
  socket.session = NSURLSession.sessionWithConfigurationDelegateDelegateQueue(
    NSURLSessionConfiguration.defaultSessionConfiguration, socket.delegate, NSOperationQueue.mainQueue);
  socket.task = socket.session.webSocketTaskWithURL(NSURL.URLWithString(url));
  socket.task.resume();
  return socket;
}
