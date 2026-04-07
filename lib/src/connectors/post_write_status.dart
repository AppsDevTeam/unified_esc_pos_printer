import '../models/printer_status.dart';
import '../utils/printer_logger.dart';

/// Sends a DLE EOT status query after a write and logs the result.
///
/// [queryFn] performs the platform-specific status query and returns the raw
/// status byte (or -1 on timeout).  [bytesWritten] is used to calculate a
/// proportional timeout so slow printers have enough time to respond.
/// [tag] is the log tag forwarded to [PrinterLogger].
///
/// This is an internal helper shared by all connector implementations.
/// It is intentionally NOT exported from the library barrel file.
Future<PrinterStatus> postWriteStatusQuery({
  required Future<int> Function(int timeoutMs) queryFn,
  required int bytesWritten,
  required String tag,
}) async {
  // Base 1 s + ~0.4 ms per byte (~2.5 KB/s effective print throughput).
  final int timeoutMs = 1000 + (bytesWritten * 2 ~/ 5);
  final int rawStatus = await queryFn(timeoutMs);
  final PrinterStatus status = rawStatus >= 0
      ? PrinterStatus.fromByte(rawStatus)
      : PrinterStatus.timeout;
  PrinterLogger.debug(tag, 'Post-write status: $status');
  return status;
}
