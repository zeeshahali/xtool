#ifndef PREFIX_INCLUDED
#error "prefix header was not included"
#endif
#if !FROM_XCCONFIG || !IOS_DEVICE
#error "xcconfig / conditional settings were not applied"
#endif
// found only via the header map, like Unity plugins rely on
#include "PluginHelper.h"
#include "GameLib.h"
#include <UnityFramework/UnityFramework.h>

extern "C" int PluginValue(void);

int UnityFrameworkEntry(int argc)
{
    return PluginHelperValue() + GameLibValue() + PluginValue() + argc;
}
