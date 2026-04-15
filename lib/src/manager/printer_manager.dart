import 'dart:async';

import '../connectors/ble_connector.dart';
import '../connectors/bluetooth_connector.dart';
import '../connectors/network_connector.dart';
import '../connectors/printer_connector.dart';
import '../connectors/usb/usb_connector.dart';
import '../core/commands.dart';
import '../core/enums.dart';
import '../core/ticket.dart';
import '../exceptions/printer_exception.dart';
import '../models/printer_connection_state.dart';
import '../models/printer_device.dart';
import '../models/printer_status.dart';
import '../utils/printer_log_level.dart';
import '../utils/printer_logger.dart';

const String _tag = 'Manager';

/// Unified facade for all ESC/POS printer operations.
///
/// Transparently delegates to the correct [PrinterConnector] based on the
/// runtime type of the [PrinterDevice] selected.
///
/// **Minimal usage:**
/// ```dart
/// final manager = PrinterManager();
/// final printers = await manager.scanPrinters();
/// await manager.connect(printers.first);
/// final ticket = Ticket(PaperSize.mm80, await CapabilityProfile.load());
/// ticket.text('Hello!');
/// ticket.cut();
/// await manager.printTicket(ticket);
/// await manager.openCashDrawer();
/// await manager.disconnect();
/// await manager.dispose();
/// ```
class PrinterManager {
  PrinterManager({
    PrinterLogLevel logLevel = PrinterLogLevel.none,
    void Function(PrinterLogLevel level, String tag, String message)? onLog,
    NetworkConnector? networkConnector,
    BleConnector? bleConnector,
    BluetoothConnector? bluetoothConnector,
    UsbConnector? usbConnector,
  })  : _network = networkConnector ?? NetworkConnector(),
        _ble = bleConnector ?? BleConnector(),
        _bluetooth = bluetoothConnector ?? BluetoothConnector(),
        _usb = usbConnector ?? UsbConnector() {
    PrinterLogger.configure(level: logLevel, onLog: onLog);
  }

  final NetworkConnector _network;
  final BleConnector _ble;
  final BluetoothConnector _bluetooth;
  final UsbConnector _usb;

  PrinterConnector<PrinterDevice>? _active;
  PrinterDevice? _activeDevice;
  StreamSubscription<PrinterConnectionState>? _activeStateSub;
  final StreamController<PrinterConnectionState> _stateController =
      StreamController<PrinterConnectionState>.broadcast();

  /// Active scan subscriptions created by [scanAll], tracked so
  /// [stopAllScans] can cancel them.
  final List<StreamSubscription<dynamic>> _scanSubscriptions = [];
  StreamController<List<PrinterDevice>>? _scanController;

  /// Scan for all printer types simultaneously, returning a merged stream.
  ///
  /// Each emission is the latest accumulated list for each connector type;
  /// the stream closes when all enabled scans have finished or [timeout]
  /// elapses.
  ///
  /// Filter by [types] to limit which connection types are scanned.
  Stream<List<PrinterDevice>> scanAll({
    Duration timeout = const Duration(seconds: 5),
    Set<PrinterConnectionType> types = const {
      PrinterConnectionType.network,
      PrinterConnectionType.ble,
      PrinterConnectionType.bluetooth,
      PrinterConnectionType.usb,
    },
  }) {
    // Drop connection types that are not supported on the current platform.
    final Set<PrinterConnectionType> unsupported =
        types.where((PrinterConnectionType t) => !t.isSupportedOnCurrentPlatform).toSet();
    if (unsupported.isNotEmpty) {
      PrinterLogger.warning(
        _tag,
        'Skipping unsupported connection types on this platform: $unsupported',
      );
    }
    final Set<PrinterConnectionType> supported = types.difference(unsupported);

    PrinterLogger.info(_tag, 'Starting scan for types: $supported');

    // Cancel any previous scan that is still in progress.
    _stopScansSync();

    final StreamController<List<PrinterDevice>> controller =
        StreamController<List<PrinterDevice>>();
    _scanController = controller;

    final Map<PrinterConnectionType, List<PrinterDevice>> buckets = {};

    void emit() {
      final List<PrinterDevice> all = [
        for (final list in buckets.values) ...list,
      ];
      if (!controller.isClosed) controller.add(all);
    }

    int pending = 0;

    void addScan<T extends PrinterDevice>(
      PrinterConnectionType type,
      Stream<List<T>> stream,
    ) {
      pending++;
      final StreamSubscription<List<T>> sub = stream.listen(
        (devices) {
          buckets[type] = devices;
          emit();
        },
        onError: (Object e) {
          PrinterLogger.warning(_tag, '${type.name} scan error: $e');
        },
        onDone: () {
          pending--;
          if (pending == 0 && !controller.isClosed) {
            PrinterLogger.info(_tag, 'All scans complete');
            controller.close();
          }
        },
        cancelOnError: false,
      );
      _scanSubscriptions.add(sub);
    }

    if (supported.contains(PrinterConnectionType.network)) {
      addScan(
        PrinterConnectionType.network,
        _network.scan(timeout: timeout),
      );
    }

    if (supported.contains(PrinterConnectionType.ble)) {
      addScan(
        PrinterConnectionType.ble,
        _ble.scan(timeout: timeout),
      );
    }

    if (supported.contains(PrinterConnectionType.bluetooth)) {
      addScan(
        PrinterConnectionType.bluetooth,
        _bluetooth.scan(timeout: timeout),
      );
    }

    if (supported.contains(PrinterConnectionType.usb)) {
      addScan(
        PrinterConnectionType.usb,
        _usb.scan(timeout: timeout),
      );
    }

    if (pending == 0) controller.close();

    return controller.stream;
  }

  /// Scan all printer types and collect results, returning after [timeout].
  Future<List<PrinterDevice>> scanPrinters({
    Duration timeout = const Duration(seconds: 5),
    Set<PrinterConnectionType> types = const {
      PrinterConnectionType.network,
      PrinterConnectionType.ble,
      PrinterConnectionType.bluetooth,
      PrinterConnectionType.usb,
    },
  }) async {
    List<PrinterDevice> latest = [];

    await for (final batch in scanAll(timeout: timeout, types: types)) {
      latest = batch;
    }

    return latest;
  }

  /// Connect to [device].
  ///
  /// If already connected to another device, disconnects first.
  Future<void> connect(
    PrinterDevice device, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_active != null) {
      PrinterLogger.debug(
        _tag,
        'Already connected — disconnecting previous device',
      );
      await disconnect();
    }

    if (!device.connectionType.isSupportedOnCurrentPlatform) {
      throw PrinterConnectionException(
        '${device.connectionType.name} is not supported on this platform',
      );
    }

    PrinterLogger.info(_tag, 'Connecting to ${device.name}');

    final PrinterConnector<PrinterDevice> connector = _connectorFor(device);

    _active = connector;
    _activeDevice = device;

    // Forward state changes from the active connector.
    _activeStateSub = connector.stateStream.listen((s) {
      if (!_stateController.isClosed) _stateController.add(s);
    });

    await connector.connect(device, timeout: timeout);
  }

  /// Disconnect from the currently connected printer.
  Future<void> disconnect() async {
    if (_activeDevice != null) {
      PrinterLogger.info(_tag, 'Disconnecting from ${_activeDevice?.name}');
    }

    await _activeStateSub?.cancel();
    _activeStateSub = null;

    await _active?.disconnect();
    _active = null;
    _activeDevice = null;

    if (!_stateController.isClosed) {
      _stateController.add(PrinterConnectionState.disconnected);
    }
  }

  /// Send the bytes from [ticket] to the connected printer.
  Future<void> printTicket(Ticket ticket) async {
    final PrinterConnector<PrinterDevice> connector = _assertConnected('printTicket');
    PrinterLogger.info(_tag, 'Printing ticket (${ticket.bytes.length} bytes)');
    await connector.writeBytes(ticket.bytes);
  }

  /// Send raw [bytes] to the connected printer.
  Future<void> printBytes(List<int> bytes) async {
    final PrinterConnector<PrinterDevice> connector = _assertConnected('printBytes');
    PrinterLogger.debug(_tag, 'Printing ${bytes.length} raw bytes');
    await connector.writeBytes(bytes);
  }

  /// Open the cash drawer connected to [pin] (default: pin 2).
  Future<void> openCashDrawer({CashDrawer pin = CashDrawer.pin2}) async {
    final PrinterConnector<PrinterDevice> connector = _assertConnected('openCashDrawer');
    PrinterLogger.info(_tag, 'Opening cash drawer (${pin.name})');

    final List<int> bytes = pin == CashDrawer.pin2
        ? cCashDrawerPin2.codeUnits
        : cCashDrawerPin5.codeUnits;

    await connector.writeBytes(bytes);
  }

  /// Send a DLE EOT status query to the connected printer.
  ///
  /// Returns [PrinterStatus.timeout] when the printer does not respond within
  /// [timeoutMs] milliseconds or does not support DLE EOT (e.g. USB).
  Future<PrinterStatus> queryStatus({int timeoutMs = 2000}) async {
    final PrinterConnector<PrinterDevice> connector = _assertConnected('queryStatus');
    return connector.queryStatus(timeoutMs: timeoutMs);
  }

  /// Current connection state of the active connector.
  PrinterConnectionState get state =>
      _active?.state ?? PrinterConnectionState.disconnected;

  /// Stream of state changes. Stays alive across connect/disconnect cycles,
  /// forwarding events from whichever connector is currently active.
  Stream<PrinterConnectionState> get stateStream => _stateController.stream;

  /// Whether a printer is currently connected.
  bool get isConnected => state == PrinterConnectionState.connected;

  /// The device currently connected to, or null if not connected.
  PrinterDevice? get connectedDevice => _activeDevice;

  /// Stop all in-progress scans started by [scanAll] or [scanPrinters].
  ///
  /// Safe to call even when no scan is running.
  Future<void> stopAllScans() async {
    _stopScansSync();
    await Future.wait([
      _network.stopScan(),
      _ble.stopScan(),
      _bluetooth.stopScan(),
      _usb.stopScan(),
    ]);
    PrinterLogger.info(_tag, 'All scans stopped');
  }

  /// Disconnect and release all connector resources.
  Future<void> dispose() async {
    PrinterLogger.debug(_tag, 'Disposing');
    await stopAllScans();
    await disconnect();
    await _stateController.close();
    await _network.dispose();
    await _ble.dispose();
    await _bluetooth.dispose();
    await _usb.dispose();
  }

  // Helpers

  /// Cancel tracked Dart-side scan subscriptions and close the scan controller.
  void _stopScansSync() {
    for (final StreamSubscription<dynamic> sub in _scanSubscriptions) {
      sub.cancel();
    }
    _scanSubscriptions.clear();

    if (_scanController != null && !_scanController!.isClosed) {
      _scanController!.close();
    }
    _scanController = null;
  }

  PrinterConnector<PrinterDevice> _connectorFor(PrinterDevice device) {
    return switch (device) {
      NetworkPrinterDevice() => _network as PrinterConnector<PrinterDevice>,
      BlePrinterDevice() => _ble as PrinterConnector<PrinterDevice>,
      BluetoothPrinterDevice() => _bluetooth as PrinterConnector<PrinterDevice>,
      UsbPrinterDevice() => _usb as PrinterConnector<PrinterDevice>,
      _ => throw PrinterConnectionException(
          'No connector available for device type ${device.runtimeType}',
        ),
    };
  }

  PrinterConnector<PrinterDevice> _assertConnected(String operation) {
    final PrinterConnector<PrinterDevice>? connector = _active;
    if (connector == null || !isConnected) {
      throw PrinterStateException(
        'Cannot $operation: not connected to a printer',
        currentState: state,
        requiredState: PrinterConnectionState.connected,
      );
    }
    return connector;
  }
}
