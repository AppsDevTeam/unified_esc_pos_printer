## 3.7.1

- Signal `endOfStream` after BLE / Bluetooth Classic scan stops (Android + iOS) — closes the Dart-side broadcast controller so a subsequent `subscription.cancel()` becomes a no-op instead of producing "No active stream to cancel" noise in `FlutterError.reportError` (and Crashlytics).

## 3.7.0

- Add typed exception subclasses for common failure modes:
  - `PrinterTimeoutException`, `PrinterUnreachableException`, `PrinterPlatformUnsupportedException`, `PrinterDisconnectedDuringOperationException` under `PrinterConnectionException`
  - `PrinterNetworkUnavailableException` under `PrinterScanException`
  - new `PrinterDeviceException` for hardware error conditions reported by the printer (cover open, paper out, paper jam, overheat, cutter error, …) carrying a `PrinterStatusDetail`
- Add `PrinterStatusDetail` model parsing DLE EOT 1/2/3/4 responses: `coverOpen`, `paperEnd`/`paperNearEnd`, `paperFedByButton`, `mechanicalError`/`cutterError`, `unrecoverableError`/`autoRecoverableError`, …
- Add `PrinterConnector.queryStatusByte(n, …)` and `PrinterManager.queryStatusDetail()` for issuing arbitrary DLE EOT real-time status queries
- Add connect-time DLE EOT probe and `PrinterConnector.supportsRealtimeStatus` so post-write timeouts are only escalated on printers that actually implement the protocol
- Post-write status check now throws `PrinterDeviceException` with detailed flags when the printer reports an error condition; previously these were only logged
- Bluetooth Classic native (Android): `btQueryStatus` accepts `n` parameter for DLE EOT 1..4 queries; Windows (no-op) and other transports gracefully degrade to `-1`
- Use a broadcast view of `Socket` / `UsbPort.inputStream` so the connect-time probe and post-write verify can both read responses without "Stream has already been listened to"
- Network connector now performs post-write status verification (was previously skipped)

## 3.6.1

- Switch `flutter_libserialport` to AppsDevTeam fork v0.6.1 with 16 KB page-size aligned Android `.so` (required by Android 16, supported on Android 15)

## 3.6.0

- Add BLE flow control: `maxChunkSize` and `chunkDelay` on `BleConnector`
- Add debug receipt image to example test parts

## 3.5.0

- Fix image rasterization and operator precedence in `Generator`
- Wait for BT adapter on iOS before BLE scan/connect
- Add platform support check for connection types

## 3.4.0

- Add public `queryStatus()` across all connectors (BLE, Bluetooth Classic, Network, USB)
- Add `PrinterStatus` model for DLE EOT status parsing
- Support multiple concurrent connections (BLE, Bluetooth Classic, Windows)
- Add multi-printer example page
- Match Bluetooth Classic write behavior to `print_bluetooth_thermal`

## 3.3.1

- Add `stopAllScans()` and wrap scan generators in try/finally
- Fix `PlatformException` when cancelling scan stream after native timeout

## 3.3.0

- Add configurable debug logging via `PrinterManager` `logLevel` parameter
- Replace `network_info_plus` with `dart:io NetworkInterface` for iOS compatibility
- Add iOS example signing config

## 3.2.0

- Fix `NetworkConnector` race condition where scan events were lost before listener attached
- Use single-subscription `StreamController` in `scanAll` to buffer events until listener subscribes
- Throw `PrinterScanException` instead of silent return when WiFi IP is unavailable
- Use full scan timeout for each TCP probe (was hardcoded 500 ms)
- Update release script to use git ref and fix README dependency format

## 3.1.0

- Internal release (no user-facing changes)

## 3.0.0

- BREAKING: Rename `TextStyles` to `PrintTextStyle`
- BREAKING: Rename `styles` parameter to `style` in ticket/generator APIs and `PrintColumn`
- BREAKING: Rename `textStyle` to `style` in `Ticket.textRaster(...)` and `renderTextLinesAsImages(...)`
- Update README and example app to use the new names

## 2.0.0

- BREAKING: Remove `align` from `TextStyles`
- Add explicit `align` parameter to `Ticket.text(...)` and `Ticket.textEncoded(...)`
- Add `PrintColumn.align` for row/column alignment
- Update `Generator` alignment flow to use explicit alignment parameters
- Update `README.md` and example app usage to the new alignment API

## 1.0.3

- Rename `spaceBetweenRows` to `columnGap` for clarity
- Only apply `columnGap` between columns, not after the last column
- Change default `columnGap` from 5 to 1

## 1.0.2

- Improved Pub Score

## 1.0.1

- Update README.md.

## 1.0.0

- Initial release.


