#include "controller_navigation_channel.h"

#include <windows.h>
#include <Xinput.h>

#include <flutter/method_result.h>
#include <flutter/standard_method_codec.h>

namespace {

constexpr char kChannelName[] = "pdf_viewer/controller_navigation";
constexpr SHORT kLeftStickDeadZone = 16000;

bool IsPressedUp(const XINPUT_GAMEPAD& gamepad) {
  return (gamepad.wButtons & XINPUT_GAMEPAD_DPAD_UP) != 0 ||
         gamepad.sThumbLY > kLeftStickDeadZone;
}

bool IsPressedDown(const XINPUT_GAMEPAD& gamepad) {
  return (gamepad.wButtons & XINPUT_GAMEPAD_DPAD_DOWN) != 0 ||
         gamepad.sThumbLY < -kLeftStickDeadZone;
}

bool IsPressedLeft(const XINPUT_GAMEPAD& gamepad) {
  return (gamepad.wButtons & XINPUT_GAMEPAD_DPAD_LEFT) != 0 ||
         gamepad.sThumbLX < -kLeftStickDeadZone;
}

bool IsPressedRight(const XINPUT_GAMEPAD& gamepad) {
  return (gamepad.wButtons & XINPUT_GAMEPAD_DPAD_RIGHT) != 0 ||
         gamepad.sThumbLX > kLeftStickDeadZone;
}

bool IsActivatePressed(const XINPUT_GAMEPAD& gamepad) {
  return (gamepad.wButtons & XINPUT_GAMEPAD_A) != 0;
}

bool IsBackPressed(const XINPUT_GAMEPAD& gamepad) {
  return (gamepad.wButtons & XINPUT_GAMEPAD_B) != 0 ||
         (gamepad.wButtons & XINPUT_GAMEPAD_BACK) != 0;
}

const char* DirectionControlUp(const XINPUT_GAMEPAD& gamepad) {
  return (gamepad.wButtons & XINPUT_GAMEPAD_DPAD_UP) != 0 ? "dpad_up"
                                                           : "left_stick_up";
}

const char* DirectionControlDown(const XINPUT_GAMEPAD& gamepad) {
  return (gamepad.wButtons & XINPUT_GAMEPAD_DPAD_DOWN) != 0 ? "dpad_down"
                                                             : "left_stick_down";
}

const char* DirectionControlLeft(const XINPUT_GAMEPAD& gamepad) {
  return (gamepad.wButtons & XINPUT_GAMEPAD_DPAD_LEFT) != 0 ? "dpad_left"
                                                             : "left_stick_left";
}

const char* DirectionControlRight(const XINPUT_GAMEPAD& gamepad) {
  return (gamepad.wButtons & XINPUT_GAMEPAD_DPAD_RIGHT) != 0
             ? "dpad_right"
             : "left_stick_right";
}

const char* BackControl(const XINPUT_GAMEPAD& gamepad) {
  return (gamepad.wButtons & XINPUT_GAMEPAD_BACK) != 0 ? "button_back"
                                                        : "button_b";
}

}  // namespace

ControllerNavigationChannel::ControllerNavigationChannel(
    flutter::BinaryMessenger* messenger)
    : channel_(std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger,
          kChannelName,
          &flutter::StandardMethodCodec::GetInstance())) {
  channel_->Resize(8);
  channel_->SetWarnsOnOverflow(false);
  RegisterMethodHandler();
}

ControllerNavigationChannel::~ControllerNavigationChannel() {
  if (channel_) {
    channel_->SetMethodCallHandler(nullptr);
  }
}

void ControllerNavigationChannel::RegisterMethodHandler() {
  channel_->SetMethodCallHandler(
      [this](
          const flutter::MethodCall<flutter::EncodableValue>& call,
          std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
              result) {
        if (call.method_name() == "getStatus") {
          result->Success(flutter::EncodableValue(BuildStatusPayload()));
          return;
        }
        result->NotImplemented();
      });
}

flutter::EncodableMap ControllerNavigationChannel::BuildStatusPayload() const {
  flutter::EncodableMap payload;
  payload[flutter::EncodableValue("backend")] =
      flutter::EncodableValue("xinput");
  payload[flutter::EncodableValue("connected")] =
      flutter::EncodableValue(controller_connected_);
  if (controller_index_ >= 0) {
    payload[flutter::EncodableValue("controllerIndex")] =
        flutter::EncodableValue(controller_index_);
  }
  return payload;
}

void ControllerNavigationChannel::EmitStatus() {
  channel_->InvokeMethod(
      "controllerStatus",
      std::make_unique<flutter::EncodableValue>(BuildStatusPayload()));
}

void ControllerNavigationChannel::EmitAction(Action action,
                                             const char* control) {
  flutter::EncodableMap payload;
  payload[flutter::EncodableValue("backend")] =
      flutter::EncodableValue("xinput");
  payload[flutter::EncodableValue("action")] =
      flutter::EncodableValue(ActionName(action));
  payload[flutter::EncodableValue("control")] =
      flutter::EncodableValue(control);
  if (controller_index_ >= 0) {
    payload[flutter::EncodableValue("controllerIndex")] =
        flutter::EncodableValue(controller_index_);
  }

  channel_->InvokeMethod(
      "controllerAction",
      std::make_unique<flutter::EncodableValue>(std::move(payload)));
}

void ControllerNavigationChannel::UpdateDirectional(Action action,
                                                    bool pressed,
                                                    const char* control,
                                                    TimePoint now) {
  RepeatState* state = nullptr;
  switch (action) {
    case Action::kUp:
      state = &up_state_;
      break;
    case Action::kDown:
      state = &down_state_;
      break;
    case Action::kLeft:
      state = &left_state_;
      break;
    case Action::kRight:
      state = &right_state_;
      break;
    case Action::kActivate:
    case Action::kBack:
      return;
  }

  if (!pressed) {
    state->active = false;
    return;
  }

  if (!state->active) {
    state->active = true;
    state->first_dispatch_at = now;
    state->last_dispatch_at = now;
    EmitAction(action, control);
    return;
  }

  if (now - state->first_dispatch_at < kInitialRepeatDelay) {
    return;
  }
  if (now - state->last_dispatch_at < kRepeatInterval) {
    return;
  }

  state->last_dispatch_at = now;
  EmitAction(action, control);
}

void ControllerNavigationChannel::UpdateButton(Action action,
                                               bool pressed,
                                               bool& previous_pressed,
                                               const char* control) {
  if (!pressed) {
    previous_pressed = false;
    return;
  }
  if (previous_pressed) {
    return;
  }

  previous_pressed = true;
  EmitAction(action, control);
}

void ControllerNavigationChannel::ResetState() {
  activate_pressed_ = false;
  back_pressed_ = false;
  up_state_.active = false;
  down_state_.active = false;
  left_state_.active = false;
  right_state_.active = false;
}

void ControllerNavigationChannel::SetWindowActive(bool active) {
  if (window_active_ == active) {
    return;
  }

  window_active_ = active;
  if (!window_active_) {
    ResetState();
  }
}

void ControllerNavigationChannel::Poll() {
  if (!window_active_) {
    return;
  }

  XINPUT_STATE state{};
  int connected_index = -1;
  for (DWORD index = 0; index < kMaxControllers; ++index) {
    if (XInputGetState(index, &state) == ERROR_SUCCESS) {
      connected_index = static_cast<int>(index);
      break;
    }
  }

  const bool connected = connected_index >= 0;
  if (connected != controller_connected_ ||
      connected_index != controller_index_) {
    controller_connected_ = connected;
    controller_index_ = connected_index;
    ResetState();
    EmitStatus();
  }

  if (!connected) {
    return;
  }

  const auto now = Clock::now();
  const auto& gamepad = state.Gamepad;

  UpdateDirectional(
      Action::kUp, IsPressedUp(gamepad), DirectionControlUp(gamepad), now);
  UpdateDirectional(Action::kDown,
                    IsPressedDown(gamepad),
                    DirectionControlDown(gamepad),
                    now);
  UpdateDirectional(Action::kLeft,
                    IsPressedLeft(gamepad),
                    DirectionControlLeft(gamepad),
                    now);
  UpdateDirectional(Action::kRight,
                    IsPressedRight(gamepad),
                    DirectionControlRight(gamepad),
                    now);
  UpdateButton(Action::kActivate,
               IsActivatePressed(gamepad),
               activate_pressed_,
               "button_a");
  UpdateButton(
      Action::kBack, IsBackPressed(gamepad), back_pressed_, BackControl(gamepad));
}

const char* ControllerNavigationChannel::ActionName(Action action) {
  switch (action) {
    case Action::kUp:
      return "up";
    case Action::kDown:
      return "down";
    case Action::kLeft:
      return "left";
    case Action::kRight:
      return "right";
    case Action::kActivate:
      return "activate";
    case Action::kBack:
      return "back";
  }
  return "unknown";
}
