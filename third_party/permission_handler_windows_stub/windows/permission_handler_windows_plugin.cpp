#include "include/permission_handler_windows/permission_handler_windows_plugin.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>

namespace {

class PermissionHandlerWindowsPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  PermissionHandlerWindowsPlugin() = default;
  ~PermissionHandlerWindowsPlugin() override = default;

  PermissionHandlerWindowsPlugin(const PermissionHandlerWindowsPlugin&) = delete;
  PermissionHandlerWindowsPlugin& operator=(
      const PermissionHandlerWindowsPlugin&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

void PermissionHandlerWindowsPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "flutter.baseflow.com/permissions/methods",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<PermissionHandlerWindowsPlugin>();

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](
          const auto& call,
          auto result) { plugin_pointer->HandleMethodCall(call, std::move(result)); });

  registrar->AddPlugin(std::move(plugin));
}

void PermissionHandlerWindowsPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method_name = method_call.method_name();

  if (method_name == "checkPermissionStatus") {
    result->Success(flutter::EncodableValue(1));
    return;
  }

  if (method_name == "requestPermissions") {
    flutter::EncodableMap request_results;
    const auto* permissions =
        std::get_if<flutter::EncodableList>(method_call.arguments());
    if (permissions != nullptr) {
      for (const auto& permission : *permissions) {
        request_results[permission] = flutter::EncodableValue(1);
      }
    }
    result->Success(flutter::EncodableValue(request_results));
    return;
  }

  if (method_name == "checkServiceStatus") {
    result->Success(flutter::EncodableValue(2));
    return;
  }

  if (method_name == "shouldShowRequestPermissionRationale" ||
      method_name == "openAppSettings") {
    result->Success(flutter::EncodableValue(false));
    return;
  }

  result->NotImplemented();
}

}  // namespace

void PermissionHandlerWindowsPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  PermissionHandlerWindowsPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
