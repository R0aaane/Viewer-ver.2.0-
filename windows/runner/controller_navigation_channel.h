#ifndef RUNNER_CONTROLLER_NAVIGATION_CHANNEL_H_
#define RUNNER_CONTROLLER_NAVIGATION_CHANNEL_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <chrono>
#include <memory>

class ControllerNavigationChannel {
 public:
  explicit ControllerNavigationChannel(flutter::BinaryMessenger* messenger);
  ~ControllerNavigationChannel();

  void Poll();
  void SetWindowActive(bool active);

 private:
  enum class Action {
    kUp,
    kDown,
    kLeft,
    kRight,
    kActivate,
    kBack,
  };

  struct RepeatState {
    bool active = false;
    std::chrono::steady_clock::time_point first_dispatch_at{};
    std::chrono::steady_clock::time_point last_dispatch_at{};
  };

  using Clock = std::chrono::steady_clock;
  using TimePoint = Clock::time_point;

  static constexpr int kMaxControllers = 4;
  static constexpr std::chrono::milliseconds kInitialRepeatDelay{360};
  static constexpr std::chrono::milliseconds kRepeatInterval{120};

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  bool window_active_ = true;
  bool controller_connected_ = false;
  int controller_index_ = -1;
  bool activate_pressed_ = false;
  bool back_pressed_ = false;
  RepeatState up_state_;
  RepeatState down_state_;
  RepeatState left_state_;
  RepeatState right_state_;

  void RegisterMethodHandler();
  flutter::EncodableMap BuildStatusPayload() const;
  void EmitStatus();
  void EmitAction(Action action, const char* control);
  void UpdateDirectional(Action action,
                         bool pressed,
                         const char* control,
                         TimePoint now);
  void UpdateButton(Action action,
                    bool pressed,
                    bool& previous_pressed,
                    const char* control);
  void ResetState();
  static const char* ActionName(Action action);
};

#endif  // RUNNER_CONTROLLER_NAVIGATION_CHANNEL_H_
