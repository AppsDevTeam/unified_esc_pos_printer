import '../exceptions/printer_exception.dart';
import '../models/printer_status.dart';
import '../models/printer_status_detail.dart';
import '../utils/printer_logger.dart';

/// Confirms a write completed cleanly by querying the printer's real-time
/// status and, if anything looks off, gathering full DLE EOT 1/2/3/4 detail
/// before throwing [PrinterDeviceException].
///
/// Behavior:
/// - On a clean response (`online && !hasError`): returns silently.
/// - On a missing response (timeout / unsupported transport): logs and
///   returns silently — we cannot tell whether the print succeeded, but
///   no error was raised at the transport layer either.
/// - On any reported problem: pulls DLE EOT 2/3/4 to assemble a
///   [PrinterStatusDetail] and throws [PrinterDeviceException] with that
///   detail attached.
///
/// [bytesWritten] is used to derive a base timeout so slow printers have
/// enough time to acknowledge before we give up.  Internal helper —
/// intentionally NOT exported from the library barrel file.
Future<void> verifyAfterWrite({
  required Future<int> Function(int n, int timeoutMs) queryStatusByteFn,
  required int bytesWritten,
  required String tag,
}) async {
  // Base 1 s + ~0.4 ms per byte (~2.5 KB/s effective print throughput).
  final int baseTimeoutMs = 1000 + (bytesWritten * 2 ~/ 5);

  final int eot1 = await queryStatusByteFn(1, baseTimeoutMs);
  if (eot1 < 0) {
    PrinterLogger.debug(tag, 'Post-write: status query unanswered (transport may not support it)');
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
