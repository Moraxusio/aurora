// User-triggered clipboard reads only. No clipboard monitor, cookies or key files.
#include "ai_input.h"
#include <windows.h>
#include <shellapi.h>
#include <winhttp.h>
#include <wincodec.h>
#include <wrl/client.h>
#include <string>
#include <vector>
#include <stdexcept>

using flutter::EncodableValue;
using flutter::EncodableMap;
using flutter::EncodableList;
using Microsoft::WRL::ComPtr;
namespace {
constexpr size_t kLimit = 8 * 1024 * 1024;
std::string Utf8(const std::wstring& s) {
  if (s.empty()) return {};
  const int count = WideCharToMultiByte(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0, nullptr, nullptr);
  std::string out(count, '\0');
  WideCharToMultiByte(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), out.data(), count, nullptr, nullptr);
  return out;
}
void Check(HRESULT hr) { if (FAILED(hr)) throw std::runtime_error("Cannot encode clipboard image"); }
std::vector<uint8_t> BitmapPng(HBITMAP bitmap) {
  ComPtr<IWICImagingFactory> factory;
  Check(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)));
  ComPtr<IWICBitmap> image;
  Check(factory->CreateBitmapFromHBITMAP(bitmap, nullptr, WICBitmapIgnoreAlpha, &image));
  UINT w = 0, h = 0;
  Check(image->GetSize(&w, &h));
  if (w == 0 || h == 0 || static_cast<uint64_t>(w) * h > 40000000) throw std::runtime_error("Clipboard image is too large");
  ComPtr<IStream> stream;
  Check(CreateStreamOnHGlobal(nullptr, TRUE, &stream));
  ComPtr<IWICBitmapEncoder> encoder;
  Check(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder));
  Check(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache));
  ComPtr<IWICBitmapFrameEncode> frame;
  Check(encoder->CreateNewFrame(&frame, nullptr));
  Check(frame->Initialize(nullptr));
  Check(frame->SetSize(w, h));
  WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGR;
  Check(frame->SetPixelFormat(&format));
  Check(frame->WriteSource(image.Get(), nullptr));
  Check(frame->Commit());
  Check(encoder->Commit());
  STATSTG stat{};
  Check(stream->Stat(&stat, STATFLAG_NONAME));
  if (stat.cbSize.QuadPart > kLimit) throw std::runtime_error("Clipboard image exceeds 8 MiB");
  HGLOBAL global = nullptr;
  Check(GetHGlobalFromStream(stream.Get(), &global));
  const auto* bytes = static_cast<const uint8_t*>(GlobalLock(global));
  if (!bytes) throw std::runtime_error("Clipboard image unavailable");
  std::vector<uint8_t> out(bytes, bytes + static_cast<size_t>(stat.cbSize.QuadPart));
  GlobalUnlock(global);
  return out;
}
std::string Proxy() {
  WINHTTP_CURRENT_USER_IE_PROXY_CONFIG config{};
  if (!WinHttpGetIEProxyConfigForCurrentUser(&config)) return "DIRECT";
  std::wstring proxy = config.lpszProxy ? config.lpszProxy : L"";
  if (config.lpszProxy) GlobalFree(config.lpszProxy);
  if (config.lpszProxyBypass) GlobalFree(config.lpszProxyBypass);
  if (config.lpszAutoConfigUrl) GlobalFree(config.lpszAutoConfigUrl);
  // Manual HTTP(S) system proxies, including common local proxy applications.
  // PAC-only configurations are not interpreted or fetched here.
  if (proxy.find(L'=') != std::wstring::npos) {
    auto pos = proxy.find(L"https=");
    size_t prefix = 6;
    if (pos == std::wstring::npos) { pos = proxy.find(L"http="); prefix = 5; }
    if (pos == std::wstring::npos) return "DIRECT";
    proxy = proxy.substr(pos + prefix);
    proxy = proxy.substr(0, proxy.find(L';'));
  }
  if (proxy.rfind(L"http://", 0) == 0) proxy = proxy.substr(7);
  if (proxy.empty() || proxy.find(L'@') != std::wstring::npos || proxy.find(L"//") != std::wstring::npos) return "DIRECT";
  return "PROXY " + Utf8(proxy);
}
EncodableValue Clipboard() {
  if (!OpenClipboard(nullptr)) throw std::runtime_error("Clipboard is busy; retry paste");
  struct Close { ~Close() { CloseClipboard(); } } closer;
  if (auto drop = static_cast<HDROP>(GetClipboardData(CF_HDROP))) {
    const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
    if (count > 8) throw std::runtime_error("At most 8 files can be pasted at once");
    EncodableList paths;
    for (UINT i = 0; i < count; i++) {
      const UINT size = DragQueryFileW(drop, i, nullptr, 0);
      std::wstring path(size + 1, L'\0');
      DragQueryFileW(drop, i, path.data(), size + 1);
      path.resize(size);
      paths.emplace_back(Utf8(path));
    }
    return EncodableValue(EncodableMap{{EncodableValue("paths"), EncodableValue(paths)}});
  }
  const UINT png = RegisterClipboardFormatW(L"PNG");
  std::vector<uint8_t> data;
  if (auto handle = GetClipboardData(png)) {
    const SIZE_T size = GlobalSize(handle);
    if (size > kLimit) throw std::runtime_error("Clipboard image exceeds 8 MiB");
    const auto* bytes = static_cast<const uint8_t*>(GlobalLock(handle));
    if (bytes) { data.assign(bytes, bytes + size); GlobalUnlock(handle); }
  }
  if (data.empty()) {
    if (auto bitmap = static_cast<HBITMAP>(GetClipboardData(CF_BITMAP))) data = BitmapPng(bitmap);
  }
  if (!data.empty()) return EncodableValue(EncodableMap{
    {EncodableValue("bytes"), EncodableValue(data)},
    {EncodableValue("name"), EncodableValue("clipboard.png")},
  });
  return EncodableValue(EncodableMap{});
}
}
void HandleAiInput(const flutter::MethodCall<EncodableValue>& call,
                   std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  try {
    if (call.method_name() == "authProxy") result->Success(EncodableValue(Proxy()));
    else if (call.method_name() == "readClipboard") result->Success(Clipboard());
    else result->NotImplemented();
  } catch (const std::exception& error) { result->Error("input", error.what()); }
}
