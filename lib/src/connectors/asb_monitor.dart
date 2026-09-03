import 'dart:async';

import '../models/printer_status_detail.dart';
import '../utils/printer_logger.dart';

/// Listens to a continuous byte stream from a printer and parses ASB
/// (Automatic Status Back) packets. ASB packets are 4 bytes wide and
/// are pushed by the printer whenever its status changes — paper out,
/// cover open, recovery, etc. — see ESC/POS `GS a n` command.
///
/// Each ASB byte shares the same bit layout as the DLE EOT n=1..4
/// real-time status response, so we feed the assembled packet into
/// [PrinterStatusDetail.fromBytes] using `eot1..eot4` as a shorthand
/// for "ASB byte 1..4".
///
/// **Mutual exclusion with DLE EOT polling.** ASB and DLE EOT poll-and-
/// respond cannot share the same byte stream cleanly: a 1-byte DLE EOT
/// response is indistinguishable from the first byte of an ASB packet.
/// The monitor therefore drops any leftover bytes that don't form a
/// complete 4-byte packet within [_packetIdleTimeout]; callers that opt
/// into ASB should stop issuing DLE EOT queries on the same connection.
class AsbMonitor {
  /// Idle window after which an incomplete (1–3 byte) tail in the
  /// buffer is assumed to be a stray DLE EOT response from somebody
  /// else and discarded.
  static const Duration _packetIdleTimeout = Duration(milliseconds: 50);

  final String tag;

  final List<int> _buffer = <int>[];

  final StreamController<PrinterStatusDetail> _statusController =
      StreamController<PrinterStatusDetail>.broadcast();

  /// Raw bytes of the last packet, so repeats of an unchanged status can be
  /// recognised without giving [PrinterStatusDetail] value equality.
  List<int>? _lastPacketBytes;

  Timer? _idleTimer;
  StreamSubscription<List<int>>? _sub;
  PrinterStatusDetail _latest = const PrinterStatusDetail();
  bool _enabled = false;
  Completer<bool>? _firstPacketCompleter;

  AsbMonitor({required this.tag});

  /// Latest status assembled from the most recent ASB packet. Equals
  /// `PrinterStatusDetail()` (i.e. `isUnknown == true`) before the
  /// first packet arrives.
  PrinterStatusDetail get latest => _latest;

  /// Pushed every time a fresh ASB packet is parsed.
  Stream<PrinterStatusDetail> get statusStream => _statusController.stream;

  /// True iff the printer has confirmed ASB support by sending the
  /// initial 4-byte status packet after we enabled it.
  bool get isEnabled => _enabled;

  /// Attaches to [inboundStream], sends `GS a <mask>` via [sendBytes] to
  /// enable ASB on the printer, and waits up to [timeout] for the
  /// printer's initial 4-byte status push.
  ///
  /// Returns `true` if ASB is supported (and the monitor remains attached
  /// for the duration of the connection); `false` otherwise (the
  /// subscription is detached so the caller can fall back to DLE EOT).
  ///
  /// [mask] is the ASB status class mask: bit 0 = drawer kick, bit 1 =
  /// online/offline, bit 2 = error, bit 3 = paper roll sensor. `0xFF`
  /// enables all classes; `0x0E` enables online + error + paper.
  Future<bool> tryEnable({
    required Stream<List<int>> inboundStream,
    required Future<void> Function(List<int> bytes) sendBytes,
    int mask = 0xFF,
    Duration timeout = const Duration(milliseconds: 1500),
  }) async {
    if (_enabled) return true;

    final Completer<bool> firstPacket = Completer<bool>();
    _firstPacketCompleter = firstPacket;
    _sub = inboundStream.listen(_onBytes);

    try {
      await sendBytes(<int>[0x1D, 0x61, mask & 0xFF]);
    } catch (e) {
      PrinterLogger.error(tag, 'ASB: enable command write failed: $e');
      await _detach();
      return false;
    }

    final bool ok = await firstPacket.future.timeout(
      timeout,
      onTimeout: () => false,
    );

    if (!ok) {
      PrinterLogger.info(
        tag,
        'ASB: not supported (no initial packet within '
        '${timeout.inMilliseconds} ms)',
      );
      // Best-effort: tell the printer to stop pushing ASB in case it
      // actually does support `GS a` and silently turned itself on but
      // we missed the initial packet. Without this, any subsequent
      // status change would push 4 bytes into a socket nobody is
      // reading, eventually saturating the kernel buffer.
      try {
        await sendBytes(<int>[0x1D, 0x61, 0x00]);
      } catch (_) {}
      await _detach();
      return false;
    }

    _enabled = true;
    _firstPacketCompleter = null;
    PrinterLogger.info(tag, 'ASB: enabled (initial status $_latest)');
    return true;
  }

  void _onBytes(List<int> data) {
    if (data.isEmpty) return;
    _idleTimer?.cancel();
    _buffer.addAll(data);

    while (_buffer.length >= 4) {
      final List<int> packet = _buffer.sublist(0, 4);
      _buffer.removeRange(0, 4);
      _processPacket(packet);
    }

    if (_buffer.isNotEmpty) {
      _idleTimer = Timer(_packetIdleTimeout, () {
        if (_buffer.isNotEmpty) {
          PrinterLogger.debug(
            tag,
            'ASB: discarding ${_buffer.length} stray byte(s)',
          );
          _buffer.clear();
        }
      });
    }
  }

  void _processPacket(List<int> packet) {
    final PrinterStatusDetail detail = PrinterStatusDetail.fromBytes(
      eot1: packet[0],
      eot2: packet[1],
      eot3: packet[2],
      eot4: packet[3],
    );
    _latest = detail;

    // Some printers push ASB periodically rather than only on change, so the
    // same "everything is fine" packet arrives every few seconds forever.
    // Logging each repeat buries every other line in the log and reads like a
    // busy loop. Log the first packet and every actual change, stay quiet in
    // between; the status stream still gets every packet.
    final List<int>? previous = _lastPacketBytes;
    final bool changed = previous == null ||
        previous[0] != packet[0] ||
        previous[1] != packet[1] ||
        previous[2] != packet[2] ||
        previous[3] != packet[3];
    _lastPacketBytes = packet;

    if (changed) PrinterLogger.debug(tag, 'ASB: packet $detail');

    if (!_statusController.isClosed) _statusController.add(detail);

    final Completer<bool>? first = _firstPacketCompleter;
    if (first != null && !first.isCompleted) {
      first.complete(true);
    }
  }

  Future<void> _detach() async {
    _lastPacketBytes = null;
    _idleTimer?.cancel();
    _idleTimer = null;
    await _sub?.cancel();
    _sub = null;
    _buffer.clear();
    _firstPacketCompleter = null;
  }

  /// Cancels the inbound subscription and closes the status stream.
  /// Call from the connector's `disconnect` / `dispose` path.
  Future<void> dispose() async {
    await _detach();
    _enabled = false;
    _latest = const PrinterStatusDetail();
    if (!_statusController.isClosed) {
      await _statusController.close();
    }
  }
}
