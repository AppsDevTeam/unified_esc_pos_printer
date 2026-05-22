import '../exceptions/printer_exception.dart';
import '../models/printer_status_detail.dart';
import '../utils/printer_logger.dart';

/// Confirms a write completed cleanly by querying the printer's full
/// real-time status (DLE EOT 1, 2, 3, 4) and throwing
/// [PrinterDeviceException] if the assembled [PrinterStatusDetail]
/// reports any problem.
///
/// **Why all four queries every time.** EOT 1 carries the "general"
/// error bit, EOT 2 the offline cause (cover, paper-end, button-feed),
/// EOT 3 the error cause (mechanical, cutter, overheat), EOT 4 the
/// paper sensor (paper end, near-end). Spec-compliant printers raise
/// the EOT 1 error flag whenever any of the others triggers — but some
/// firmwares (Sunmi NT212 confirmed) leave EOT 1 clean and signal only
/// in EOT 4, so querying just EOT 1 misses the fault. Always pulling
/// the full set is the only protocol-portable way to catch every state.
///
/// [supportsRealtimeStatus] comes from a connect-time probe — it tells us
/// whether the printer answers DLE EOT at all.  This is critical because
/// many cheap thermal printers simply don't implement the spec, and a
/// timeout on those means "doesn't speak the protocol", not "in error".
///
/// Behavior:
/// - All four queries answered, none reports a problem: silent.
/// - Any reports a problem: throw [PrinterDeviceException] with the
///   assembled [PrinterStatusDetail].
/// - EOT 1 timeout AND probe said the printer does support DLE EOT:
///   throw [PrinterDeviceException] with an empty detail
///   (`isUnknown == true`) so callers can show a generic "printer
///   stopped responding" message.
/// - EOT 1 timeout AND probe said it doesn't (or probe never ran):
///   silent — we have no way to tell whether the print succeeded.
///
/// [bytesWritten] sizes the EOT 1 timeout: thermal printers process the
/// command in-line with their print queue, so on a long job the response
/// only arrives once the queue drains. When the first probe times out
/// from a printer that previously responded, we retry once with a longer
/// budget before treating it as an error — thermal heads can stall
/// briefly on cutter/feed operations and the real-time queue is the
/// last thing they service. Internal helper — intentionally NOT
/// exported from the library barrel file.
Future<void> verifyAfterWrite({
  required Future<int> Function(int n, int timeoutMs) queryStatusByteFn,
  required int bytesWritten,
  required bool? supportsRealtimeStatus,
  required String tag,
}) async {
  // Base 1 s + ~0.4 ms per byte (~2.5 KB/s effective print throughput).
  final int baseTimeoutMs = 1000 + (bytesWritten * 2 ~/ 5);

  int eot1 = await queryStatusByteFn(1, baseTimeoutMs);

  if (eot1 < 0 && supportsRealtimeStatus == true) {
    // Retry — a printer that normally responds can fall silent for a
    // few seconds while it cuts the previous job or recovers paper
    // feed; we don't want to surface a transient busy state as a fatal
    // error. 3 s second-chance budget is long enough to cover those
    // operations on cheap thermal printers without making genuine
    // failures noticeably slower.
    PrinterLogger.debug(
      tag,
      'Post-write: first probe timed out, retrying with 3 s budget',
    );
    eot1 = await queryStatusByteFn(1, 3000);
  }

  if (eot1 < 0) {
    if (supportsRealtimeStatus == true) {
      PrinterLogger.error(
        tag,
        'Post-write: status query timed out from a printer that '
        'normally responds (retry exhausted) — printer is likely in error state',
      );
      throw const PrinterDeviceException(
        'Printer stopped responding to status queries',
        detail: PrinterStatusDetail(),
      );
    }
    PrinterLogger.debug(
      tag,
      'Post-write: status query unanswered '
      '(supportsRealtimeStatus=$supportsRealtimeStatus)',
    );
    return;
  }

  // EOT 1 answered — pull the rest unconditionally. The printer is
  // responding, so follow-ups should land in <100 ms each; we use a
  // shorter timeout here because they're not gated on print-queue
  // drainage like EOT 1 is.
  const int detailTimeoutMs = 800;
  final int eot2 = await queryStatusByteFn(2, detailTimeoutMs);
  final int eot3 = await queryStatusByteFn(3, detailTimeoutMs);
  final int eot4 = await queryStatusByteFn(4, detailTimeoutMs);

  final PrinterStatusDetail detail = PrinterStatusDetail.fromBytes(
    eot1: eot1,
    eot2: eot2,
    eot3: eot3,
    eot4: eot4,
  );

  if (!detail.hasAnyProblem) {
    PrinterLogger.debug(tag, 'Post-write: ok ($detail)');
    return;
  }

  PrinterLogger.error(tag, 'Post-write: device reports problem: $detail');
  throw PrinterDeviceException(
    'Printer reports an error condition',
    detail: detail,
  );
}

/// Runs a quick DLE EOT 1 probe right after connect to find out whether
/// this printer implements real-time status at all.  Sent when the print
/// queue is empty so a supporting printer answers within milliseconds.
///
/// Returns:
/// - `true`: printer answered → real-time status is supported.
/// - `false`: timed out → printer doesn't speak DLE EOT.
///
/// Internal helper — intentionally NOT exported from the library barrel
/// file.  Connectors that cannot read back at all (BLE without an RX
/// characteristic, Windows Print Spooler) should not call this and should
/// expose `supportsRealtimeStatus == null` instead.
Future<bool> probeRealtimeStatus({
  required Future<int> Function(int n, int timeoutMs) queryStatusByteFn,
  required String tag,
  int timeoutMs = 1500,
}) async {
  final int probe = await queryStatusByteFn(1, timeoutMs);
  final bool supported = probe >= 0;
  PrinterLogger.info(
    tag,
    'Probe: real-time status ${supported ? "supported" : "NOT supported"} '
    '(probe byte=$probe)',
  );
  return supported;
}
