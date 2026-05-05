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


