#ifndef BT_CLASSIC_MANAGER_H_
#define BT_CLASSIC_MANAGER_H_

#include "ble_manager.h"  // for PlatformThreadDispatcher

#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Devices.Bluetooth.Rfcomm.h>
#include <winrt/Windows.Devices.Enumeration.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Networking.Sockets.h>
#include <winrt/Windows.Storage.Streams.h>

#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace unified_esc_pos_printer {

class BtClassicManager {
 public:
  BtClassicManager();
  ~BtClassicManager();

  void SetDispatcher(PlatformThreadDispatcher* dispatcher);

  // Stream handler for the bt_scan EventChannel.
  std::unique_ptr<flutter::StreamHandler<flutter::EncodableValue>>
      CreateDiscoveryStreamHandler();

  void GetBondedDevices(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void StartDiscovery(
      int timeout_ms,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void StopDiscovery(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void Connect(
      const std::string& address, int timeout_ms,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void Write(
      const std::string& address,
      const std::vector<uint8_t>& data,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void Disconnect(
      const std::string& address,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void Dispose();

  // Callback receives (address, state).
  std::function<void(const std::string&, const std::string&)> connection_state_callback;

 private:
  static std::string FormatAddress(uint64_t address);
  static uint64_t ParseAddress(const std::string& address_str);
  void StopDiscoveryInternal();
  void CleanupConnection(const std::string& address);

  PlatformThreadDispatcher* dispatcher_ = nullptr;

  // Discovery state
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> discovery_sink_;
  winrt::Windows::Devices::Enumeration::DeviceWatcher watcher_{nullptr};
  winrt::event_token watcher_added_token_;
  winrt::event_token watcher_completed_token_;
  winrt::event_token watcher_stopped_token_;
  std::vector<flutter::EncodableMap> discovered_devices_;
  std::mutex discovery_mutex_;

  // Per-device connection state
  std::mutex connection_mutex_;
  std::unordered_map<std::string, winrt::Windows::Networking::Sockets::StreamSocket> sockets_;
  std::unordered_map<std::string, winrt::Windows::Storage::Streams::DataWriter> writers_;
  std::unordered_map<std::string, std::atomic<bool>*> disconnect_monitors_;
};

}  // namespace unified_esc_pos_printer

#endif  // BT_CLASSIC_MANAGER_H_
