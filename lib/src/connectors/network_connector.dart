import 'dart:async';
import 'dart:io';

import '../core/commands.dart';
import '../exceptions/printer_exception.dart';
import '../models/printer_connection_state.dart';
import '../models/printer_device.dart';

import '../models/printer_status.dart';
import '../models/printer_status_detail.dart';
import '../utils/printer_logger.dart';
import 'asb_monitor.dart';
import 'post_write_status.dart';
import 'pre_write_status.dart';
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
  // Broadcast view of [_socket] so multiple callers (queryStatusByte from
  // verifyAfterWrite, the connect-time probe, …) can listen sequentially.
  // Plain Socket is single-subscription; without this every second query
  // throws "Stream has already been listened to".
  Stream<List<int>>? _inboundStream;
  PrinterConnectionState _state = PrinterConnectionState.disconnected;
  bool? _supportsRealtimeStatus;
  AsbMonitor? _asb;
  // Set to true by [disconnect] before tearing the socket down so the
  // [socket.done] handler can tell a local teardown from a remote close
  // (idle timeout on the printer side, network glitch, …). Cleared on
  // every fresh [connect].
  bool _disconnectInitiatedLocally = false;
  final StreamController<PrinterConnectionState> _stateController =
      StreamController<PrinterConnectionState>.broadcast();

  @override
  Stream<PrinterConnectionState> get stateStream => _stateController.stream;

  @override
  PrinterConnectionState get state => _state;

  @override
  bool? get supportsRealtimeStatus => _supportsRealtimeStatus;

  @override
  bool get supportsAsb => _asb?.isEnabled ?? false;

  @override
  PrinterStatusDetail get latestAsbStatus =>
      _asb?.latest ?? const PrinterStatusDetail();

  @override
  Stream<PrinterStatusDetail> get asbStatusStream =>
      _asb?.statusStream ?? const Stream<PrinterStatusDetail>.empty();

  @override
  Stream<List<NetworkPrinterDevice>> scan({
    Duration timeout = const Duration(seconds: 5),
  }) async* {
    _setState(PrinterConnectionState.scanning);

    final List<NetworkPrinterDevice> found = [];

    // Collect every unique /24 the device is on. Multi-homed setups
    // (Wi-Fi + USB tether, Wi-Fi + cellular hotspot, …) routinely have
    // two or more non-loopback interfaces; picking only the first
    // means we'd scan the wrong subnet on devices where the printer
    // lives on the secondary one (Sunmi D3 Pro reliably reports
    // `usb0` 192.168.139.x before `wlan0` 192.168.0.x, for example).
    final Set<String> subnets = <String>{};
    try {
      final List<NetworkInterface> interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );

      for (final NetworkInterface interface in interfaces) {
        for (final InternetAddress addr in interface.addresses) {
          final String ip = addr.address;
          // Skip loopback and link-local addresses.
          if (ip.startsWith('127.') || ip.startsWith('169.254.')) continue;
          final List<String> parts = ip.split('.');
          if (parts.length != 4) continue;
          final String subnet = '${parts[0]}.${parts[1]}.${parts[2]}';
          if (subnets.add(subnet)) {
            PrinterLogger.debug(
              _tag,
              'Local IP $ip on ${interface.name} → subnet $subnet.*',
            );
          }
        }
      }
    } catch (e) {
      PrinterLogger.error(_tag, 'Failed to enumerate network interfaces: $e');
    }

    if (subnets.isEmpty) {
      PrinterLogger.error(_tag, 'No usable local subnet found — aborting scan');
      _setState(PrinterConnectionState.disconnected);
      throw const PrinterNetworkUnavailableException(
        'Cannot determine local WiFi IP address. '
        'Ensure the device is connected to a WiFi network and '
        'required permissions are granted.',
      );
    }

    // Each probe gets the full scan timeout so slow printers are not missed.
    final Duration probeTimeout = timeout;

    PrinterLogger.info(
      _tag,
      'Scanning ${subnets.length} subnet(s) ${subnets.join(', ')} on port $scanPort '
      '(timeout: ${probeTimeout.inSeconds}s)',
    );

    final Stopwatch stopwatch = Stopwatch()..start();
    final StreamController<List<NetworkPrinterDevice>> controller =
        StreamController<List<NetworkPrinterDevice>>();

    // Fan-out 254 parallel TCP probe connections per subnet — runs all
    // subnets concurrently so total scan time stays bounded by the
    // probe timeout, not multiplied by the subnet count.
    final List<Future<void>> probes = <Future<void>>[];
    for (final String subnet in subnets) {
      for (int i = 1; i <= 254; i++) {
        final String host = '$subnet.$i';
        probes.add(Future<void>(() async {
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
        }));
      }
    }

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

    _disconnectInitiatedLocally = false;

    try {
      final Socket socket = await Socket.connect(
        device.host,
        device.port,
        timeout: timeout,
      );
      final Stream<List<int>> inbound = socket.asBroadcastStream();
      _socket = socket;
      _inboundStream = inbound;

      // Watch for remote close — printer-side idle timeout, network glitch,
      // FIN/RST from the router. PrintManager._ensureConnected will see
      // state != connected on the next print and dial up fresh.
      //
      // Capture the socket reference so the late-firing callback can
      // distinguish "I closed THIS socket" from "I already moved on to a
      // new connection". Without that check, a reconnect arriving between
      // the old socket's close() returning and its done future firing
      // would have the callback nuke the fresh ASB monitor / socket.
      final Socket socketRef = socket;
      // ignore: discarded_futures
      socket.done.then((_) async {
        if (_socket != socketRef) {
          PrinterLogger.debug(
            _tag,
            'Socket.done from stale reference — already replaced, ignoring',
          );
          return;
        }
        await _onSocketDone(local: _disconnectInitiatedLocally);
      }).catchError((Object e) {
        PrinterLogger.warning(_tag, 'socket.done handler failed: $e');
      });

      // Send ESC @ to initialise the printer on connect.
      socket.add(cInit.codeUnits);
      await socket.flush();

      PrinterLogger.info(_tag, 'Connected to ${device.host}:${device.port}');
      _setState(PrinterConnectionState.connected);

      // Prefer ASB over DLE EOT polling — ASB tells us about paper-out
      // / cover-open even when the printer otherwise stops answering
      // status queries (a common failure mode of cheap thermal heads).
      // Falls back to the original probe only if the printer doesn't
      // push the initial 4-byte status packet within the timeout.
      final AsbMonitor monitor = AsbMonitor(tag: _tag);
      _asb = monitor;
      final bool asbOk = await monitor.tryEnable(
        inboundStream: inbound,
        sendBytes: (List<int> b) async {
          socket.add(b);
          await socket.flush();
        },
      );

      if (!asbOk) {
        await monitor.dispose();
        _asb = null;
        _supportsRealtimeStatus = await probeRealtimeStatus(
          queryStatusByteFn: (int n, int timeoutMs) =>
              queryStatusByte(n, timeoutMs: timeoutMs),
          tag: _tag,
        );
      }
    } on SocketException catch (e) {
      PrinterLogger.error(
        _tag,
        'Connection failed to ${device.host}:${device.port}: ${e.message}',
      );
      _setState(PrinterConnectionState.error);
      _setState(PrinterConnectionState.disconnected);
      throw PrinterUnreachableException(
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
      throw PrinterTimeoutException(
        'Connection to ${device.host}:${device.port} timed out',
        cause: e,
      );
    }
  }

  @override
  Future<void> writeBytes(List<int> bytes, {bool verifyStatus = true}) async {
    _assertState(PrinterConnectionState.connected, 'writeBytes');

    final AsbMonitor? asb = _asb;
    if (verifyStatus) {
      // When ASB is not handling status pushes for us, do a quick DLE EOT
      // ping before the write. Catches "printer fell into error state
      // mid-session" cases that the connect-time probe couldn't see, and
      // late-binds `supportsRealtimeStatus = true` the moment the printer
      // proves it speaks the protocol — so subsequent timeouts become
      // genuine error signals rather than "doesn't support DLE EOT".
      if (asb == null || !asb.isEnabled) {
        _supportsRealtimeStatus = await verifyBeforeWrite(
          queryStatusByteFn: (int n, int timeoutMs) =>
              queryStatusByte(n, timeoutMs: timeoutMs),
          supportsRealtimeStatus: _supportsRealtimeStatus,
          tag: _tag,
        );
      }

      // Gate the print on the most recent ASB status — refusing to send
      // bytes to a printer that has already reported a fault is cheaper
      // than transferring 20 KB of raster into a printer that can't use
      // them and then trying to recover.
      if (asb != null && asb.isEnabled && asb.latest.hasAnyProblem) {
        PrinterLogger.error(
          _tag,
          'Pre-write: refusing print, ASB reports problem: ${asb.latest}',
        );
        throw PrinterDeviceException(
          'Printer reports an error condition',
          detail: asb.latest,
        );
      }
    }

    _setState(PrinterConnectionState.printing);

    try {
      PrinterLogger.debug(_tag, 'Writing ${bytes.length} bytes');
      _socket!.add(bytes);
      await _socket!.flush();

      // Bytes are flushed — the write phase is over.  Return to 'connected'
      // before verifying so that queryStatusByte's state assertion passes.
      _setState(PrinterConnectionState.connected);
    } catch (e) {
      PrinterLogger.error(_tag, 'Write failed: $e');
      _setState(PrinterConnectionState.error);
      _setState(PrinterConnectionState.disconnected);
      throw PrinterWriteException('Failed to write bytes to printer', cause: e);
    }

    if (!verifyStatus) return;

    if (asb != null && asb.isEnabled) {
      // ASB pushes any post-write status change asynchronously — no need
      // to poll DLE EOT here. Re-check the cached status one more time
      // in case a new packet arrived between the gate above and the
      // socket flush completing.
      if (asb.latest.hasAnyProblem) {
        PrinterLogger.error(
          _tag,
          'Post-write: ASB reports problem: ${asb.latest}',
        );
        throw PrinterDeviceException(
          'Printer reports an error condition',
          detail: asb.latest,
        );
      }
      return;
    }

    // Outside the write try/catch: a PrinterDeviceException raised here
    // means the bytes went through but the printer reports a hardware
    // problem — we want it to propagate without flipping us to 'error'.
    await verifyAfterWrite(
      queryStatusByteFn: (int n, int timeoutMs) =>
          queryStatusByte(n, timeoutMs: timeoutMs),
      bytesWritten: bytes.length,
      supportsRealtimeStatus: _supportsRealtimeStatus,
      tag: _tag,
    );
  }

  @override
  Future<PrinterStatus> queryStatus({int timeoutMs = 2000}) async {
    final int raw = await queryStatusByte(1, timeoutMs: timeoutMs);
    final PrinterStatus status =
        raw >= 0 ? PrinterStatus.fromByte(raw) : PrinterStatus.timeout;
    PrinterLogger.debug(_tag, 'queryStatus: $status');
    return status;
  }

  @override
  Future<int> queryStatusByte(int n, {int timeoutMs = 2000}) async {
    _assertState(PrinterConnectionState.connected, 'queryStatusByte');

    final Socket? sock = _socket;
    final Stream<List<int>>? inbound = _inboundStream;
    if (sock == null || inbound == null) return -1;

    final Completer<int> completer = Completer<int>();
    StreamSubscription<List<int>>? sub;

    sub = inbound.listen(
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

    sock.add([0x10, 0x04, n & 0xFF]);
    await sock.flush();

    final Future<int> timeoutFuture = Future<int>.delayed(
      Duration(milliseconds: timeoutMs),
      () => -1,
    );

    final int rawStatus = await Future.any([completer.future, timeoutFuture]);
    await sub.cancel();
    return rawStatus;
  }

  @override
  Future<int> queryRawByte(List<int> request, {int timeoutMs = 500}) async {
    _assertState(PrinterConnectionState.connected, 'queryRawByte');

    final Socket? sock = _socket;
    final Stream<List<int>>? inbound = _inboundStream;
    if (sock == null || inbound == null) return -1;

    final Completer<int> completer = Completer<int>();
    StreamSubscription<List<int>>? sub;

    sub = inbound.listen(
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

    sock.add(request);
    await sock.flush();

    final Future<int> timeoutFuture = Future<int>.delayed(
      Duration(milliseconds: timeoutMs),
      () => -1,
    );

    final int rawResponse = await Future.any([completer.future, timeoutFuture]);
    await sub.cancel();
    return rawResponse;
  }

  // ── Disconnection ──────────────────────────────────────────────────────────

  @override
  Future<void> disconnect() async {
    if (_state == PrinterConnectionState.disconnected) return;

    PrinterLogger.info(_tag, 'Disconnecting');
    _disconnectInitiatedLocally = true;
    _setState(PrinterConnectionState.disconnecting);

    await _asb?.dispose();
    _asb = null;

    try {
      await _socket?.flush();
      await _socket?.close();
    } finally {
      _socket?.destroy();
      _socket = null;
      _inboundStream = null;
      _supportsRealtimeStatus = null;
      _setState(PrinterConnectionState.disconnected);
    }
  }

  /// Invoked from [Socket.done] when the OS socket closes. [local] is true
  /// when our own [disconnect] initiated the teardown — in that case the
  /// future just completes after `_socket.close()` and there's nothing
  /// left to do. When false, the printer (or the network) closed the
  /// connection unilaterally and we need to tear our state down so the
  /// next print triggers a fresh [PrinterManager._ensureConnected].
  Future<void> _onSocketDone({required bool local}) async {
    if (local) {
      PrinterLogger.debug(_tag, 'Socket done (local close)');
      return;
    }
    if (_state == PrinterConnectionState.disconnected) {
      // We may have raced disconnect() — nothing else to do.
      return;
    }
    PrinterLogger.warning(_tag, 'Socket closed by remote');
    await _asb?.dispose();
    _asb = null;
    _socket?.destroy();
    _socket = null;
    _inboundStream = null;
    _supportsRealtimeStatus = null;
    _setState(PrinterConnectionState.error);
    _setState(PrinterConnectionState.disconnected);
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    await _stateController.close();
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
