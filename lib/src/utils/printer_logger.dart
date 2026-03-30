import 'dart:developer' as dev;

import 'printer_log_level.dart';

/// Internal logger for the unified_esc_pos_printer library.
///
/// Not exported — configured only via [PrinterManager] constructor.
class PrinterLogger {
  PrinterLogger._();

  static PrinterLogLevel _level = PrinterLogLevel.none;

  static void Function(PrinterLogLevel level, String tag, String message)?
      _onLog;

  /// Called by [PrinterManager] to configure logging.
  static void configure({
    required PrinterLogLevel level,
    void Function(PrinterLogLevel level, String tag, String message)? onLog,
  }) {
    _level = level;
    _onLog = onLog;
  }

  static void _log(
    PrinterLogLevel messageLevel,
    String tag,
    String message,
  ) {
    if (_level == PrinterLogLevel.none) return;
    if (messageLevel.index > _level.index) return;

    if (_onLog != null) {
      _onLog!(messageLevel, tag, message);
      return;
    }

    dev.log(
      '[$tag] $message',
      name: 'PrinterSDK',
      level: switch (messageLevel) {
        PrinterLogLevel.error => 1000,
        PrinterLogLevel.warning => 900,
        PrinterLogLevel.info => 800,
        PrinterLogLevel.debug => 500,
        PrinterLogLevel.none => 0,
      },
    );
  }

  /// Log an error message.
  static void error(String tag, String message) =>
      _log(PrinterLogLevel.error, tag, message);

  /// Log a warning message.
  static void warning(String tag, String message) =>
      _log(PrinterLogLevel.warning, tag, message);

  /// Log an informational message.
  static void info(String tag, String message) =>
      _log(PrinterLogLevel.info, tag, message);

  /// Log a debug message.
  static void debug(String tag, String message) =>
      _log(PrinterLogLevel.debug, tag, message);
}
