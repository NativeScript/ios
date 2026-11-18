#import "TNSFunctions.h"
#include <mach/mach.h>

bool TNSHasExecutableV8Memory(void) {
  vm_address_t address = 0;
  for (;;) {
    vm_size_t size = 0;
    natural_t depth = 0;
    struct vm_region_submap_info_64 info;
    mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
    if (vm_region_recurse_64(mach_task_self(), &address, &size, &depth,
                             (vm_region_recurse_info_t)&info, &count) != KERN_SUCCESS) {
      return false;
    }
    if (info.user_tag == 255 && (info.protection & VM_PROT_EXECUTE)) {
      return true;
    }
    address += size;
  }
}

CFArrayRef CFArrayCreateWithString(CFStringRef string) {
    const void* values[] = { string };
    return CFArrayCreate(kCFAllocatorDefault, values, 1, &kCFTypeArrayCallBacks);
}
