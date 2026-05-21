#ifndef FLUTTER_PLUGIN_PERMISSION_HANDLER_WINDOWS_PLUGIN_H_
#define FLUTTER_PLUGIN_PERMISSION_HANDLER_WINDOWS_PLUGIN_H_

#include <flutter/plugin_registrar_windows.h>

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FLUTTER_PLUGIN_EXPORT __declspec(dllimport)
#endif

extern "C" {
FLUTTER_PLUGIN_EXPORT void PermissionHandlerWindowsPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);
}

#endif  // FLUTTER_PLUGIN_PERMISSION_HANDLER_WINDOWS_PLUGIN_H_
