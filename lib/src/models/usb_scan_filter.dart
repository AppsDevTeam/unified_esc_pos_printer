/// Decides which USB devices a USB scan reports.
///
/// A USB bus on a POS terminal carries far more than printers — root hubs,
/// internal hubs, network adapters, card readers. Offering all of them in a
/// printer picker invites the user to pick something that can never print,
/// and probing a non-printer with serial drivers is not harmless: the probing
/// control transfers reset a hub and take every device behind it off the bus.
enum UsbScanFilter {
  /// Report only devices that could plausibly be a printer — everything that
  /// is not a hub and exposes a bulk OUT endpoint. This is the default.
  ///
  /// Devices whose descriptors the platform does not report (desktop
  /// platforms, older plugin versions) are kept rather than dropped, so the
  /// filter can never hide a printer it failed to classify.
  printerCandidatesOnly,

  /// Report every USB device the platform enumerates, unclassified. Use when
  /// a printer is not recognised by [printerCandidatesOnly] and the user
  /// needs to pick it by hand.
  all,
}
