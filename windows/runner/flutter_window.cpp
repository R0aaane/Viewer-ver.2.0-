#include "flutter_window.h"

#include <iostream>
#include <optional>
#include <utility>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

constexpr ULONG_PTR kProtocolCopyDataTag = 0x58565652;  // XVVR

std::optional<std::string> CopyDataToUtf8Url(LPARAM lparam) {
  auto* copy_data = reinterpret_cast<COPYDATASTRUCT*>(lparam);
  if (copy_data == nullptr || copy_data->dwData != kProtocolCopyDataTag ||
      copy_data->lpData == nullptr || copy_data->cbData == 0) {
    return std::nullopt;
  }

  auto* utf16_url = reinterpret_cast<const wchar_t*>(copy_data->lpData);
  const std::string callback_url = Utf8FromUtf16(utf16_url);
  if (callback_url.empty()) {
    return std::nullopt;
  }

  return callback_url;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

void FlutterWindow::SetInitialCallbackUrl(
    std::optional<std::string> callback_url) {
  pending_callback_url_ = std::move(callback_url);
}

void FlutterWindow::HandleProtocolLaunch(const std::string& callback_url) {
  std::cout << "[xviewer][windows] Received protocol URL: " << callback_url
            << std::endl;
  pending_callback_url_ = callback_url;
  DispatchCallbackUrlToFlutter(callback_url);
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  RegisterAuthCallbackChannels();
  controller_navigation_channel_ = std::make_unique<ControllerNavigationChannel>(
      flutter_controller_->engine()->messenger());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  SetTimer(GetHandle(), kControllerPollTimerId, 16, nullptr);

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  KillTimer(GetHandle(), kControllerPollTimerId);
  controller_navigation_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_COPYDATA: {
      const auto callback_url = CopyDataToUtf8Url(lparam);
      if (callback_url.has_value()) {
        HandleProtocolLaunch(*callback_url);
        return 1;
      }
      break;
    }

    case WM_TIMER:
      if (wparam == kControllerPollTimerId && controller_navigation_channel_) {
        controller_navigation_channel_->Poll();
        return 0;
      }
      break;

    case WM_ACTIVATEAPP:
      if (controller_navigation_channel_) {
        controller_navigation_channel_->SetWindowActive(wparam != FALSE);
      }
      break;

    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::RegisterAuthCallbackChannels() {
  auto* messenger = flutter_controller_->engine()->messenger();
  auto codec = &flutter::StandardMethodCodec::GetInstance();

  method_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "xviewer/auth_callback", codec);
  method_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "consumePendingCallbackUrl") {
      if (pending_callback_url_.has_value()) {
        std::cout
            << "[xviewer][windows] Flutter requested pending callback URL: "
            << *pending_callback_url_ << std::endl;
        result->Success(flutter::EncodableValue(*pending_callback_url_));
        pending_callback_url_.reset();
        return;
      }

      result->Success();
      return;
    }

    result->NotImplemented();
  });

  stream_handler_ =
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [this](
              const flutter::EncodableValue* arguments,
              std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>
                  &&events)
              -> std::unique_ptr<
                  flutter::StreamHandlerError<flutter::EncodableValue>> {
            callback_event_sink_ = std::move(events);
            std::cout << "[xviewer][windows] Flutter event stream attached."
                      << std::endl;
            return nullptr;
          },
          [this](const flutter::EncodableValue* arguments)
              -> std::unique_ptr<
                  flutter::StreamHandlerError<flutter::EncodableValue>> {
            callback_event_sink_.reset();
            std::cout << "[xviewer][windows] Flutter event stream detached."
                      << std::endl;
            return nullptr;
          });

  event_channel_ =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          messenger, "xviewer/auth_callback/events", codec);
  event_channel_->SetStreamHandler(std::move(stream_handler_));
}

void FlutterWindow::DispatchCallbackUrlToFlutter(
    const std::string& callback_url) {
  if (!callback_event_sink_) {
    std::cout << "[xviewer][windows] Flutter event sink not ready; keeping URL "
                 "pending."
              << std::endl;
    return;
  }

  std::cout << "[xviewer][windows] Forwarding callback URL to Flutter: "
            << callback_url << std::endl;
  callback_event_sink_->Success(flutter::EncodableValue(callback_url));
}
