#include "StdioForwarder.h"
#include <Foundation/Foundation.h>
#include <TargetConditionals.h>
#include <dispatch/dispatch.h>
#include <os/log.h>
#include <stdio.h>
#include <unistd.h>
#include <memory>
#include <mutex>
#include <string>
#include "Helpers.h"
#include "Runtime.h"
#include "RuntimeConfig.h"

namespace tns {

namespace {

// The CLI tells these entries apart from JS console output by this subsystem.
constexpr const char* kStdioSubsystem = "org.nativescript.stdio";

// A longer line goes out in parts instead of growing the buffer without limit.
constexpr size_t kMaxBufferedLineBytes = 64 * 1024;

void Forward(int fd, const char* category, dispatch_queue_t queue) {
  int fds[2];
  if (pipe(fds) != 0) {
    return;
  }
  if (dup2(fds[1], fd) < 0) {
    close(fds[0]);
    close(fds[1]);
    return;
  }
  close(fds[1]);

  int readEnd = fds[0];
  os_log_t log = os_log_create(kStdioSubsystem, category);
  auto pending = std::make_shared<std::string>();
  dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, readEnd, 0, queue);
  dispatch_source_set_event_handler(source, ^{
    char buffer[4096];
    ssize_t count = read(readEnd, buffer, sizeof(buffer));
    if (count <= 0) {
      return;
    }
    pending->append(buffer, count);

    size_t start = 0;
    size_t end;
    while ((end = pending->find('\n', start)) != std::string::npos) {
      TNS_WriteToOsLog(pending->substr(start, end - start).c_str(), OS_LOG_TYPE_DEFAULT, "", log);
      start = end + 1;
    }
    pending->erase(0, start);

    if (pending->size() >= kMaxBufferedLineBytes) {
      TNS_WriteToOsLog(pending->c_str(), OS_LOG_TYPE_DEFAULT, "", log);
      pending->clear();
    }
  });
  dispatch_resume(source);
}

}  // namespace

void StartStdioForwarding() {
  static std::once_flag once;
  std::call_once(once, [] {
    if (!RuntimeConfig.IsDebug || RuntimeConfig.ApplicationPath.empty()) {
      return;
    }

    id value = Runtime::GetAppConfigValue("forwardStdio");
    if (value == nil || ![value boolValue] || !IsDevNull(STDOUT_FILENO)) {
      return;
    }

    // Decided once and from stdout, which is about to stop being /dev/null.
    ShouldMarkLogChunks();

    // Otherwise stdout is fully buffered into a pipe, and print() only shows up
    // when the buffer fills.
    setvbuf(stdout, nullptr, _IOLBF, 0);

    // Serial, so that the chunks of a split line stay together.
    dispatch_queue_t queue =
        dispatch_queue_create("org.nativescript.stdio", DISPATCH_QUEUE_SERIAL);
    Forward(STDOUT_FILENO, "stdout", queue);
#if !TARGET_OS_SIMULATOR
    // On the simulator NSLog reaches the unified log as well, so forwarding
    // stderr there would print it twice.
    Forward(STDERR_FILENO, "stderr", queue);
#endif
  });
}

}  // namespace tns
