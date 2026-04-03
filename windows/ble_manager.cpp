#include "ble_manager.h"

#include <objbase.h>

#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Devices.Bluetooth.Advertisement.h>
#include <winrt/Windows.Devices.Bluetooth.GenericAttributeProfile.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Storage.Streams.h>

#include <algorithm>
#include <iomanip>
#include <sstream>
#include <thread>

using namespace winrt;
using namespace Windows::Devices::Bluetooth;
using namespace Windows::Devices::Bluetooth::Advertisement;
using namespace Windows::Devices::Bluetooth::GenericAttributeProfile;
using namespace Windows::Foundation;
using namespace Windows::Storage::Streams;

namespace unified_esc_pos_printer {

// ── PlatformThreadDispatcher ─────────────────────────────────────────────

void PlatformThreadDispatcher::Initialize(HWND hwnd) {
  hwnd_ = hwnd;
  SetWindowSubclass(hwnd, SubclassProc, /*subclass_id=*/1,
                    reinterpret_cast<DWORD_PTR>(this));
}

void PlatformThreadDispatcher::Shutdown() {
  if (hwnd_) {
    RemoveWindowSubclass(hwnd_, SubclassProc, 1);
    hwnd_ = nullptr;
  }
}

void PlatformThreadDispatcher::Post(std::function<void()> callback) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    queue_.push(std::move(callback));
  }
  if (hwnd_) {
    PostMessage(hwnd_, kWmFlutterCallback, 0, 0);
  }
}

void PlatformThreadDispatcher::DrainQueue() {
  std::queue<std::function<void()>> local_queue;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    std::swap(local_queue, queue_);
  }
  while (!local_queue.empty()) {
    local_queue.front()();
    local_queue.pop();
  }
}

LRESULT CALLBACK PlatformThreadDispatcher::SubclassProc(
    HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam,
    UINT_PTR subclass_id, DWORD_PTR ref_data) {
  if (msg == kWmFlutterCallback) {
    auto* self = reinterpret_cast<PlatformThreadDispatcher*>(ref_data);
    self->DrainQueue();
    return 0;
  }
  return DefSubclassProc(hwnd, msg, wParam, lParam);
}

// ── Well-known ESC/POS BLE UUIDs ─────────────────────────────────────────

static const guid kEscPosServiceUuid{0x000018F0, 0x0000, 0x1000, {0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB}};
static const guid kEscPosTxCharUuid{0x00002AF1, 0x0000, 0x1000, {0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB}};

// ── BleManager ───────────────────────────────────────────────────────────

BleManager::BleManager() {
  winrt::init_apartment(winrt::apartment_type::single_threaded);
}

BleManager::~BleManager() {
  Dispose();
}

void BleManager::SetDispatcher(PlatformThreadDispatcher* dispatcher) {
  dispatcher_ = dispatcher;
}

std::unique_ptr<flutter::StreamHandler<flutter::EncodableValue>>
BleManager::CreateScanStreamHandler() {
  auto on_listen = [this](
      const flutter::EncodableValue* arguments,
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
      -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
    scan_event_sink_ = std::move(events);
    return nullptr;
  };
  auto on_cancel = [this](const flutter::EncodableValue* arguments)
      -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
    scan_event_sink_.reset();
    return nullptr;
  };
  return std::make_unique<
      flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
      on_listen, on_cancel);
}

// ── Scanning ─────────────────────────────────────────────────────────────

void BleManager::StartScan(
    int timeout_ms,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  StopScanInternal();

  {
    std::lock_guard<std::mutex> lock(scan_mutex_);
    discovered_devices_.clear();
    resolved_addresses_.clear();
  }

  watcher_ = BluetoothLEAdvertisementWatcher();
  watcher_.ScanningMode(BluetoothLEScanningMode::Active);

  watcher_received_token_ = watcher_.Received(
      [this](BluetoothLEAdvertisementWatcher const&,
             BluetoothLEAdvertisementReceivedEventArgs const& args) {
        auto address = args.BluetoothAddress();
        std::ostringstream oss;
        oss << std::hex << std::setfill('0');
        oss << std::setw(2) << ((address >> 40) & 0xFF) << ":"
            << std::setw(2) << ((address >> 32) & 0xFF) << ":"
            << std::setw(2) << ((address >> 24) & 0xFF) << ":"
            << std::setw(2) << ((address >> 16) & 0xFF) << ":"
            << std::setw(2) << ((address >> 8) & 0xFF) << ":"
            << std::setw(2) << (address & 0xFF);
        std::string device_id = oss.str();

        // Try to get name from advertisement data first.
        std::string name;
        auto local_name = args.Advertisement().LocalName();
        if (!local_name.empty()) {
          name = winrt::to_string(local_name);
        }

        // If no name in advertisement, resolve via BluetoothLEDevice (once
        // per address to avoid repeated lookups).
        if (name.empty()) {
          bool already_resolved = false;
          {
            std::lock_guard<std::mutex> lock(scan_mutex_);
            already_resolved = resolved_addresses_.count(address) > 0;
            resolved_addresses_.insert(address);
          }
          if (!already_resolved) {
            try {
              auto ble_device = BluetoothLEDevice::FromBluetoothAddressAsync(address).get();
              if (ble_device != nullptr) {
                auto friendly_name = ble_device.Name();
                if (!friendly_name.empty()) {
                  name = winrt::to_string(friendly_name);
                }
                ble_device.Close();
              }
            } catch (...) {
              // Fall through — use MAC address as name.
            }
          }
          if (name.empty()) {
            name = device_id;
          }
        }

        std::lock_guard<std::mutex> lock(scan_mutex_);
        bool exists = std::any_of(
            discovered_devices_.begin(), discovered_devices_.end(),
            [&device_id](const flutter::EncodableMap& m) {
              auto it = m.find(flutter::EncodableValue("deviceId"));
              return it != m.end() &&
                     std::get<std::string>(it->second) == device_id;
            });

        if (!exists) {
          flutter::EncodableMap device_map;
          device_map[flutter::EncodableValue("deviceId")] =
              flutter::EncodableValue(device_id);
          device_map[flutter::EncodableValue("name")] =
              flutter::EncodableValue(name);
          discovered_devices_.push_back(device_map);

          if (scan_event_sink_ && dispatcher_) {
            flutter::EncodableList list;
            for (const auto& d : discovered_devices_) {
              list.push_back(flutter::EncodableValue(d));
            }
            auto value = flutter::EncodableValue(list);
            dispatcher_->Post([this, value = std::move(value)]() {
              if (scan_event_sink_) {
                scan_event_sink_->Success(value);
              }
            });
          }
        }
      });

  watcher_.Start();

  // Auto-stop after timeout
  std::thread([this, timeout_ms]() {
    std::this_thread::sleep_for(std::chrono::milliseconds(timeout_ms));
    StopScanInternal();
  }).detach();

  result->Success(flutter::EncodableValue());
}

void BleManager::StopScan(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  StopScanInternal();
  result->Success(flutter::EncodableValue());
}

void BleManager::StopScanInternal() {
  if (watcher_ != nullptr) {
    try {
      watcher_.Stop();
      watcher_.Received(watcher_received_token_);
    } catch (...) {}
    watcher_ = nullptr;
  }
}

// ── Connection ───────────────────────────────────────────────────────────

guid BleManager::ParseUuid(const std::string& uuid_str) {
  // Parse a UUID string like "000018f0-0000-1000-8000-00805f9b34fb"
  GUID g;
  std::wstring wide(uuid_str.begin(), uuid_str.end());
  std::wstring braced = L"{" + wide + L"}";
  CLSIDFromString(braced.c_str(), &g);
  return winrt::guid(g);
}

void BleManager::Connect(
    const std::string& device_id, int timeout_ms,
    const std::string* service_uuid, const std::string* characteristic_uuid,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {

  auto target_svc = service_uuid ? ParseUuid(*service_uuid) : kEscPosServiceUuid;
  auto target_char = characteristic_uuid ? ParseUuid(*characteristic_uuid) : kEscPosTxCharUuid;

  // Parse MAC address to uint64
  uint64_t bt_address = 0;
  std::istringstream iss(device_id);
  std::string byte_str;
  while (std::getline(iss, byte_str, ':')) {
    bt_address = (bt_address << 8) | std::stoul(byte_str, nullptr, 16);
  }

  // Clean up any existing connection for this device
  CleanupConnection(device_id);

  // Run connection on a background thread (WinRT async)
  auto shared_result = std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
      result.release());

  std::thread([this, device_id, bt_address, target_svc, target_char, timeout_ms, shared_result]() {
    try {
      auto device = BluetoothLEDevice::FromBluetoothAddressAsync(bt_address).get();
      if (device == nullptr) {
        dispatcher_->Post([shared_result]() {
          shared_result->Error("NOT_FOUND", "BLE device not found");
        });
        return;
      }

      // Monitor connection status
      auto connection_status_token = device.ConnectionStatusChanged(
          [this, device_id](BluetoothLEDevice const& dev, auto const&) {
            if (dev.ConnectionStatus() == BluetoothConnectionStatus::Disconnected) {
              CleanupConnection(device_id);
              if (dispatcher_ && connection_state_callback) {
                dispatcher_->Post([this, device_id]() {
                  if (connection_state_callback) {
                    connection_state_callback(device_id, "disconnected");
                  }
                });
              }
            }
          });

      // Open GATT session for MTU
      auto ble_device_id = device.BluetoothDeviceId();
      auto gatt_session = GattSession::FromDeviceIdAsync(ble_device_id).get();
      gatt_session.MaintainConnection(true);
      int mtu_payload = static_cast<int>(gatt_session.MaxPduSize()) - 3;
      if (mtu_payload < 20) mtu_payload = 20;

      // Discover services
      auto services_result = device.GetGattServicesAsync().get();
      if (services_result.Status() != GattCommunicationStatus::Success) {
        dispatcher_->Post([shared_result]() {
          shared_result->Error("SERVICE_DISCOVERY_FAILED", "Failed to discover GATT services");
        });
        return;
      }

      GattCharacteristic found_char{nullptr};

      // 1. Try target service/characteristic
      for (auto const& svc : services_result.Services()) {
        if (svc.Uuid() == target_svc) {
          auto chars_result = svc.GetCharacteristicsAsync().get();
          if (chars_result.Status() == GattCommunicationStatus::Success) {
            for (auto const& c : chars_result.Characteristics()) {
              if (c.Uuid() == target_char) {
                auto props = c.CharacteristicProperties();
                if ((props & GattCharacteristicProperties::Write) ==
                        GattCharacteristicProperties::Write ||
                    (props & GattCharacteristicProperties::WriteWithoutResponse) ==
                        GattCharacteristicProperties::WriteWithoutResponse) {
                  found_char = c;
                  break;
                }
              }
            }
          }
        }
        if (found_char != nullptr) break;
      }

      // 2. Fallback: any writable characteristic
      if (found_char == nullptr) {
        for (auto const& svc : services_result.Services()) {
          auto chars_result = svc.GetCharacteristicsAsync().get();
          if (chars_result.Status() == GattCommunicationStatus::Success) {
            for (auto const& c : chars_result.Characteristics()) {
              auto props = c.CharacteristicProperties();
              if ((props & GattCharacteristicProperties::Write) ==
                      GattCharacteristicProperties::Write ||
                  (props & GattCharacteristicProperties::WriteWithoutResponse) ==
                      GattCharacteristicProperties::WriteWithoutResponse) {
                found_char = c;
                break;
              }
            }
          }
          if (found_char != nullptr) break;
        }
      }

      if (found_char == nullptr) {
        dispatcher_->Post([shared_result]() {
          shared_result->Error("NO_CHARACTERISTIC", "No writable characteristic found");
        });
        return;
      }

      auto props = found_char.CharacteristicProperties();
      bool has_write =
          (props & GattCharacteristicProperties::Write) ==
          GattCharacteristicProperties::Write;
      bool has_write_no_resp =
          (props & GattCharacteristicProperties::WriteWithoutResponse) ==
          GattCharacteristicProperties::WriteWithoutResponse;
      bool write_without_response = !has_write && has_write_no_resp;

      // Store per-device connection state
      {
        std::lock_guard<std::mutex> lock(connection_mutex_);
        DeviceConnection conn;
        conn.device = device;
        conn.tx_characteristic = found_char;
        conn.gatt_session = gatt_session;
        conn.mtu_payload = mtu_payload;
        conn.write_without_response = write_without_response;
        conn.connection_status_token = connection_status_token;
        connections_[device_id] = conn;
      }

      dispatcher_->Post([this, device_id, shared_result]() {
        shared_result->Success(flutter::EncodableValue());
        if (connection_state_callback) {
          connection_state_callback(device_id, "connected");
        }
      });
    } catch (const winrt::hresult_error& e) {
      auto msg = winrt::to_string(e.message());
      dispatcher_->Post([shared_result, msg]() {
        shared_result->Error("CONNECTION_FAILED", msg);
      });
    } catch (const std::exception& e) {
      std::string msg = e.what();
      dispatcher_->Post([shared_result, msg]() {
        shared_result->Error("CONNECTION_FAILED", msg);
      });
    }
  }).detach();
}

// ── MTU & Characteristic Info ────────────────────────────────────────────

void BleManager::GetMtu(
    const std::string& device_id,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  std::lock_guard<std::mutex> lock(connection_mutex_);
  auto it = connections_.find(device_id);
  int mtu = (it != connections_.end()) ? it->second.mtu_payload : 20;
  result->Success(flutter::EncodableValue(mtu));
}

void BleManager::SupportsWriteWithoutResponse(
    const std::string& device_id,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  std::lock_guard<std::mutex> lock(connection_mutex_);
  auto it = connections_.find(device_id);
  bool val = (it != connections_.end()) ? it->second.write_without_response : false;
  result->Success(flutter::EncodableValue(val));
}

// ── Writing ──────────────────────────────────────────────────────────────

void BleManager::Write(
    const std::string& device_id,
    const std::vector<uint8_t>& data, bool without_response,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  GattCharacteristic char_copy{nullptr};
  {
    std::lock_guard<std::mutex> lock(connection_mutex_);
    auto it = connections_.find(device_id);
    if (it == connections_.end() || it->second.tx_characteristic == nullptr) {
      result->Error("NOT_CONNECTED", "BLE device not connected: " + device_id);
      return;
    }
    char_copy = it->second.tx_characteristic;
  }

  auto shared_result = std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
      result.release());

  std::thread([this, data, without_response, shared_result, char_copy]() {
    try {
      DataWriter writer;
      writer.WriteBytes(
          winrt::array_view<const uint8_t>(data.data(), static_cast<uint32_t>(data.size())));
      auto buffer = writer.DetachBuffer();

      auto write_option = without_response
          ? GattWriteOption::WriteWithoutResponse
          : GattWriteOption::WriteWithResponse;

      auto status = char_copy.WriteValueAsync(buffer, write_option).get();
      if (status == GattCommunicationStatus::Success) {
        dispatcher_->Post([shared_result]() {
          shared_result->Success(flutter::EncodableValue());
        });
      } else {
        dispatcher_->Post([shared_result]() {
          shared_result->Error("WRITE_FAILED", "GATT write failed");
        });
      }
    } catch (const winrt::hresult_error& e) {
      auto msg = winrt::to_string(e.message());
      dispatcher_->Post([shared_result, msg]() {
        shared_result->Error("WRITE_FAILED", msg);
      });
    } catch (const std::exception& e) {
      std::string msg = e.what();
      dispatcher_->Post([shared_result, msg]() {
        shared_result->Error("WRITE_FAILED", msg);
      });
    }
  }).detach();
}

// ── Disconnection ────────────────────────────────────────────────────────

void BleManager::Disconnect(
    const std::string& device_id,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  CleanupConnection(device_id);
  if (connection_state_callback) {
    connection_state_callback(device_id, "disconnected");
  }
  result->Success(flutter::EncodableValue());
}

void BleManager::Dispose() {
  StopScanInternal();

  std::vector<std::string> device_ids;
  {
    std::lock_guard<std::mutex> lock(connection_mutex_);
    for (const auto& pair : connections_) {
      device_ids.push_back(pair.first);
    }
  }
  for (const auto& id : device_ids) {
    CleanupConnection(id);
  }
}

void BleManager::CleanupConnection(const std::string& device_id) {
  std::lock_guard<std::mutex> lock(connection_mutex_);
  auto it = connections_.find(device_id);
  if (it == connections_.end()) return;

  auto& conn = it->second;
  conn.tx_characteristic = nullptr;
  if (conn.gatt_session != nullptr) {
    try { conn.gatt_session.Close(); } catch (...) {}
    conn.gatt_session = nullptr;
  }
  if (conn.device != nullptr) {
    try {
      conn.device.ConnectionStatusChanged(conn.connection_status_token);
      conn.device.Close();
    } catch (...) {}
    conn.device = nullptr;
  }
  connections_.erase(it);
}

}  // namespace unified_esc_pos_printer
