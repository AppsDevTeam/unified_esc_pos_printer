import '../exceptions/printer_exception.dart';
import '../models/printer_status.dart';
import '../models/printer_status_detail.dart';
import '../utils/printer_logger.dart';

/// Confirms a write completed cleanly by querying the printer's real-time
/// status and, if anything looks off, gathering full DLE EOT 1/2/3/4 detail
/// before throwing [PrinterDeviceException].
///
/// [supportsRealtimeStatus] comes from a connect-time probe — it tells us
/// whether the printer answers DLE EOT at all.  This is critical because
/// many cheap thermal printers simply don't implement the spec, and a
/// timeout on those means "doesn't speak the protocol", not "in error".
///
/// Behavior:
/// - Clean response (`online && !hasError`): silent.
/// - Reported problem: pull EOT 2/3/4, throw [PrinterDeviceException]
///   with the assembled [PrinterStatusDetail].
/// - Timeout AND probe said the printer does support DLE EOT: throw
///   [PrinterDeviceException] with an empty detail (`isUnknown == true`)
///   so callers can show a generic "printer stopped responding" message.
/// - Timeout AND probe said it doesn't (or probe never ran): silent —
///   we have no way to tell whether the print succeeded.
///
/// [bytesWritten] sizes the EOT 1 timeout: thermal printers process the
/// command in-line with their print queue, so on a long job the response
/// only arrives once the queue drains.  Internal helper — intentionally
/// NOT exported from the library barrel file.
Future<void> verifyAfterWrite({
  required Future<int> Function(int n, int timeoutMs) queryStatusByteFn,
  required int bytesWritten,
  required bool? supportsRealtimeStatus,
  required String tag,
}) async {
  // Base 1 s + ~0.4 ms per byte (~2.5 KB/s effective print throughput).
  final int baseTimeoutMs = 1000 + (bytesWritten * 2 ~/ 5);

  final int eot1 = await queryStatusByteFn(1, baseTimeoutMs);
  if (eot1 < 0) {
    if (supportsRealtimeStatus == true) {
      PrinterLogger.error(
        tag,
        'Post-write: status query timed out from a printer that '
        'normally responds — printer is likely in error state',
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

  final PrinterStatus status = PrinterStatus.fromByte(eot1);
  if (status.online && !status.hasError) {
    PrinterLogger.debug(tag, 'Post-write: ok ($status)');
    return;
  }

  // Something is wrong — ask for the rest of the detail.  Use a shorter
  // timeout for follow-up queries; the printer is already responding.
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
