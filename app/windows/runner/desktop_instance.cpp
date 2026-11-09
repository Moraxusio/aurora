#include "desktop_instance.h"

#include <sddl.h>
#include <vector>

namespace {
std::wstring UserSID() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return {};
  DWORD size = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &size);
  std::vector<BYTE> buffer(size);
  if (!GetTokenInformation(token, TokenUser, buffer.data(), size, &size)) {
    CloseHandle(token);
    return {};
  }
  CloseHandle(token);
  LPWSTR text = nullptr;
  if (!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(buffer.data())->User.Sid, &text)) return {};
  const std::wstring result(text);
  LocalFree(text);
  return result;
}

struct Search { const DesktopInstance* instance; HWND found; };
BOOL CALLBACK FindInstance(HWND window, LPARAM param) {
  auto* search = reinterpret_cast<Search*>(param);
  if (GetPropW(window, search->instance->property().c_str())) {
    search->found = window;
    return FALSE;
  }
  return TRUE;
}
}  // namespace

DesktopInstance::DesktopInstance() {
  const auto sid = UserSID();
  if (sid.empty()) return;
  wchar_t scope[80]{};
  const DWORD count = GetEnvironmentVariableW(L"AURORA3_INSTANCE_SCOPE", scope, 80);
  std::wstring channel = L"default";
  if (count > 0 && count < 80) {
    channel.clear();
    for (DWORD i = 0; i < count; ++i) {
      const wchar_t c = scope[i];
      if ((c >= L'a' && c <= L'z') || (c >= L'A' && c <= L'Z') || (c >= L'0' && c <= L'9') || c == L'-') channel += c;
    }
    if (channel.empty()) channel = L"default";
  }
  property_ = L"Aurora3.Client." + sid + L"." + channel;
  restore_message_ = RegisterWindowMessageW((property_ + L".Restore").c_str());
  mutex_ = CreateMutexW(nullptr, FALSE, (L"Local\\" + property_).c_str());
  primary_ = mutex_ != nullptr && GetLastError() != ERROR_ALREADY_EXISTS;
}

DesktopInstance::~DesktopInstance() {
  if (mutex_) CloseHandle(mutex_);
}

bool DesktopInstance::MarkWindow(HWND window) const {
  return SetPropW(window, property_.c_str(), reinterpret_cast<HANDLE>(1)) != FALSE;
}

bool DesktopInstance::RestoreExisting() const {
  // A second launch may arrive while the first process is still loading the
  // engine. Bound the wait; never start a duplicate after a failed handoff.
  for (int i = 0; i < 100; ++i) {
    Search search{this, nullptr};
    EnumWindows(FindInstance, reinterpret_cast<LPARAM>(&search));
    if (search.found) {
      DWORD process = 0;
      GetWindowThreadProcessId(search.found, &process);
      AllowSetForegroundWindow(process);
      return PostMessageW(search.found, restore_message_, 0, 0) != FALSE;
    }
    Sleep(100);
  }
  return false;
}
