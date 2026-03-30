/// Log level for the printer library.
enum PrinterLogLevel {
  /// No logging.
  none,

  /// Errors only.
  error,

  /// Warnings and errors.
  warning,

  /// Informational messages, warnings, and errors.
  info,

  /// All messages including verbose debug output.
  debug,
}
