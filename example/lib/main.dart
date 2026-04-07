import 'dart:async';

import 'package:flutter/material.dart';
import 'package:unified_esc_pos_printer/unified_esc_pos_printer.dart';

import 'multi_printer_page.dart';
import 'printer_ui_helpers.dart';
import 'test_ticket_builder.dart';

void main() => runApp(const PrinterDemoApp());

class PrinterDemoApp extends StatelessWidget {
  const PrinterDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ESC/POS Printer Demo',
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
      ),
      home: const PrinterDemoPage(),
    );
  }
}

class PrinterDemoPage extends StatefulWidget {
  const PrinterDemoPage({super.key});

  @override
  State<PrinterDemoPage> createState() => _PrinterDemoPageState();
}

class _PrinterDemoPageState extends State<PrinterDemoPage> {
  final PrinterManager _manager = PrinterManager(
    logLevel: PrinterLogLevel.debug,
  );
  final List<PrinterDevice> _devices = [];

  StreamSubscription<PrinterConnectionState>? _stateSub;
  StreamSubscription<List<PrinterDevice>>? _scanSub;

  PrinterConnectionState _state = PrinterConnectionState.disconnected;
  bool _scanning = false;

  /// Which connection types to scan. Null means scan all.
  PrinterConnectionType? _scanFilter;

  /// Which test parts to include when printing. All 6 by default.
  final Set<int> _selectedParts = {1, 2, 3, 4, 5, 6};

  @override
  void initState() {
    super.initState();
    _stateSub = _manager.stateStream.listen((s) {
      if (mounted) setState(() => _state = s);
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _scanSub?.cancel();
    _manager.dispose();
    super.dispose();
  }

  Future<void> _startScan() async {
    final Set<PrinterConnectionType> types = _scanFilter != null
        ? {_scanFilter!}
        : PrinterConnectionType.values.toSet();

    setState(() {
      _scanning = true;
      _devices.clear();
    });

    _scanSub?.cancel();
    _scanSub = _manager
        .scanAll(
          timeout: Duration(
            seconds: types.contains(PrinterConnectionType.network) ? 30 : 5,
          ),
          types: types,
        )
        .listen(
      (devices) {
        if (mounted) {
          setState(() {
            _devices.clear();
            _devices.addAll(devices);
          });
        }
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

  Future<void> _connectTo(PrinterDevice device) async {
    try {
      await _manager.connect(device);
      _showSnack('Connected to ${device.name}');
    } on PrinterException catch (e) {
      _showSnack('Connection failed: ${e.message}');
    }
  }

  Future<void> _disconnect() async {
    await _manager.disconnect();
    _showSnack('Disconnected');
  }

  Future<void> _printTestTicket() async {
    if (_state != PrinterConnectionState.connected) {
      _showSnack('No printer connected');
      return;
    }

    try {
      final Ticket ticket = await buildTestTicket(_selectedParts);
      await _manager.printTicket(ticket);
      _showSnack('Ticket printed!');
    } on PrinterException catch (e) {
      _showSnack('Print failed: ${e.message}');
    }
  }

  Future<void> _queryStatus() async {
    if (_state != PrinterConnectionState.connected) {
      _showSnack('No printer connected');
      return;
    }

    try {
      final PrinterStatus status = await _manager.queryStatus();
      _showSnack('Status: $status');
    } on PrinterException catch (e) {
      _showSnack('Status query failed: ${e.message}');
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
      );
  }

  @override
  Widget build(BuildContext context) {
    final bool connected = _state == PrinterConnectionState.connected;
    final connectedDevice = _manager.connectedDevice;

    return Scaffold(
      appBar: AppBar(
        title: const Text('ESC/POS Printer Demo'),
        actions: [
          IconButton(
            icon: const Icon(Icons.devices),
            tooltip: 'Multi-Printer Test',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const MultiPrinterPage(),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: _ConnectionStatusBar(
              state: _state,
              device: connectedDevice,
              onDisconnect: connected ? _disconnect : null,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ScanFilterChip(
                    label: 'All',
                    icon: Icons.select_all,
                    selected: _scanFilter == null,
                    onTap: () => setState(() => _scanFilter = null),
                  ),
                  for (final type in PrinterConnectionType.values)
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _scanning ? null : _startScan,
                icon: _scanning
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(filterIcon(_scanFilter)),
                label: Text(
                  _scanning
                      ? 'Scanning ${filterLabel(_scanFilter)}...'
                      : 'Scan ${filterLabel(_scanFilter)}',
                ),
              ),
            ),
          ),
          Expanded(
            child: _devices.isEmpty
                ? Center(
                    child: Text(
                      _scanning
                          ? 'Searching for printers...'
                          : 'No printers found. Tap Scan.',
                    ),
                  )
                : ListView.builder(
                    itemCount: _devices.length,
                    itemBuilder: (context, i) {
                      final device = _devices[i];
                      final bool isActive = _manager.connectedDevice == device;
                      return ListTile(
                        leading: Icon(iconForDevice(device)),
                        title: Text(
                          device.name,
                          style: TextStyle(
                            fontWeight:
                                isActive ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                        subtitle: Text(subtitleForDevice(device)),
                        trailing:
                            isActive ? const Icon(Icons.check_circle) : null,
                        selected: isActive,
                        selectedTileColor: Colors.grey.withValues(alpha: 0.1),
                        onTap: connected || _scanning
                            ? null
                            : () => _connectTo(device),
                      );
                    },
                  ),
          ),
          Container(
            padding: EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.02),
                  blurRadius: 3,
                  offset: const Offset(0, -2),
                )
              ],
            ),
            child: Column(
              children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: FilterChip(
                          label: const Text('All'),
                          selected: _selectedParts.length == kTestPartLabels.length,
                          onSelected: (_) => setState(() {
                            if (_selectedParts.length == kTestPartLabels.length) {
                              _selectedParts.clear();
                            } else {
                              _selectedParts.addAll(kTestPartLabels.keys);
                            }
                          }),
                        ),
                      ),
                      for (final entry in kTestPartLabels.entries)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: FilterChip(
                            label: Text(entry.value),
                            selected: _selectedParts.contains(entry.key),
                            onSelected: (selected) => setState(() {
                              selected
                                  ? _selectedParts.add(entry.key)
                                  : _selectedParts.remove(entry.key);
                            }),
                          ),
                        ),
                    ],
                  ),
                ),
                SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _scanning || !connected || _selectedParts.isEmpty
                            ? null
                            : _printTestTicket,
                        icon: const Icon(Icons.receipt_long),
                        label: const Text('Print Test Ticket'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonalIcon(
                      onPressed: connected ? _queryStatus : null,
                      icon: const Icon(Icons.info_outline),
                      label: const Text('Status'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectionStatusBar extends StatelessWidget {
  const _ConnectionStatusBar({
    required this.state,
    required this.device,
    required this.onDisconnect,
  });

  final PrinterConnectionState state;
  final PrinterDevice? device;
  final VoidCallback? onDisconnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bool connected = state == PrinterConnectionState.connected;
    final bool connecting = state == PrinterConnectionState.connecting;
    final bool error = state == PrinterConnectionState.error;

    final Color bgColor;
    final Color fgColor;
    final IconData icon;
    final String label;

    if (connected) {
      bgColor = Colors.green.shade50;
      fgColor = Colors.green.shade800;
      icon = Icons.check_circle;
      label = device?.name ?? 'Connected';
    } else if (connecting) {
      bgColor = Colors.orange.shade50;
      fgColor = Colors.orange.shade800;
      icon = Icons.sensors_rounded;
      label = 'Connecting...';
    } else if (error) {
      bgColor = Colors.red.shade50;
      fgColor = Colors.red.shade800;
      icon = Icons.error;
      label = 'Connection error';
    } else {
      bgColor =
          theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5);
      fgColor = theme.colorScheme.onSurfaceVariant;
      icon = Icons.print_disabled;
      label = 'No printer connected';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, color: fgColor, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: fgColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (connected && device != null)
                  Text(
                    '${device!.connectionType.name.toUpperCase()} - ${_deviceDetail(device!)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: fgColor.withValues(alpha: 0.7),
                    ),
                  ),
              ],
            ),
          ),
          if (connected)
            TextButton(
              onPressed: onDisconnect,
              child: Text('Disconnect', style: TextStyle(color: fgColor)),
            ),
        ],
      ),
    );
  }

  String _deviceDetail(PrinterDevice device) {
    return switch (device) {
      NetworkPrinterDevice(host: final h, port: final p) => '$h:$p',
      BlePrinterDevice(deviceId: final id) => id,
      BluetoothPrinterDevice(address: final addr) => addr,
      UsbPrinterDevice(identifier: final id) => id,
      _ => '',
    };
  }
}

