#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <optional>
#include <string>

#include "controller_navigation_channel.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  void SetInitialCallbackUrl(std::optional<std::string> callback_url);
  void HandleProtocolLaunch(const std::string& callback_url);

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  static constexpr UINT_PTR kControllerPollTimerId = 1001;

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<ControllerNavigationChannel> controller_navigation_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      method_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      event_channel_;
  std::unique_ptr<flutter::StreamHandlerFunctions<flutter::EncodableValue>>
      stream_handler_;
  std::optional<std::string> pending_callback_url_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>
      callback_event_sink_;

  void RegisterAuthCallbackChannels();
  void DispatchCallbackUrlToFlutter(const std::string& callback_url);
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
