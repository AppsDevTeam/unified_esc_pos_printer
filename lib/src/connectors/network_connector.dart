import 'dart:async';
import 'dart:io';

import '../core/commands.dart';
import '../exceptions/printer_exception.dart';
import '../models/printer_connection_state.dart';
import '../models/printer_device.dart';

import '../utils/printer_logger.dart';
import 'post_write_status.dart';
import 'printer_connector.dart';

const String _tag = 'Network';

/// Connector for network (TCP/IP) ESC/POS printers.
///
/// **Discovery:** Scans the local subnet by attempting parallel TCP connections
/// on [scanPort]. Hosts that accept a connection within [kScanSubnetTimeoutMs]
/// are reported as discovered printers.
///
/// **Data flow:** Sends all bytes in a single [Socket.add] call followed by
/// [Socket.flush] to avoid partial writes.
class NetworkConnector extends PrinterConnector<NetworkPrinterDevice> {
  NetworkConnector({this.scanPort = kDefaultNetworkPort});

  /// Port used for both discovery scanning and default connections.
  final int scanPort;

  Socket? _socket;
  PrinterConnectionState _state = PrinterConnectionState.disconnected;
  final StreamController<PrinterConnectionState> _stateController =
      StreamController<PrinterConnectionState>.broadcast();

  @override
  Stream<PrinterConnectionState> get stateStream => _stateController.stream;

  @override
  PrinterConnectionState get state => _state;

  @override
  Stream<List<NetworkPrinterDevice>> scan({
    Duration timeout = const Duration(seconds: 5),
  }) async* {
    _setState(PrinterConnectionState.scanning);

    final List<NetworkPrinterDevice> found = [];
    String? localIp;

    try {
      final List<NetworkInterface> interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );

      for (final NetworkInterface interface in interfaces) {
        for (final InternetAddress addr in interface.addresses) {
          final String ip = addr.address;
          // Skip loopback and link-local addresses.
          if (ip.startsWith('127.') || ip.startsWith('169.254.')) continue;
          localIp = ip;
          PrinterLogger.debug(
            _tag,
            'Found local IP: $ip on ${interface.name}',
          );
          break;
        }
        if (localIp != null) break;
      }
    } catch (e) {
      PrinterLogger.error(_tag, 'Failed to enumerate network interfaces: $e');
    }

    if (localIp == null || localIp.isEmpty) {
      PrinterLogger.error(_tag, 'No usable local IP found — aborting scan');
      _setState(PrinterConnectionState.disconnected);
      throw const PrinterScanException(
        'Cannot determine local WiFi IP address. '
        'Ensure the device is connected to a WiFi network and '
        'required permissions are granted.',
      );
    }

    // Derive subnet prefix (e.g. '192.168.1')
    final List<String> parts = localIp.split('.');
    if (parts.length != 4) {
      PrinterLogger.error(_tag, 'Invalid IP format: $localIp');
      _setState(PrinterConnectionState.disconnected);
      return;
    }

    final String subnet = '${parts[0]}.${parts[1]}.${parts[2]}';

    // Each probe gets the full scan timeout so slow printers are not missed.
    final Duration probeTimeout = timeout;

    PrinterLogger.info(
      _tag,
      'Scanning subnet $subnet.* on port $scanPort '
      '(timeout: ${probeTimeout.inSeconds}s)',
    );

    final Stopwatch stopwatch = Stopwatch()..start();
    final StreamController<List<NetworkPrinterDevice>> controller =
        StreamController<List<NetworkPrinterDevice>>();

    // Fan-out 254 parallel TCP probe connections.
    final List<Future<void>> probes = List.generate(254, (i) async {
      final String host = '$subnet.${i + 1}';

      try {
        final Socket s = await Socket.connect(
          host,
          scanPort,
          timeout: probeTimeout,
        );

        await s.close();
        s.destroy();

        PrinterLogger.info(_tag, 'Found printer at $host:$scanPort');

        final NetworkPrinterDevice device = NetworkPrinterDevice(
          name: host,
          host: host,
          port: scanPort,
        );
        found.add(device);
        controller.add(List<NetworkPrinterDevice>.unmodifiable(found));
      } on SocketException {
        // Host not reachable — connection refused.
      } on TimeoutException {
        // Host not reachable within timeout — expected for most IPs
      } catch (e) {
        PrinterLogger.debug(_tag, '$host — unexpected error: $e');
      }
    });

    // Close stream when all probes finish.
    Future.wait(probes).whenComplete(() {
      stopwatch.stop();
      PrinterLogger.info(
        _tag,
        'Scan complete in ${stopwatch.elapsed.inSeconds}s — '
        'found ${found.length} printer(s)',
      );
      _setState(PrinterConnectionState.disconnected);
      controller.close();
    });

    yield* controller.stream;
  }

  @override
  Future<void> stopScan() async {
    if (_state == PrinterConnectionState.scanning) {
      PrinterLogger.debug(_tag, 'Stopping scan');
      _setState(PrinterConnectionState.disconnected);
    }
  }

  @override
  Future<void> connect(
    NetworkPrinterDevice device, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    _assertState(
      PrinterConnectionState.disconnected,
      'connect',
    );

    PrinterLogger.info(_tag, 'Connecting to ${device.host}:${device.port}');
    _setState(PrinterConnectionState.connecting);

    try {
      _socket = await Socket.connect(
        device.host,
        device.port,
        timeout: timeout,
      );

      // Send ESC @ to initialise the printer on connect.
      _socket!.add(cInit.codeUnits);
      await _socket!.flush();

      PrinterLogger.info(_tag, 'Connected to ${device.host}:${device.port}');
      _setState(PrinterConnectionState.connected);
    } on SocketException catch (e) {
      PrinterLogger.error(
        _tag,
        'Connection failed to ${device.host}:${device.port}: ${e.message}',
      );
      _setState(PrinterConnectionState.error);
      _setState(PrinterConnectionState.disconnected);
      throw PrinterConnectionException(
        'Cannot connect to ${device.host}:${device.port}',
        cause: e,
      );
    } on TimeoutException catch (e) {
      PrinterLogger.error(
        _tag,
        'Connection timed out to ${device.host}:${device.port}',
      );
      _setState(PrinterConnectionState.error);
      _setState(PrinterConnectionState.disconnected);
      throw PrinterConnectionException(
        'Connection to ${device.host}:${device.port} timed out',
        cause: e,
      );
    }
  }

  @override
  Future<void> writeBytes(List<int> bytes) async {
    _assertState(PrinterConnectionState.connected, 'writeBytes');

    _setState(PrinterConnectionState.printing);

    try {
      PrinterLogger.debug(_tag, 'Writing ${bytes.length} bytes');
      _socket!.add(bytes);
      await _socket!.flush();

      await postWriteStatusQuery(
        queryFn: (int timeoutMs) => _queryStatus(timeoutMs),
        bytesWritten: bytes.length,
        tag: _tag,
      );

      _setState(PrinterConnectionState.connected);
    } catch (e) {
      PrinterLogger.error(_tag, 'Write failed: $e');
      _setState(PrinterConnectionState.error);
      _setState(PrinterConnectionState.disconnected);
      throw PrinterWriteException('Failed to write bytes to printer', cause: e);
    }
  }

  // ── Disconnection ──────────────────────────────────────────────────────────

  @override
  Future<void> disconnect() async {
    if (_state == PrinterConnectionState.disconnected) return;

    PrinterLogger.info(_tag, 'Disconnecting');
    _setState(PrinterConnectionState.disconnecting);

    try {
      await _socket?.flush();
      await _socket?.close();
    } finally {
      _socket?.destroy();
      _socket = null;
      _setState(PrinterConnectionState.disconnected);
    }
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    await _stateController.close();
  }

  /// Sends DLE EOT status query and waits for a single-byte response.
  /// Returns the status byte, or -1 on timeout.
  Future<int> _queryStatus(int timeoutMs) async {
    final Socket? sock = _socket;
    if (sock == null) return -1;

    final Completer<int> completer = Completer<int>();
    StreamSubscription<List<int>>? sub;

    sub = sock.listen(
      (List<int> data) {
        if (!completer.isCompleted && data.isNotEmpty) {
          completer.complete(data.first);
          sub?.cancel();
        }
      },
      onError: (Object e) {
        if (!completer.isCompleted) completer.complete(-1);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete(-1);
      },
    );

    // Send DLE EOT n=1 (printer status)
    sock.add(const [0x10, 0x04, 0x01]);
    await sock.flush();

    // Wait with timeout
    final Future<int> timeoutFuture = Future<int>.delayed(
      Duration(milliseconds: timeoutMs),
      () => -1,
    );

    final int result = await Future.any([completer.future, timeoutFuture]);
    await sub.cancel();
    return result;
  }

  void _setState(PrinterConnectionState next) {
    _state = next;
    if (!_stateController.isClosed) _stateController.add(next);
  }

  void _assertState(PrinterConnectionState required, String operation) {
    if (_state != required) {
      throw PrinterStateException(
        'Cannot $operation: expected $required but was $_state',
        currentState: _state,
        requiredState: required,
      );
    }
  }
}
