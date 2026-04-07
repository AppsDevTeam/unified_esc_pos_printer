/// Result of a DLE EOT real-time status query sent to the printer.
///
/// Printers that support DLE EOT respond with a single byte whose bits
/// encode the current state.  Printers that do not support it simply
/// never respond, which is reported as [PrinterStatus.timeout].
class PrinterStatus {
  /// Whether the printer responded to the status query at all.
  /// If `false`, all other fields are meaningless — the printer either
  /// does not support DLE EOT or is unreachable.
  final bool supported;

  /// Printer is online and ready to accept data.
  final bool online;

  /// Printer has an error condition (cover open, paper jam, etc.).
  final bool hasError;

  /// The raw status byte returned by the printer, or -1 if unsupported.
  final int rawByte;

  const PrinterStatus._({
    required this.supported,
    required this.online,
    required this.hasError,
    required this.rawByte,
  });

  /// Printer responded — parse the DLE EOT n=1 response byte.
  ///
  /// Bit layout (per ESC/POS specification):
  /// - Bit 0: fixed 0
  /// - Bit 1: fixed 1
  /// - Bit 2: 0 = connector pin 3 low, 1 = high (drawer state)
  /// - Bit 3: 0 = online, 1 = offline
  /// - Bit 4: fixed 1
  /// - Bit 5: 0 = no error, 1 = error condition exists
  /// - Bit 6: 0 = no recoverable error, 1 = recoverable error
  /// - Bit 7: fixed 0
  factory PrinterStatus.fromByte(int byte) {
    return PrinterStatus._(
      supported: true,
      online: (byte & 0x08) == 0,
      hasError: (byte & 0x20) != 0,
      rawByte: byte,
    );
  }

  /// Printer did not respond within the timeout.
  static const PrinterStatus timeout = PrinterStatus._(
    supported: false,
    online: false,
    hasError: false,
    rawByte: -1,
  );

  /// The connector does not support DLE EOT status queries (e.g. Windows
  /// Print Spooler).
  static const PrinterStatus unsupported = PrinterStatus._(
    supported: false,
    online: false,
    hasError: false,
    rawByte: -2,
  );

  @override
  String toString() {
    if (rawByte == -2) return 'PrinterStatus(unsupported)';
    if (!supported) return 'PrinterStatus(timeout)';
    return 'PrinterStatus(online: $online, hasError: $hasError, raw: 0x${rawByte.toRadixString(16)})';
  }
}
