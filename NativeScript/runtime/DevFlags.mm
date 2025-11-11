#import <Foundation/Foundation.h>

#include "DevFlags.h"
#include "Runtime.h"
#include "RuntimeConfig.h"

namespace tns {

bool IsScriptLoadingLogEnabled() {
  id value = Runtime::GetAppConfigValue("logScriptLoading");
  return value ? [value boolValue] : false;
}

} // namespace tns
