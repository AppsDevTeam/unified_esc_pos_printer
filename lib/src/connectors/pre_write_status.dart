import '../exceptions/printer_exception.dart';
import '../models/printer_status_detail.dart';
import '../utils/printer_logger.dart';

/// Polls the printer for its real-time status (DLE EOT 1, 2, 3, 4)
/// before sending a print job. Throws [PrinterDeviceException] if the
/// assembled [PrinterStatusDetail] reports any problem (paper end /
/// near-end, cover open, mechanical / cutter / unrecoverable error,
/// overheating, …), so a print isn't wasted on a printer that can't
/// physically deliver.
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
/// **Late-binding `supportsRealtimeStatus`.** The connect-time probe
/// can give a misleading `false` if the printer happened to be silent
/// at that moment — many ESC/POS printers stop answering DLE EOT when
/// offline. If THIS function gets a positive response, the returned
/// value is `true` — the printer has just proven it speaks the
/// protocol, regardless of what the initial probe said. Subsequent
/// timeouts can then be treated as genuine errors rather than "printer
/// doesn't implement DLE EOT".
///
/// Behavior:
/// - All four queries answered, none reports a problem: return `true`.
/// - Any reports a problem: throw [PrinterDeviceException] with the
///   assembled [PrinterStatusDetail].
/// - EOT 1 timeout AND we previously knew the printer responds: throw
///   [PrinterDeviceException] with empty detail (printer gone silent).
/// - EOT 1 timeout AND we never had a positive response: return the
///   input `supportsRealtimeStatus` unchanged — could be a dumb
///   printer that simply doesn't speak DLE EOT, so don't punish it.
///
/// Skipped automatically by the caller when ASB is active — ASB pushes
/// would corrupt the single-byte EOT response if both ran on the same
/// stream. Internal helper — intentionally NOT exported from the
/// library barrel file.
Future<bool?> verifyBeforeWrite({
  required Future<int> Function(int n, int timeoutMs) queryStatusByteFn,
  required bool? supportsRealtimeStatus,
  required String tag,
}) async {
  // First probe is short — most healthy printers answer in <50 ms when
  // the queue is empty. If it times out the printer is either offline,
  // legitimately doesn't speak DLE EOT, or is briefly busy (recently
  // received unrecognized commands, finalizing a cut, etc.). Retry
  // once with a generous budget before reaching any conclusion;
  // 1500 ms is long enough for thermal heads to recover from a stall
  // without dragging genuine errors out unreasonably.
  const int firstProbeMs = 300;
  const int retryProbeMs = 1500;
  int eot1 = await queryStatusByteFn(1, firstProbeMs);
  if (eot1 < 0) {
    PrinterLogger.debug(
      tag,
      'Pre-write: first probe timed out, retrying with $retryProbeMs ms budget',
    );
    eot1 = await queryStatusByteFn(1, retryProbeMs);
  }

  if (eot1 < 0) {
    if (supportsRealtimeStatus == true) {
      // The printer answered status queries earlier in the session and
      // now goes completely silent — far more likely to be a lost
      // connection (powered off, network drop, frozen firmware) than a
      // device-level fault that DLE EOT 2/3/4 would expose. Surface
      // this as a connection-class exception so callers can show
      // "check that the printer is on and reachable" instead of the
      // "check paper / cover" implied by a hardware fault.
      PrinterLogger.error(
        tag,
        'Pre-write: printer stopped responding (previously confirmed support)',
      );
      throw const PrinterDisconnectedDuringOperationException(
        'Printer stopped responding to status queries',
      );
    }
    PrinterLogger.debug(
      tag,
      'Pre-write: status query unanswered '
      '(supportsRealtimeStatus=$supportsRealtimeStatus) — proceeding optimistically',
    );
    return supportsRealtimeStatus;
  }

  // EOT 1 answered — pull the rest. Short timeout because the printer
  // is responsive right now; queries should land in <100 ms each.
  const int detailTimeoutMs = 500;
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
    PrinterLogger.debug(tag, 'Pre-write: ok ($detail)');
    return true;
  }

  PrinterLogger.error(tag, 'Pre-write: device reports problem: $detail');
  throw PrinterDeviceException(
    'Printer reports an error condition',
    detail: detail,
  );
}
