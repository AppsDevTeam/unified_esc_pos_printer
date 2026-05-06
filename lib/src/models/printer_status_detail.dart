/// Detailed printer status, parsed from up to four DLE EOT real-time
/// status queries (ESC/POS): n=1 (basic), n=2 (offline cause),
/// n=3 (error cause), n=4 (paper sensor).
///
/// Every field is nullable because:
/// - Some printers do not respond to every query.
/// - Some transports (notably BLE without an RX characteristic) cannot read
///   the response byte and only confirm the write was accepted.
/// - A null field means **unknown**, not "fine".
///
/// When interpreting the result, always check that any field you rely on
/// is non-null. A `hasError == true` with everything else null still means
/// "the printer is in some error state" — fall back to a generic message
/// in that case.
class PrinterStatusDetail {
  // ── DLE EOT 1 — printer status ────────────────────────────────────────────

  /// True when the printer responded to DLE EOT n=1.
  /// If `false`, [online] / [hasError] are meaningless.
  final bool basicSupported;

  /// Printer is online and ready to accept data. Null when EOT 1 was not
  /// answered.
  final bool? online;

  /// Printer reports any error condition (cover open, paper jam, …).
  /// Null when EOT 1 was not answered.
  final bool? hasError;

  /// True when the cash drawer connector pin 3 is high.
  final bool? drawerKickHigh;

  // ── DLE EOT 2 — offline cause ─────────────────────────────────────────────

  /// Cover (or platen) is open. Null when EOT 2 was not answered.
  final bool? coverOpen;

  /// Printer is paused because paper was fed by pressing the FEED button.
  final bool? paperFedByButton;

  /// Printer is offline because it is out of paper (also confirmed by EOT 4).
  final bool? offlineBecausePaperEnd;

  /// Printer is offline because of an error condition (refer to EOT 3).
  final bool? offlineBecauseError;

  // ── DLE EOT 3 — error cause ───────────────────────────────────────────────

  /// Mechanical error during paper feed (motor stalled, gears jammed, …).
  final bool? mechanicalError;

  /// Auto-cutter is jammed or has another error.
  final bool? cutterError;

  /// Unrecoverable error — the printer needs a power cycle / service.
  final bool? unrecoverableError;

  /// Recoverable error that can be cleared automatically (typically head
  /// overheat or motor overheat).
  final bool? autoRecoverableError;

  // ── DLE EOT 4 — paper sensor ──────────────────────────────────────────────

  /// Roll paper near-end sensor reports paper running low.
  final bool? paperNearEnd;

  /// Roll paper end sensor reports no paper present.
  final bool? paperEnd;

  const PrinterStatusDetail({
    this.basicSupported = false,
    this.online,
    this.hasError,
    this.drawerKickHigh,
    this.coverOpen,
    this.paperFedByButton,
    this.offlineBecausePaperEnd,
    this.offlineBecauseError,
    this.mechanicalError,
    this.cutterError,
    this.unrecoverableError,
    this.autoRecoverableError,
    this.paperNearEnd,
    this.paperEnd,
  });

  /// Build from raw DLE EOT response bytes. Pass `-1` (or `null`) for any
  /// query that did not respond / is not supported.
  ///
  /// All four bytes share the same fixed-bit layout:
  /// - bit 0 = 0
  /// - bit 1 = 1
  /// - bit 4 = 1
  /// - bit 7 = 0
  ///
  /// The remaining bits 2/3/5/6 carry the per-query payload below.
  factory PrinterStatusDetail.fromBytes({
    int? eot1,
    int? eot2,
    int? eot3,
    int? eot4,
  }) {
    final bool eot1Ok = eot1 != null && eot1 >= 0;
    final bool eot2Ok = eot2 != null && eot2 >= 0;
    final bool eot3Ok = eot3 != null && eot3 >= 0;
    final bool eot4Ok = eot4 != null && eot4 >= 0;

    return PrinterStatusDetail(
      basicSupported: eot1Ok,
      online: eot1Ok ? (eot1 & 0x08) == 0 : null,
      hasError: eot1Ok ? (eot1 & 0x20) != 0 : null,
      drawerKickHigh: eot1Ok ? (eot1 & 0x04) != 0 : null,
      // EOT 2 — offline cause
      coverOpen: eot2Ok ? (eot2 & 0x04) != 0 : null,
      paperFedByButton: eot2Ok ? (eot2 & 0x08) != 0 : null,
      offlineBecausePaperEnd: eot2Ok ? (eot2 & 0x20) != 0 : null,
      offlineBecauseError: eot2Ok ? (eot2 & 0x40) != 0 : null,
      // EOT 3 — error cause
      mechanicalError: eot3Ok ? (eot3 & 0x04) != 0 : null,
      cutterError: eot3Ok ? (eot3 & 0x08) != 0 : null,
      unrecoverableError: eot3Ok ? (eot3 & 0x20) != 0 : null,
      autoRecoverableError: eot3Ok ? (eot3 & 0x40) != 0 : null,
      // EOT 4 — paper sensor
      paperNearEnd: eot4Ok ? (eot4 & 0x0C) != 0 : null,
      paperEnd: eot4Ok ? (eot4 & 0x60) != 0 : null,
    );
  }

  /// True when every DLE EOT query came back unanswered. Useful as a
  /// "we have no idea what's wrong" check.
  bool get isUnknown =>
      !basicSupported &&
      coverOpen == null &&
      paperFedByButton == null &&
      offlineBecausePaperEnd == null &&
      offlineBecauseError == null &&
      mechanicalError == null &&
      cutterError == null &&
      unrecoverableError == null &&
      autoRecoverableError == null &&
      paperNearEnd == null &&
      paperEnd == null;

  /// True when **any** known field reports a problem. Conservative —
  /// returns false when everything is null (unknown).
  bool get hasAnyProblem {
    if (hasError == true) return true;
    if (online == false) return true;
    if (coverOpen == true) return true;
    if (offlineBecausePaperEnd == true) return true;
    if (offlineBecauseError == true) return true;
    if (mechanicalError == true) return true;
    if (cutterError == true) return true;
    if (unrecoverableError == true) return true;
    if (autoRecoverableError == true) return true;
    if (paperEnd == true) return true;
    return false;
  }

  @override
  String toString() {
    final List<String> flags = <String>[
      if (online == false) 'offline',
      if (hasError == true) 'error',
      if (coverOpen == true) 'coverOpen',
      if (paperFedByButton == true) 'paperFeedButton',
      if (offlineBecausePaperEnd == true) 'offlinePaperEnd',
      if (offlineBecauseError == true) 'offlineErrorCause',
      if (mechanicalError == true) 'mechanicalError',
      if (cutterError == true) 'cutterError',
      if (unrecoverableError == true) 'unrecoverableError',
      if (autoRecoverableError == true) 'autoRecoverableError',
      if (paperNearEnd == true) 'paperNearEnd',
      if (paperEnd == true) 'paperEnd',
    ];
    if (flags.isEmpty) {
      if (isUnknown) return 'PrinterStatusDetail(unknown)';
      return 'PrinterStatusDetail(ok)';
    }
    return 'PrinterStatusDetail(${flags.join(', ')})';
  }
}
