package com.elriztechnology.unified_esc_pos_printer

import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import android.util.Log
import java.io.IOException
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

class BluetoothClassicManager(private val context: Context) {

    companion object {
        // Standard SPP (Serial Port Profile) UUID
        private val SPP_UUID = UUID.fromString("00001101-0000-1000-8000-00805f9b34fb")
    }

    private val bluetoothAdapter: BluetoothAdapter? =
        (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    private val mainHandler = Handler(Looper.getMainLooper())

    private var activity: Activity? = null

    // Scan state
    private var scanEventSink: EventChannel.EventSink? = null
    private val discoveredDevices = mutableListOf<Map<String, String>>()
    private var discoveryReceiver: BroadcastReceiver? = null
    private var discoveryTimeoutRunnable: Runnable? = null

    // Per-device connection state (ConcurrentHashMap because connect() runs
    // on a background thread while write()/disconnect() run on the main thread)
    private val sockets = ConcurrentHashMap<String, BluetoothSocket>()
    private val outputStreams = ConcurrentHashMap<String, OutputStream>()
    private val inputThreads = ConcurrentHashMap<String, Thread>()

    // When true, the monitor thread yields inputStream reads to queryStatus.
    private val queryingStatus = ConcurrentHashMap<String, Boolean>()


    var connectionStateCallback: ((String, String) -> Unit)? = null

    val scanStreamHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            scanEventSink = events
        }

        override fun onCancel(arguments: Any?) {
            scanEventSink = null
        }
    }

    fun setActivity(activity: Activity?) {
        this.activity = activity
    }

    fun getBondedDevices(result: MethodChannel.Result) {
        val adapter = bluetoothAdapter
        if (adapter == null) {
            result.success(emptyList<Map<String, String>>())
            return
        }

        try {
            val bonded = adapter.bondedDevices?.map { device ->
                mapOf(
                    "name" to (device.name ?: device.address),
                    "address" to device.address
                )
            } ?: emptyList()
            result.success(bonded)
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", "Cannot access bonded devices", e.message)
        }
    }

    fun startDiscovery(timeoutMs: Long, result: MethodChannel.Result) {
        val adapter = bluetoothAdapter
        if (adapter == null) {
            result.error("UNAVAILABLE", "Bluetooth adapter not available", null)
            return
        }

        discoveredDevices.clear()
        stopDiscoveryInternal()

        discoveryReceiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                when (intent.action) {
                    BluetoothDevice.ACTION_FOUND -> {
                        val device: BluetoothDevice? =
                            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                        device?.let {
                            val address = it.address
                            if (discoveredDevices.none { d -> d["address"] == address }) {
                                val name = try { it.name } catch (_: SecurityException) { null }

                                discoveredDevices.add(
                                    mapOf(
                                        "name" to (name ?: address),
                                        "address" to address
                                    )
                                )

                                mainHandler.post {
                                    scanEventSink?.success(discoveredDevices.toList())
                                }
                            }
                        }
                    }
                    BluetoothAdapter.ACTION_DISCOVERY_FINISHED -> {
                        stopDiscoveryInternal()
                    }
                }
            }
        }

        val filter = IntentFilter().apply {
            addAction(BluetoothDevice.ACTION_FOUND)
            addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED)
        }

        context.registerReceiver(discoveryReceiver, filter)

        try {
            adapter.startDiscovery()
        } catch (e: SecurityException) {
            stopDiscoveryInternal()
            result.error("PERMISSION_DENIED", "Bluetooth discovery permission denied", e.message)
            return
        }

        // Auto-stop after timeout
        discoveryTimeoutRunnable = Runnable { stopDiscoveryInternal() }
        mainHandler.postDelayed(discoveryTimeoutRunnable!!, timeoutMs)

        result.success(null)
    }

    fun stopDiscovery(result: MethodChannel.Result) {
        stopDiscoveryInternal()
        result.success(null)
    }

    private fun stopDiscoveryInternal() {
        discoveryTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        discoveryTimeoutRunnable = null

        discoveryReceiver?.let {
            try {
                context.unregisterReceiver(it)
            } catch (_: IllegalArgumentException) {
                // Not registered
            }
        }

        discoveryReceiver = null

        try {
            bluetoothAdapter?.cancelDiscovery()
        } catch (_: SecurityException) {}

        // Signal Flutter that no more discovery events are coming. Closes
        // the Dart-side broadcast stream gracefully so a subsequent
        // subscription.cancel() becomes a no-op instead of producing
        // "No active stream to cancel" noise in services-library logs
        // (and Crashlytics).
        mainHandler.post {
            scanEventSink?.endOfStream()
            scanEventSink = null
        }
    }

    fun connect(address: String, timeoutMs: Long, result: MethodChannel.Result) {
        val adapter = bluetoothAdapter
        if (adapter == null) {
            result.error("UNAVAILABLE", "Bluetooth adapter not available", null)
            return
        }

        val device: BluetoothDevice
        try {
            device = adapter.getRemoteDevice(address)
        } catch (e: Exception) {
            result.error("INVALID_ADDRESS", "Invalid Bluetooth address: $address", e.message)
            return
        }

        // Clean up any existing connection for this address
        cleanupConnection(address)

        // Connect on a background thread to avoid blocking the UI
        Thread {
            try {
                // Cancel discovery before connecting (improves reliability)
                try { adapter.cancelDiscovery() } catch (_: SecurityException) {}

                // Try secure RFCOMM first, then insecure, then reflection fallback.
                // Pre-paired devices from OS settings often fail the secure SDP
                // lookup, so fallbacks are essential.
                val sock = try {
                    val s = device.createRfcommSocketToServiceRecord(SPP_UUID)
                    s.connect()
                    s
                } catch (_: IOException) {
                    try {
                        val s = device.createInsecureRfcommSocketToServiceRecord(SPP_UUID)
                        s.connect()
                        s
                    } catch (_: IOException) {
                        // Last resort: reflection-based socket on port 1
                        val m = device.javaClass.getMethod(
                            "createRfcommSocket",
                            Int::class.javaPrimitiveType
                        )
                        val s = m.invoke(device, 1) as BluetoothSocket
                        s.connect()
                        s
                    }
                }

                sockets[address] = sock
                outputStreams[address] = sock.outputStream

                // Monitor for remote disconnection.
                // Uses polling instead of blocking read() so that queryStatus
                // can exclusively read the printer's response.
                val monitorThread = Thread {
                    try {
                        while (!Thread.currentThread().isInterrupted) {
                            if (queryingStatus[address] == true) {
                                Thread.sleep(100)
                                continue
                            }
                            val inputStream = sock.inputStream
                            if (inputStream.available() > 0) {
                                val buf = ByteArray(inputStream.available())
                                inputStream.read(buf)
                            }
                            Thread.sleep(500)
                        }
                    } catch (_: IOException) {
                        // Connection lost — socket closed or remote disconnect
                    } catch (_: InterruptedException) {
                        // Thread interrupted by cleanupConnection — expected
                    }
                    mainHandler.post {
                        if (sockets.containsKey(address)) {
                            cleanupConnection(address)
                            connectionStateCallback?.invoke(address, "disconnected")
                        }
                    }
                }

                monitorThread.isDaemon = true
                monitorThread.start()
                inputThreads[address] = monitorThread

                mainHandler.post {
                    connectionStateCallback?.invoke(address, "connected")
                    result.success(null)
                }
            } catch (e: SecurityException) {
                mainHandler.post {
                    result.error("PERMISSION_DENIED", "Bluetooth connect permission denied", e.message)
                }
            } catch (e: IOException) {
                mainHandler.post {
                    result.error("CONNECTION_FAILED", "Bluetooth Classic connection failed", e.message)
                }
            }
        }.start()
    }

    fun write(address: String, data: ByteArray, result: MethodChannel.Result) {
        val os = outputStreams[address]
        if (os == null) {
            result.error("NOT_CONNECTED", "Bluetooth Classic not connected to $address", null)
            return
        }

        Thread {
            try {
                os.write(data)
                os.flush()
                mainHandler.post { result.success(null) }
            } catch (e: IOException) {
                mainHandler.post { result.error("WRITE_FAILED", "Bluetooth Classic write failed", e.message) }
            }
        }.start()
    }

    /// Sends DLE EOT n=[n] (real-time status query) and waits for the
    /// printer's single-byte response.  Because BT SPP is a sequential
    /// stream the printer can only receive this command after all preceding
    /// data.  [n] selects which status the printer should report:
    ///   1 — printer status, 2 — offline cause,
    ///   3 — error cause,    4 — paper sensor.
    fun queryStatus(address: String, n: Int, timeoutMs: Int, result: MethodChannel.Result) {
        val os = outputStreams[address]
        val sock = sockets[address]
        if (os == null || sock == null) {
            result.error("NOT_CONNECTED", "Bluetooth Classic not connected to $address", null)
            return
        }

        Thread {
            queryingStatus[address] = true
            try {
                // Small pause to let monitor thread yield.
                Thread.sleep(150)

                // Drain any stale bytes from the input buffer.
                val input = sock.inputStream
                while (input.available() > 0) { input.read() }

                os.write(byteArrayOf(0x10, 0x04, (n and 0xFF).toByte()))
                os.flush()

                val deadline = System.currentTimeMillis() + timeoutMs
                while (System.currentTimeMillis() < deadline) {
                    if (input.available() > 0) {
                        val status = input.read()
                        Log.d("PrinterSDK", "BT queryStatus(n=$n): response 0x${status.toString(16)} ($address)")
                        mainHandler.post { result.success(status) }
                        return@Thread
                    }
                    Thread.sleep(50)
                }
                Log.d("PrinterSDK", "BT queryStatus(n=$n): timeout (${timeoutMs}ms) ($address)")
                mainHandler.post { result.success(-1) }
            } catch (e: IOException) {
                mainHandler.post { result.error("QUERY_FAILED", "Bluetooth Classic status query failed", e.message) }
            } finally {
                queryingStatus.remove(address)
            }
        }.start()
    }

    fun disconnect(address: String, result: MethodChannel.Result) {
        cleanupConnection(address)
        connectionStateCallback?.invoke(address, "disconnected")
        result.success(null)
    }

    fun dispose() {
        stopDiscoveryInternal()
        val addresses = sockets.keys.toList()
        for (address in addresses) {
            cleanupConnection(address)
        }
    }

    private fun cleanupConnection(address: String) {
        inputThreads.remove(address)?.interrupt()
        try { outputStreams.remove(address)?.close() } catch (_: IOException) {}
        try { sockets.remove(address)?.close() } catch (_: IOException) {}
    }
}
