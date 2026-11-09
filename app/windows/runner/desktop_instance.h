#ifndef RUNNER_DESKTOP_INSTANCE_H_
#define RUNNER_DESKTOP_INSTANCE_H_

#include <windows.h>
#include <string>

// Current-user/current-session product singleton. v2's names are never used.
// Tests set AURORA3_INSTANCE_SCOPE so smoke tests cannot activate the user's
// release instance. This is not a system service or a crash restart watchdog.
class DesktopInstance {
 public:
  DesktopInstance();
  ~DesktopInstance();
  bool IsPrimary() const { return primary_; }
  bool Valid() const { return mutex_ != nullptr && restore_message_ != 0; }
  bool RestoreExisting() const;
  bool MarkWindow(HWND window) const;
  const std::wstring& property() const { return property_; }
  UINT restore_message() const { return restore_message_; }

 private:
  HANDLE mutex_ = nullptr;
  bool primary_ = false;
  std::wstring property_;
  UINT restore_message_ = 0;
};

#endif
