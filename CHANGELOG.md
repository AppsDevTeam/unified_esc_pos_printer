## 3.8.3

- **iOS BLE: prefer write-without-response.** `BleManager.selectCharacteristic` now enables write-without-response whenever the TX characteristic advertises it, even if it also supports write-with-response (most ESC/POS printers expose both). With-response forced a per-chunk ATT ack round-trip — one packet per connection event — and, because iOS reports `maximumWriteValueLength(for: .withResponse) == 512`, chunks larger than the negotiated ATT MTU were sent via the ATT prepared/long-write procedure, which some printer GATT stacks mishandle (corrupting long raster jobs). Without-response sends single-MTU packets that iOS pipelines several per connection event, an order of magnitude faster, and sidesteps the prepared-write path entirely. Android is unchanged (it deliberately keeps with-response, where its `onCharacteristicWrite` callback provides per-chunk backpressure).
- **`BleConnector.syncEveryBytes` flow-control barrier (default 4096).** On the write-without-response fast path the connector now forces one write-with-response roughly every `syncEveryBytes` bytes (and on the final chunk). The blocking ack drains the printer's receive buffer and bounds how far the unacked burst runs ahead of a slow printer, preventing the silent receive-buffer overflow that drops bytes and corrupts long raster jobs — while retaining ~80–90% of without-response throughput. Set to `null`/`0` to disable.

## 3.8.2

- **`PrinterDisconnectedDuringOperationException` for silent printers.** When `verifyBeforeWrite` / `verifyAfterWrite` time out on DLE EOT 1 (after retry) from a printer that previously responded — power cut, network drop, frozen firmware — the helpers now throw `PrinterDisconnectedDuringOperationException` instead of `PrinterDeviceException` with an empty status detail. Callers that map exceptions to user messages can show "printer disconnected / check it's powered on" semantics for this case rather than the "hardware fault" copy a `PrinterDeviceException` implies.

## 3.8.1

- **NetworkConnector scan now covers all reachable /24 subnets**, not just the first non-loopback interface returned by `NetworkInterface.list()`. Multi-homed Android devices (Sunmi D3 Pro with USB tether + Wi-Fi, phones with VPN + Wi-Fi, …) often list secondary interfaces before the Wi-Fi one — picking just the first meant scanning the wrong subnet and missing printers reachable via Wi-Fi. Probes across all subnets run concurrently, so scan duration stays bounded by the per-probe timeout.

## 3.8.0

- **Comprehensive printer status detection.** `verifyBeforeWrite` and `verifyAfterWrite` now always query the full DLE EOT family (n=1, 2, 3, 4) on every status check, not just n=1. Some firmwares (Sunmi NT212 confirmed) leave the EOT 1 error bit clear even when paper is out or the cover is open, signalling the fault only in EOT 4 (paper sensor); asking all four every time is the only protocol-portable way to catch every state.
- **Automatic Status Back (ASB) support.** New `AsbMonitor` enables `GS a n` on connect and forwards 4-byte status packets pushed by the printer when its state changes (paper-out, cover-open, recovery). When ASB is negotiated successfully, pre/post-write gates on `latestAsbStatus.hasAnyProblem` and the connector skips DLE EOT polling (the two protocols share the same byte stream and can't coexist).
- **BLE real-time status.** `BleConnector.queryStatusByte` and a new `queryRawByte` read the response byte from the notify characteristic discovered during connect — BLE is no longer write-only. `probeRealtimeStatus` runs after ASB negotiation fails, so BLE has feature parity with Network / USB / Bluetooth Classic. Android BleManager discovers notify alongside TX and enables notifications via CCCD; iOS BleManager.swift gained the same wire-up (`setNotifyValue(true, for:)` + `didUpdateValueFor` delegate).
- **Incoming bytes EventChannel.** New `com.elriztechnology.unified_esc_pos_printer/incoming_bytes` channel forwards BLE notify-characteristic / Bluetooth Classic RFCOMM bytes to the Dart side for ASB parsing and raw status reads. Android plugin emits per-device events from `BleManager` and `BluetoothClassicManager`; iOS plugin emits from `BleManager` (Bluetooth Classic is not supported on iOS).
- **Late-binding `supportsRealtimeStatus`.** The connect-time probe can return `false` if the printer happened to be silent at that moment (paper-out at boot, briefly busy). The pre-write probe now flips the field to `true` the first time the printer answers — so a printer that was silent at connect still gets reliable detection on the first write that wakes it up.
- **`writeBytes(verifyStatus:)` flag** for callers that want to bypass the pre/post-write status check on short control sequences (drawer kick, init bytes, …). Exposed all the way up through `PrinterManager.printBytes(verifyStatus:)`.
- **`PrinterManager.queryRawByte(request, …)`** escape hatch for experimenting with non-standard status protocols (e.g. `GS r 1` paper sensor query, `ESC v` legacy paper-end query, vendor-specific commands) without having to add a dedicated connector method per command.
- **Pre-write status check.** New `verifyBeforeWrite` mirrors the post-write helper but runs before bytes hit the wire — so a printer reporting an error condition is rejected without wasting transfer time on a job that can't print. EOT 1 probe with 300 ms first try + 1500 ms retry; on success, pulls 2/3/4 with 500 ms short timeouts.
- **Post-write retry.** `verifyAfterWrite` retries the EOT 1 query once with a 3 s budget when the first probe times out on a printer that previously responded — thermal heads can stall briefly on cutter/feed operations and we don't want to surface that as a fatal error. After EOT 1 responds, always pulls 2/3/4 unconditionally (was previously gated on EOT 1 reporting error).
- **`NetworkConnector` reactive reconnect.** Watches `socket.done` and tears the connector state down when the printer closes its side (Xprinter-style idle timeout, network glitch); the next print triggers a fresh connect via `PrinterManager._ensureConnected`. The handler captures the socket reference and bails when the connector has moved on to a new connection, so a reconnect arriving between `disconnect()` returning and the old socket done firing doesn't nuke the fresh state.
- **`UsbConnectorImpl` (Android) diagnostics.** Surface device VID/PID, manufacturer/product strings, serial-type probe outcomes, and final inputStream availability in `info`-level logs so diagnosing USB Printer Class compatibility takes one connect cycle of log output.
- **Bumps `usb_serial` to v0.8.0** which claims the bulk IN endpoint on USB Printer Class devices, enabling DLE EOT readback on USB for bidirectional printers (`protocol=2/3`, IEEE 1284.4 compatible).

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


