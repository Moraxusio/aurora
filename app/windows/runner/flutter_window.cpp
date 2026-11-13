#include "flutter_window.h"

#include <optional>
#include <flutter/standard_method_codec.h>
#include <flutter/method_result_functions.h>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"
#include "ai_input.h"

namespace {
constexpr UINT kTrayMessage = WM_APP + 40;
constexpr UINT kExitMessage = WM_APP + 41;
constexpr UINT kRestoreCommand = 31001;
constexpr UINT kExitCommand = 31002;
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             const DesktopInstance& instance)
    : project_(project), instance_(instance) {}

FlutterWindow::~FlutterWindow() {}

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
  input_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "aurora3/input", &flutter::StandardMethodCodec::GetInstance());
  input_channel_->SetMethodCallHandler(HandleAiInput);
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  if (!instance_.MarkWindow(GetHandle())) return false;
  taskbar_created_ = RegisterWindowMessageW(L"TaskbarCreated");
  AddTray();
  desktop_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "aurora3/desktop",
      &flutter::StandardMethodCodec::GetInstance());
  desktop_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const HWND hwnd = GetHandle();
    const auto& name = call.method_name();
    if (name == "ready") {
      Visibility(!hidden_ && !IsIconic(hwnd));
      // The window has no caption (win32_window.cpp): the app draws one.
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("frameless"), flutter::EncodableValue(true)},
          {flutter::EncodableValue("maximized"), flutter::EncodableValue(IsZoomed(hwnd) != FALSE)},
      }));
    } else if (name == "hide") {
      HideToTray();
      result->Success();
    } else if (name == "restore") {
      Restore();
      result->Success();
    } else if (name == "startDrag") {
      // The system's own move loop: snapping and Aero Shake work as with a caption.
      ReleaseCapture();
      SendMessage(hwnd, WM_SYSCOMMAND, SC_MOVE | HTCAPTION, 0);
      result->Success();
    } else if (name == "startResize") {
      const auto* edge = std::get_if<std::string>(call.arguments());
      WPARAM side = WMSZ_TOP;
      if (edge && *edge == "topLeft") side = WMSZ_TOPLEFT;
      if (edge && *edge == "topRight") side = WMSZ_TOPRIGHT;
      ReleaseCapture();
      SendMessage(hwnd, WM_SYSCOMMAND, SC_SIZE | side, 0);
      result->Success();
    } else if (name == "minimize") {
      ShowWindow(hwnd, SW_MINIMIZE);
      result->Success();
    } else if (name == "toggleMaximize") {
      ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
      result->Success();
    } else if (name == "close") {
      // the same as the caption's close button: hide to the tray
      PostMessage(hwnd, WM_CLOSE, 0, 0);
      result->Success();
    } else {
      result->NotImplemented();
    }
  });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if (!hidden_) this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  RemoveTray();
  if (GetHandle()) RemovePropW(GetHandle(), instance_.property().c_str());
  desktop_channel_ = nullptr;
  input_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Native lifecycle messages must not be consumed by a plugin first.
  if (message == instance_.restore_message()) {
    Restore();
    return 0;
  }
  if (message == taskbar_created_ && taskbar_created_ != 0) {
    tray_available_ = false;
    if (!AddTray() && hidden_) Restore();
    return 0;
  }
  if (message == kTrayMessage) {
    const UINT event = LOWORD(lparam);
    if (event == NIN_SELECT || event == NIN_KEYSELECT || event == WM_LBUTTONUP) Restore();
    if (event == WM_CONTEXTMENU || event == WM_RBUTTONUP) TrayMenu();
    return 0;
  }
  if (message == WM_CLOSE) {
    HideToTray();
    return 0;
  }
  if (message == WM_COMMAND) {
    if (LOWORD(wparam) == kRestoreCommand) { Restore(); return 0; }
    if (LOWORD(wparam) == kExitCommand) { RequestExit(); return 0; }
  }
  if (message == kExitMessage) {
    Destroy();
    return 0;
  }
  if (message == WM_SIZE) {
    Visibility(wparam != SIZE_MINIMIZED && !hidden_);
    if (desktop_channel_ && wparam != SIZE_MINIMIZED) {
      desktop_channel_->InvokeMethod("maximized", std::make_unique<flutter::EncodableValue>(wparam == SIZE_MAXIMIZED));
    }
  }
  if (message == WM_ENDSESSION && wparam) {
    Destroy();
    return 0;
  }
  // Give Flutter, including plugins, an opportunity to handle other messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      if (flutter_controller_) flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

bool FlutterWindow::AddTray() {
  if (tray_available_) return true;
  tray_ = {};
  tray_.cbSize = sizeof(tray_);
  tray_.hWnd = GetHandle();
  tray_.uID = 1;
  tray_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP | NIF_SHOWTIP;
  tray_.uCallbackMessage = kTrayMessage;
  tray_.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(tray_.szTip, L"Aurora 3 — 后台常驻");
  tray_available_ = Shell_NotifyIconW(NIM_ADD, &tray_) != FALSE ||
                    Shell_NotifyIconW(NIM_MODIFY, &tray_) != FALSE;
  if (tray_available_) {
    tray_.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &tray_);
  }
  return tray_available_;
}

void FlutterWindow::RemoveTray() {
  if (tray_available_) Shell_NotifyIconW(NIM_DELETE, &tray_);
  tray_available_ = false;
}

void FlutterWindow::Visibility(bool visible) {
  if (desktop_channel_) desktop_channel_->InvokeMethod("visibility", std::make_unique<flutter::EncodableValue>(visible));
}

void FlutterWindow::Restore() {
  hidden_ = false;
  ShowWindow(GetHandle(), IsIconic(GetHandle()) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(GetHandle());
  Visibility(true);
  if (flutter_controller_) flutter_controller_->ForceRedraw();
}

void FlutterWindow::HideToTray() {
  // If Explorer/the tray is unavailable, keep a taskbar button rather than
  // hiding a window that the user has no way to restore.
  hidden_ = AddTray();
  Visibility(false);
  ShowWindow(GetHandle(), hidden_ ? SW_HIDE : SW_MINIMIZE);
}

void FlutterWindow::TrayMenu() {
  HMENU menu = CreatePopupMenu();
  AppendMenuW(menu, MF_STRING, kRestoreCommand, L"显示 Aurora 3");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kExitCommand, L"退出 Aurora 3…");
  POINT point{};
  GetCursorPos(&point);
  SetForegroundWindow(GetHandle());
  TrackPopupMenu(menu, TPM_RIGHTBUTTON, point.x, point.y, 0, GetHandle(), nullptr);
  DestroyMenu(menu);
  PostMessage(GetHandle(), WM_NULL, 0, 0);
}

void FlutterWindow::RequestExit() {
  if (exit_pending_ || !desktop_channel_) return;
  Restore();
  exit_pending_ = true;
  desktop_channel_->InvokeMethod("requestExit", nullptr,
    std::make_unique<flutter::MethodResultFunctions<flutter::EncodableValue>>(
      [this](const auto* value) {
        exit_pending_ = false;
        const auto* allowed = value ? std::get_if<bool>(value) : nullptr;
        if (allowed && *allowed) PostMessage(GetHandle(), kExitMessage, 0, 0);
      },
      [this](const auto&, const auto&, const auto*) {
        exit_pending_ = false;
        MessageBoxW(GetHandle(), L"退出检查未完成，请先回到窗口保存文件后重试。", L"Aurora 3", MB_OK | MB_ICONWARNING);
      },
      [this]() {
        exit_pending_ = false;
        // Startup/store-error views may not have installed a Dart exit guard.
        // Do not silently kill an unresponsive UI or discard its state.
        if (MessageBoxW(GetHandle(), L"界面尚未完成退出检查。仍要结束 Aurora 3 吗？未保存的内容可能丢失。", L"Aurora 3", MB_YESNO | MB_DEFBUTTON2 | MB_ICONWARNING) == IDYES) {
          PostMessage(GetHandle(), kExitMessage, 0, 0);
        }
      }));
}
