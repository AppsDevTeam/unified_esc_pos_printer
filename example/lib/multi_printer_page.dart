import 'dart:async';

import 'package:flutter/material.dart';
import 'package:unified_esc_pos_printer/unified_esc_pos_printer.dart';

import 'printer_ui_helpers.dart';
import 'test_ticket_builder.dart';

/// Demonstrates printing the same test ticket to multiple printers
/// simultaneously, each via its own [PrinterManager] instance.
class MultiPrinterPage extends StatefulWidget {
  const MultiPrinterPage({super.key});

  @override
  State<MultiPrinterPage> createState() => _MultiPrinterPageState();
}

enum _DeviceStatus { idle, connecting, connected, printing, done, error }

class _DeviceEntry {
  final PrinterDevice device;
  bool selected;
  _DeviceStatus status;
  String? errorMessage;

  _DeviceEntry({required this.device})
      : selected = false,
        status = _DeviceStatus.idle;
}

class _MultiPrinterPageState extends State<MultiPrinterPage> {
  final PrinterManager _scanner = PrinterManager(logLevel: PrinterLogLevel.debug);

  final List<_DeviceEntry> _entries = [];
  bool _scanning = false;
  bool _printing = false;
  PrinterConnectionType? _scanFilter;

  /// Which test parts to include when printing.
  final Set<int> _selectedParts = {1, 2, 3, 4, 5, 6};

  static const Map<int, String> _partLabels = {
    1: 'Image & Text',
    2: 'Row & Columns',
    3: 'Multilingual',
    4: 'Text Raster',
    5: 'Barcodes',
    6: 'QR, Beep & Cashdrawer',
  };

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  // ── Scanning ───────────────────────────────────────────────────────────

  Future<void> _startScan() async {
    final Set<PrinterConnectionType> types =
        _scanFilter != null ? {_scanFilter!} : PrinterConnectionType.supportedOnCurrentPlatform;

    setState(() {
      _scanning = true;
      _entries.clear();
    });

    _scanner
        .scanAll(
      timeout: Duration(
        seconds: types.contains(PrinterConnectionType.network) ? 30 : 5,
      ),
      types: types,
    )
        .listen(
      (devices) {
        if (!mounted) return;
        setState(() {
          // Merge — keep existing entries (preserve selection), add new ones.
          final Set<String> existing = _entries.map((_DeviceEntry e) => deviceKey(e.device)).toSet();
          for (final PrinterDevice d in devices) {
            if (!existing.contains(deviceKey(d))) {
              _entries.add(_DeviceEntry(device: d));
            }
          }
        });
      },
      onDone: () {
        if (mounted) setState(() => _scanning = false);
      },
      onError: (Object error) {
        if (mounted) {
          setState(() => _scanning = false);
          _showSnack('Scan error: $error');
        }
      },
    );
  }

  // ── Printing ───────────────────────────────────────────────────────────

  Future<void> _printToSelected() async {
    final List<_DeviceEntry> targets = _entries.where((_DeviceEntry e) => e.selected).toList();

    if (targets.isEmpty) {
      _showSnack('No printers selected');
      return;
    }

    // Stop any running scan — BT adapter can't scan and connect simultaneously.
    if (_scanning) {
      await _scanner.stopAllScans();
      setState(() => _scanning = false);
      // Give the BT adapter time to release scan resources before connecting.
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }

    setState(() => _printing = true);

    // Build ticket once, share bytes across all printers.
    final Ticket ticket = await buildTestTicket(_selectedParts);
    final List<int> ticketBytes = ticket.bytes;
    debugPrint('Ticket size: ${ticketBytes.length} bytes');

    // Print to all selected printers in parallel.
    final List<Future<void>> jobs = targets.map((_DeviceEntry entry) async {
      final PrinterManager manager = PrinterManager(logLevel: PrinterLogLevel.debug);

      try {
        if (mounted) setState(() => entry.status = _DeviceStatus.connecting);
        await manager.connect(entry.device);

        if (mounted) setState(() => entry.status = _DeviceStatus.printing);
        await manager.printBytes(ticketBytes);

        if (mounted) setState(() => entry.status = _DeviceStatus.done);
      } catch (e) {
        if (mounted) {
          setState(() {
            entry.status = _DeviceStatus.error;
            entry.errorMessage = e.toString();
          });
        }
      } finally {
        try {
          await manager.disconnect();
        } catch (_) {}
        try {
          await manager.dispose();
        } catch (_) {}
      }
    }).toList();

    await Future.wait(jobs);

    if (mounted) {
      final int ok = targets.where((_DeviceEntry e) => e.status == _DeviceStatus.done).length;
      final int fail = targets.where((_DeviceEntry e) => e.status == _DeviceStatus.error).length;
      _showSnack('Done: $ok OK, $fail failed');
      setState(() => _printing = false);
    }
  }

  // ── UI helpers ─────────────────────────────────────────────────────────

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
      );
  }

  Widget _statusIcon(_DeviceStatus status) {
    return switch (status) {
      _DeviceStatus.idle => const SizedBox.shrink(),
      _DeviceStatus.connecting => const SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      _DeviceStatus.connected => const Icon(Icons.link, color: Colors.orange, size: 20),
      _DeviceStatus.printing => const SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blue),
        ),
      _DeviceStatus.done => const Icon(Icons.check_circle, color: Colors.green, size: 20),
      _DeviceStatus.error => const Icon(Icons.error, color: Colors.red, size: 20),
    };
  }

  @override
  Widget build(BuildContext context) {
    final int selectedCount = _entries.where((_DeviceEntry e) => e.selected).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Multi-Printer Test'),
      ),
      body: Column(
        children: [
          // Filter chips
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ScanFilterChip(
                    label: 'All',
                    icon: filterIcon(null),
                    selected: _scanFilter == null,
                    onTap: () => setState(() => _scanFilter = null),
                  ),
                  for (final PrinterConnectionType type in PrinterConnectionType.values)
                    if (type.isSupportedOnCurrentPlatform)
                      ScanFilterChip(
                        label: filterLabel(type),
                        icon: filterIcon(type),
                        selected: _scanFilter == type,
                        onTap: () => setState(() => _scanFilter = type),
                      ),
                ],
              ),
            ),
          ),

          // Scan button
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _scanning || _printing ? null : _startScan,
                icon: _scanning
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(filterIcon(_scanFilter)),
                label: Text(
                  _scanning ? 'Scanning ${filterLabel(_scanFilter)}...' : 'Scan ${filterLabel(_scanFilter)}',
                ),
              ),
            ),
          ),

          // Device list with checkboxes
          Expanded(
            child: _entries.isEmpty
                ? Center(
                    child: Text(
                      _scanning ? 'Searching for printers...' : 'No printers found. Tap Scan.',
                    ),
                  )
                : ListView.builder(
                    itemCount: _entries.length,
                    itemBuilder: (BuildContext context, int i) {
                      final _DeviceEntry entry = _entries[i];
                      return CheckboxListTile(
                        value: entry.selected,
                        onChanged:
                            _scanning || _printing ? null : (bool? v) => setState(() => entry.selected = v ?? false),
                        secondary: Icon(iconForDevice(entry.device)),
                        title: Text(entry.device.name),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(subtitleForDevice(entry.device)),
                            if (entry.status == _DeviceStatus.error && entry.errorMessage != null)
                              Text(
                                entry.errorMessage ?? '',
                                style: const TextStyle(
                                  color: Colors.red,
                                  fontSize: 12,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                        controlAffinity: ListTileControlAffinity.trailing,
                        isThreeLine: entry.status == _DeviceStatus.error && entry.errorMessage != null,
                      );
                    },
                  ),
          ),

          // Bottom bar — select all + print
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.02),
                  blurRadius: 3,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: Column(
              children: [
                // Part selection
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: FilterChip(
                          label: const Text('All'),
                          selected: _selectedParts.length == _partLabels.length,
                          onSelected: (_) => setState(() {
                            if (_selectedParts.length == _partLabels.length) {
                              _selectedParts.clear();
                            } else {
                              _selectedParts.addAll(_partLabels.keys);
                            }
                          }),
                        ),
                      ),
                      for (final MapEntry<int, String> entry in _partLabels.entries)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: FilterChip(
                            label: Text(entry.value),
                            selected: _selectedParts.contains(entry.key),
                            onSelected: (bool selected) => setState(() {
                              selected ? _selectedParts.add(entry.key) : _selectedParts.remove(entry.key);
                            }),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: _printing
                          ? null
                          : () => setState(() {
                                final bool allSelected = _entries.every((_DeviceEntry e) => e.selected);
                                for (final _DeviceEntry e in _entries) {
                                  e.selected = !allSelected;
                                }
                              }),
                      icon: Icon(
                        _entries.isNotEmpty && _entries.every((_DeviceEntry e) => e.selected)
                            ? Icons.deselect
                            : Icons.select_all,
                      ),
                      label: Text(
                        _entries.isNotEmpty && _entries.every((_DeviceEntry e) => e.selected)
                            ? 'Deselect All'
                            : 'Select All',
                      ),
                    ),
                    const Spacer(),
                    // Per-device status summary
                    for (final _DeviceEntry entry in _entries)
                      if (entry.selected && entry.status != _DeviceStatus.idle)
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: _statusIcon(entry.status),
                        ),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _printing || selectedCount == 0 || _selectedParts.isEmpty ? null : _printToSelected,
                    icon: _printing
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.print),
                    label: Text(
                      _printing ? 'Printing...' : 'Print to $selectedCount printer${selectedCount == 1 ? '' : 's'}',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
