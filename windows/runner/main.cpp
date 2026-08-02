#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <iostream>
#include <optional>
#include <sstream>
#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr wchar_t kRunnerWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr ULONG_PTR kProtocolCopyDataTag = 0x58565652;  // XVVR
constexpr wchar_t kProtocolRegistryKey[] = L"Software\\Classes\\xviewer";

void LogCommandLineArguments(const std::vector<std::string>& arguments) {
  std::ostringstream stream;
  stream << "[xviewer][windows] Launch arguments (" << arguments.size()
         << "):";
  if (arguments.empty()) {
    stream << " <none>";
  } else {
    for (size_t i = 0; i < arguments.size(); ++i) {
      stream << " [" << i << "]=" << arguments[i];
    }
  }
  std::cout << stream.str() << std::endl;
}

std::optional<std::string> ExtractProtocolUrl(
    const std::vector<std::string>& arguments) {
  for (const auto& argument : arguments) {
    if (argument.rfind("xviewer://", 0) == 0) {
      return argument;
    }
  }
  return std::nullopt;
}

std::wstring Utf16FromUtf8(const std::string& utf8_string) {
  if (utf8_string.empty()) {
    return std::wstring();
  }

  const int target_length = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, utf8_string.c_str(),
      static_cast<int>(utf8_string.size()), nullptr, 0);
  if (target_length <= 0) {
    return std::wstring();
  }

  std::wstring utf16_string(target_length, L'\0');
  const int converted_length = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, utf8_string.c_str(),
      static_cast<int>(utf8_string.size()), utf16_string.data(),
      target_length);
  if (converted_length <= 0) {
    return std::wstring();
  }

  return utf16_string;
}

std::wstring GetExecutablePath() {
  std::wstring path(MAX_PATH, L'\0');
  DWORD copied = ::GetModuleFileName(nullptr, path.data(),
                                     static_cast<DWORD>(path.size()));
  while (copied >= path.size() - 1) {
    path.resize(path.size() * 2, L'\0');
    copied = ::GetModuleFileName(nullptr, path.data(),
                                 static_cast<DWORD>(path.size()));
  }
  path.resize(copied);
  return path;
}

bool SetRegistryStringValue(HKEY key,
                            const wchar_t* value_name,
                            const std::wstring& value) {
  const BYTE* data = reinterpret_cast<const BYTE*>(value.c_str());
  const DWORD size = static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t));
  return ::RegSetValueEx(key, value_name, 0, REG_SZ, data, size) ==
         ERROR_SUCCESS;
}

bool EnsureProtocolRegistration() {
  const std::wstring executable_path = GetExecutablePath();
  const std::wstring open_command = L"\"" + executable_path + L"\" \"%1\"";
  HKEY protocol_key = nullptr;
  LONG result = ::RegCreateKeyEx(HKEY_CURRENT_USER, kProtocolRegistryKey, 0,
                                 nullptr, REG_OPTION_NON_VOLATILE, KEY_WRITE,
                                 nullptr, &protocol_key, nullptr);
  if (result != ERROR_SUCCESS) {
    std::cout << "[xviewer][windows] Failed to open protocol registry key. "
                 "error="
              << result << std::endl;
    return false;
  }

  bool success = true;
  success = SetRegistryStringValue(protocol_key, nullptr,
                                   L"URL:xviewer Protocol") &&
            success;
  success = SetRegistryStringValue(protocol_key, L"URL Protocol", L"") &&
            success;

  HKEY command_key = nullptr;
  result = ::RegCreateKeyEx(protocol_key, L"shell\\open\\command", 0, nullptr,
                            REG_OPTION_NON_VOLATILE, KEY_WRITE, nullptr,
                            &command_key, nullptr);
  if (result != ERROR_SUCCESS) {
    std::cout << "[xviewer][windows] Failed to open command registry key. "
                 "error="
              << result << std::endl;
    success = false;
  } else {
    success = SetRegistryStringValue(command_key, nullptr, open_command) &&
              success;
    ::RegCloseKey(command_key);
  }

  ::RegCloseKey(protocol_key);
  std::cout << "[xviewer][windows] Protocol registration "
            << (success ? "updated" : "failed") << std::endl;
  return success;
}

bool ForwardProtocolUrlToRunningInstance(const std::string& callback_url) {
  HWND existing_window = ::FindWindow(kRunnerWindowClassName, nullptr);
  if (existing_window == nullptr) {
    return false;
  }

  const std::wstring callback_url_utf16 = Utf16FromUtf8(callback_url);
  if (callback_url_utf16.empty()) {
    return false;
  }

  COPYDATASTRUCT copy_data{};
  copy_data.dwData = kProtocolCopyDataTag;
  copy_data.cbData =
      static_cast<DWORD>((callback_url_utf16.size() + 1) * sizeof(wchar_t));
  copy_data.lpData = const_cast<wchar_t*>(callback_url_utf16.c_str());

  std::cout << "[xviewer][windows] Forwarding protocol URL to running "
               "instance: "
            << callback_url << std::endl;
  ::SendMessage(existing_window, WM_COPYDATA, 0,
                reinterpret_cast<LPARAM>(&copy_data));
  ::SetForegroundWindow(existing_window);
  return true;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  EnsureProtocolRegistration();

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  LogCommandLineArguments(command_line_arguments);
  std::optional<std::string> initial_callback_url =
      ExtractProtocolUrl(command_line_arguments);
  std::cout << "[xviewer][windows] Extracted protocol URL: "
            << (initial_callback_url.has_value() ? *initial_callback_url
                                                 : "<none>")
            << std::endl;

  if (initial_callback_url.has_value() &&
      ForwardProtocolUrlToRunningInstance(*initial_callback_url)) {
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  window.SetInitialCallbackUrl(initial_callback_url);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"\u7D19\u9B5A", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
