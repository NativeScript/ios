//
//  macros.h
//  sampleng
//
//  Created by Team nStudio on 1/19/24.
//  Copyright © 2024 NativeScript. All rights reserved.
//

#ifndef macros_h
#define macros_h

#define NOTIFICATION(name)                                                      \
   [[NSString stringWithFormat:@"%@:NativeScript.Debug.%s",                    \
       [[NSBundle mainBundle] bundleIdentifier], name] UTF8String]


#endif /* macros_h */
