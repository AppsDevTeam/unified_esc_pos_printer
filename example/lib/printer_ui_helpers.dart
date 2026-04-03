import 'package:flutter/material.dart';
import 'package:unified_esc_pos_printer/unified_esc_pos_printer.dart';

/// Icon for a given [PrinterDevice] type.
IconData iconForDevice(PrinterDevice device) {
  return switch (device) {
    NetworkPrinterDevice() => Icons.wifi,
    BlePrinterDevice() => Icons.bluetooth,
    BluetoothPrinterDevice() => Icons.bluetooth_audio,
    UsbPrinterDevice() => Icons.usb,
    _ => Icons.print,
  };
}

/// Human-readable subtitle for a [PrinterDevice].
String subtitleForDevice(PrinterDevice device) {
  return switch (device) {
    NetworkPrinterDevice(host: final h, port: final p) => 'TCP $h:$p',
    BlePrinterDevice(deviceId: final id) => 'BLE $id',
    BluetoothPrinterDevice(address: final addr) => 'BT $addr',
    UsbPrinterDevice(identifier: final id) => 'USB $id',
    _ => device.connectionType.name,
  };
}

/// Human-readable label for a [PrinterConnectionType] filter.
String filterLabel(PrinterConnectionType? filter) {
  if (filter == null) return 'All';
  return switch (filter) {
    PrinterConnectionType.network => 'Network',
    PrinterConnectionType.ble => 'BLE',
    PrinterConnectionType.bluetooth => 'Bluetooth',
    PrinterConnectionType.usb => 'USB',
  };
}

/// Icon for a [PrinterConnectionType] filter.
IconData filterIcon(PrinterConnectionType? filter) {
  if (filter == null) return Icons.select_all;
  return switch (filter) {
    PrinterConnectionType.network => Icons.wifi,
    PrinterConnectionType.ble => Icons.bluetooth,
    PrinterConnectionType.bluetooth => Icons.bluetooth_audio,
    PrinterConnectionType.usb => Icons.usb,
  };
}

/// Unique key for deduplicating [PrinterDevice] instances.
String deviceKey(PrinterDevice device) {
  return switch (device) {
    NetworkPrinterDevice(host: final h, port: final p) => 'net:$h:$p',
    BlePrinterDevice(deviceId: final id) => 'ble:$id',
    BluetoothPrinterDevice(address: final addr) => 'bt:$addr',
    UsbPrinterDevice(identifier: final id) => 'usb:$id',
    _ => 'unknown:${device.name}',
  };
}

/// Filter chip used in scan type selection rows.
class ScanFilterChip extends StatelessWidget {
  const ScanFilterChip({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        showCheckmark: false,
        avatar: Icon(icon, size: 18),
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
      ),
    );
  }
}
