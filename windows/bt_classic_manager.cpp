#include "bt_classic_manager.h"

#include <iomanip>
#include <sstream>
#include <thread>

using namespace winrt;
using namespace Windows::Devices::Bluetooth;
using namespace Windows::Devices::Bluetooth::Rfcomm;
using namespace Windows::Devices::Enumeration;
using namespace Windows::Foundation;
using namespace Windows::Networking::Sockets;
using namespace Windows::Storage::Streams;

namespace unified_esc_pos_printer {

// ── Helpers ──────────────────────────────────────────────────────────────

std::string BtClassicManager::FormatAddress(uint64_t address) {
  std::ostringstream oss;
  oss << std::hex << std::setfill('0');
  oss << std::setw(2) << ((address >> 40) & 0xFF) << ":"
      << std::setw(2) << ((address >> 32) & 0xFF) << ":"
      << std::setw(2) << ((address >> 24) & 0xFF) << ":"
      << std::setw(2) << ((address >> 16) & 0xFF) << ":"
      << std::setw(2) << ((address >> 8) & 0xFF) << ":"
      << std::setw(2) << (address & 0xFF);
  return oss.str();
}

uint64_t BtClassicManager::ParseAddress(const std::string& address_str) {
  uint64_t result = 0;
  std::istringstream iss(address_str);
  std::string byte_str;
  while (std::getline(iss, byte_str, ':')) {
    result = (result << 8) | std::stoul(byte_str, nullptr, 16);
  }
  return result;
}

// ── BtClassicManager ─────────────────────────────────────────────────────

BtClassicManager::BtClassicManager() {}

BtClassicManager::~BtClassicManager() {
  Dispose();
}

void BtClassicManager::SetDispatcher(PlatformThreadDispatcher* dispatcher) {
  dispatcher_ = dispatcher;
}

std::unique_ptr<flutter::StreamHandler<flutter::EncodableValue>>
BtClassicManager::CreateDiscoveryStreamHandler() {
  auto on_listen = [this](
      const flutter::EncodableValue*,
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
      -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
    discovery_sink_ = std::move(events);
    return nullptr;
  };
  auto on_cancel = [this](const flutter::EncodableValue*)
      -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
    discovery_sink_.reset();
    return nullptr;
  };
  return std::make_unique<
      flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
      on_listen, on_cancel);
}

// ── GetBondedDevices ─────────────────────────────────────────────────────

void BtClassicManager::GetBondedDevices(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  auto shared_result =
      std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
          result.release());

  std::thread([this, shared_result]() {
    try {
      // Query paired Bluetooth Classic devices.
      auto selector = BluetoothDevice::GetDeviceSelectorFromPairingState(true);
      auto devices = DeviceInformation::FindAllAsync(selector).get();

      flutter::EncodableList list;
      for (const auto& dev_info : devices) {
        try {
          auto bt_device = BluetoothDevice::FromIdAsync(dev_info.Id()).get();
          if (bt_device == nullptr) continue;

          flutter::EncodableMap m;
          m[flutter::EncodableValue("name")] =
              flutter::EncodableValue(winrt::to_string(bt_device.Name()));
          m[flutter::EncodableValue("address")] =
              flutter::EncodableValue(FormatAddress(bt_device.BluetoothAddress()));
          list.push_back(flutter::EncodableValue(m));
        } catch (...) {
          // Skip devices that can't be resolved.
        }
      }

      dispatcher_->Post([shared_result, list = std::move(list)]() {
        shared_result->Success(flutter::EncodableValue(list));
      });
    } catch (const winrt::hresult_error& e) {
      auto msg = winrt::to_string(e.message());
      dispatcher_->Post([shared_result, msg]() {
        shared_result->Error("BT_BONDED_FAILED", msg);
      });
    } catch (const std::exception& e) {
      std::string msg = e.what();
      dispatcher_->Post([shared_result, msg]() {
        shared_result->Error("BT_BONDED_FAILED", msg);
      });
    }
  }).detach();
}

// ── Discovery ────────────────────────────────────────────────────────────

void BtClassicManager::StartDiscovery(
    int timeout_ms,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  StopDiscoveryInternal();

  {
    std::lock_guard<std::mutex> lock(discovery_mutex_);
    discovered_devices_.clear();
  }

  // Watch for unpaired BT Classic devices.
  auto selector = BluetoothDevice::GetDeviceSelectorFromPairingState(false);
  watcher_ = DeviceInformation::CreateWatcher(selector);

  watcher_added_token_ = watcher_.Added(
      [this](DeviceWatcher const&, DeviceInformation const& dev_info) {
        try {
          auto bt_device = BluetoothDevice::FromIdAsync(dev_info.Id()).get();
          if (bt_device == nullptr) return;

          std::string name = winrt::to_string(bt_device.Name());
          std::string address = FormatAddress(bt_device.BluetoothAddress());
          if (name.empty()) name = address;

          std::lock_guard<std::mutex> lock(discovery_mutex_);
          bool exists = std::any_of(
              discovered_devices_.begin(), discovered_devices_.end(),
              [&address](const flutter::EncodableMap& m) {
                auto it = m.find(flutter::EncodableValue("address"));
                return it != m.end() &&
                       std::get<std::string>(it->second) == address;
              });

          if (!exists) {
            flutter::EncodableMap device_map;
            device_map[flutter::EncodableValue("name")] =
                flutter::EncodableValue(name);
            device_map[flutter::EncodableValue("address")] =
                flutter::EncodableValue(address);
            discovered_devices_.push_back(device_map);

            if (discovery_sink_ && dispatcher_) {
              flutter::EncodableList list;
              for (const auto& d : discovered_devices_) {
                list.push_back(flutter::EncodableValue(d));
              }
              auto value = flutter::EncodableValue(list);
              dispatcher_->Post([this, value = std::move(value)]() {
                if (discovery_sink_) {
                  discovery_sink_->Success(value);
                }
              });
            }
          }
        } catch (...) {
          // Skip unresolvable devices.
        }
      });

  watcher_.Start();

  // Auto-stop after timeout.
  std::thread([this, timeout_ms]() {
    std::this_thread::sleep_for(std::chrono::milliseconds(timeout_ms));
    StopDiscoveryInternal();
  }).detach();

  result->Success(flutter::EncodableValue());
}

void BtClassicManager::StopDiscovery(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  StopDiscoveryInternal();
  result->Success(flutter::EncodableValue());
}

void BtClassicManager::StopDiscoveryInternal() {
  if (watcher_ != nullptr) {
    try {
      auto status = watcher_.Status();
      if (status == DeviceWatcherStatus::Started ||
          status == DeviceWatcherStatus::EnumerationCompleted) {
        watcher_.Stop();
      }
    } catch (...) {}
    watcher_ = nullptr;
  }
}

// ── Connection ───────────────────────────────────────────────────────────

void BtClassicManager::Connect(
    const std::string& address, int timeout_ms,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  uint64_t bt_address = ParseAddress(address);

  // Clean up any existing connection for this address
  CleanupConnection(address);

  auto shared_result =
      std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
          result.release());

  std::thread([this, address, bt_address, shared_result]() {
    try {
      auto device = BluetoothDevice::FromBluetoothAddressAsync(bt_address).get();
      if (device == nullptr) {
        dispatcher_->Post([shared_result]() {
          shared_result->Error("NOT_FOUND", "Bluetooth device not found");
        });
        return;
      }

      // Look for SPP (Serial Port Profile) service.
      auto rfcomm_result =
          device.GetRfcommServicesForIdAsync(RfcommServiceId::SerialPort()).get();

      if (rfcomm_result.Error() != BluetoothError::Success ||
          rfcomm_result.Services().Size() == 0) {
        dispatcher_->Post([shared_result]() {
          shared_result->Error("NO_SPP_SERVICE",
                               "Device does not expose SPP service");
        });
        return;
      }

      auto service = rfcomm_result.Services().GetAt(0);

      // Create RFCOMM socket and connect.
      StreamSocket socket;
      socket.ConnectAsync(
          service.ConnectionHostName(),
          service.ConnectionServiceName(),
          SocketProtectionLevel::BluetoothEncryptionAllowNullAuthentication)
          .get();

      auto writer = DataWriter(socket.OutputStream());

      {
        std::lock_guard<std::mutex> lock(connection_mutex_);
        sockets_[address] = socket;
        writers_[address] = writer;
      }

      // Spawn disconnect monitor thread.
      auto* monitor_flag = new std::atomic<bool>(true);
      {
        std::lock_guard<std::mutex> lock(connection_mutex_);
        disconnect_monitors_[address] = monitor_flag;
      }

      std::thread([this, address, socket, monitor_flag]() {
        try {
          auto reader = DataReader(socket.InputStream());
          reader.InputStreamOptions(InputStreamOptions::Partial);
          while (monitor_flag->load()) {
            // Attempt to read — blocks until data or disconnect.
            auto loaded = reader.LoadAsync(1).get();
            if (loaded == 0) break;
            // Discard any incoming data (printers rarely send data).
          }
        } catch (...) {
          // Socket closed or error.
        }

        if (monitor_flag->load()) {
          monitor_flag->store(false);
          CleanupConnection(address);
          if (dispatcher_ && connection_state_callback) {
            dispatcher_->Post([this, address]() {
              if (connection_state_callback) {
                connection_state_callback(address, "disconnected");
              }
            });
          }
        }
      }).detach();

      dispatcher_->Post([this, address, shared_result]() {
        shared_result->Success(flutter::EncodableValue());
        if (connection_state_callback) {
          connection_state_callback(address, "connected");
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

// ── Writing ──────────────────────────────────────────────────────────────

void BtClassicManager::Write(
    const std::string& address,
    const std::vector<uint8_t>& data,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  DataWriter writer_copy{nullptr};
  {
    std::lock_guard<std::mutex> lock(connection_mutex_);
    auto it = writers_.find(address);
    if (it == writers_.end() || it->second == nullptr) {
      result->Error("NOT_CONNECTED",
                     "Bluetooth Classic not connected to " + address);
      return;
    }
    writer_copy = it->second;
  }

  auto shared_result =
      std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
          result.release());

  std::thread([this, data, shared_result, writer_copy]() {
    try {
      writer_copy.WriteBytes(
          winrt::array_view<const uint8_t>(
              data.data(), static_cast<uint32_t>(data.size())));
      writer_copy.StoreAsync().get();
      writer_copy.FlushAsync().get();

      dispatcher_->Post([shared_result]() {
        shared_result->Success(flutter::EncodableValue());
      });
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

void BtClassicManager::Disconnect(
    const std::string& address,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  CleanupConnection(address);
  if (connection_state_callback) {
    connection_state_callback(address, "disconnected");
  }
  result->Success(flutter::EncodableValue());
}

void BtClassicManager::Dispose() {
  StopDiscoveryInternal();

  std::vector<std::string> addresses;
  {
    std::lock_guard<std::mutex> lock(connection_mutex_);
    for (const auto& pair : sockets_) {
      addresses.push_back(pair.first);
    }
  }
  // CleanupConnection acquires the lock itself, so call outside the lock.
  for (const auto& addr : addresses) {
    CleanupConnection(addr);
  }
}

void BtClassicManager::CleanupConnection(const std::string& address) {
  std::lock_guard<std::mutex> lock(connection_mutex_);

  // Stop disconnect monitor
  auto monitor_it = disconnect_monitors_.find(address);
  if (monitor_it != disconnect_monitors_.end()) {
    monitor_it->second->store(false);
    delete monitor_it->second;
    disconnect_monitors_.erase(monitor_it);
  }

  // Close writer
  auto writer_it = writers_.find(address);
  if (writer_it != writers_.end()) {
    try { writer_it->second.Close(); } catch (...) {}
    writers_.erase(writer_it);
  }

  // Close socket
  auto socket_it = sockets_.find(address);
  if (socket_it != sockets_.end()) {
    try { socket_it->second.Close(); } catch (...) {}
    sockets_.erase(socket_it);
  }
}

}  // namespace unified_esc_pos_printer
