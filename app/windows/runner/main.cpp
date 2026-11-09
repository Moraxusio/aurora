#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shobjidl.h>

#include "flutter_window.h"
#include "utils.h"
#include "desktop_instance.h"

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
  SetCurrentProcessExplicitAppUserModelID(L"Aurora.V3.Client");
  DesktopInstance instance_guard;
  if (!instance_guard.Valid()) {
    MessageBoxW(nullptr, L"无法创建 Aurora 3 的单实例锁，未启动客户端。", L"Aurora 3", MB_OK | MB_ICONERROR);
    ::CoUninitialize();
    return EXIT_FAILURE;
  }
  if (!instance_guard.IsPrimary()) {
    const bool restored = instance_guard.RestoreExisting();
    if (!restored) MessageBoxW(nullptr, L"Aurora 3 已在运行，但暂时没有响应。请稍后从托盘恢复。", L"Aurora 3", MB_OK | MB_ICONINFORMATION);
    ::CoUninitialize();
    return restored ? EXIT_SUCCESS : EXIT_FAILURE;
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, instance_guard);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1360, 860);
  if (!window.Create(L"Aurora 3", origin, size)) {
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
