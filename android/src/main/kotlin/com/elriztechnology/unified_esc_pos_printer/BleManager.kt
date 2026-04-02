package com.elriztechnology.unified_esc_pos_printer

import android.bluetooth.*
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

class BleManager(private val context: Context) {

    companion object {
        private val ESC_POS_SERVICE_UUID =
            UUID.fromString("000018f0-0000-1000-8000-00805f9b34fb")
        private val ESC_POS_TX_CHAR_UUID =
            UUID.fromString("00002af1-0000-1000-8000-00805f9b34fb")
    }

    private val bluetoothAdapter: BluetoothAdapter? =
        (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
    private val scanner: BluetoothLeScanner?
        get() = bluetoothAdapter?.bluetoothLeScanner

    private val mainHandler = Handler(Looper.getMainLooper())

    // Scan state (shared — only one scan at a time)
    private var scanEventSink: EventChannel.EventSink? = null
    private val discoveredDevices = mutableListOf<Map<String, String>>()
    private var scanCallback: ScanCallback? = null
    private var scanTimeoutRunnable: Runnable? = null

    // Per-device connection state
    private val gatts = mutableMapOf<String, BluetoothGatt>()
    private val txCharacteristics = mutableMapOf<String, BluetoothGattCharacteristic>()
    private val negotiatedMtus = mutableMapOf<String, Int>()
    private val writeWithoutResponses = mutableMapOf<String, Boolean>()
    private val connectResults = mutableMapOf<String, MethodChannel.Result>()
    private val writeResults = mutableMapOf<String, MethodChannel.Result>()
    private val targetServiceUuids = mutableMapOf<String, UUID>()
    private val targetCharUuids = mutableMapOf<String, UUID>()

    var connectionStateCallback: ((String, String) -> Unit)? = null

    val scanStreamHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            scanEventSink = events
        }

        override fun onCancel(arguments: Any?) {
            scanEventSink = null
        }
    }

    fun getBondedBleDevices(result: MethodChannel.Result) {
        val adapter = bluetoothAdapter
        if (adapter == null) {
            result.success(emptyList<Map<String, String>>())
            return
        }

        try {
            val bonded = adapter.bondedDevices?.filter { device ->
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR2) {
                    device.type == BluetoothDevice.DEVICE_TYPE_LE ||
                            device.type == BluetoothDevice.DEVICE_TYPE_DUAL
                } else {
                    true // Include all if we can't check type
                }
            }?.map { device ->
                mapOf(
                    "deviceId" to device.address,
                    "name" to (device.name ?: device.address)
                )
            } ?: emptyList()
            result.success(bonded)
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", "Cannot access bonded devices", e.message)
        }
    }

    fun startScan(timeoutMs: Long, result: MethodChannel.Result) {
        val s = scanner
        if (s == null) {
            result.error("UNAVAILABLE", "Bluetooth LE scanner not available", null)
            return
        }

        discoveredDevices.clear()

        scanCallback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, scanResult: ScanResult) {
                val device = scanResult.device
                val id = device.address
                if (discoveredDevices.none { it["deviceId"] == id }) {
                    val name = try { device.name } catch (_: SecurityException) { null }

                    discoveredDevices.add(
                        mapOf(
                            "deviceId" to id,
                            "name" to (name ?: id)
                        )
                    )

                    mainHandler.post {
                        scanEventSink?.success(discoveredDevices.toList())
                    }
                }
            }

            override fun onScanFailed(errorCode: Int) {
                mainHandler.post {
                    scanEventSink?.error("SCAN_FAILED", "BLE scan failed with code $errorCode", null)
                }
            }
        }

        try {
            s.startScan(scanCallback)
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", "Bluetooth scan permission denied", e.message)
            return
        }

        // Auto-stop after timeout
        scanTimeoutRunnable = Runnable {
            stopScanInternal()
        }

        mainHandler.postDelayed(scanTimeoutRunnable!!, timeoutMs)

        result.success(null)
    }

    fun stopScan(result: MethodChannel.Result) {
        stopScanInternal()
        result.success(null)
    }

    private fun stopScanInternal() {
        scanTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        scanTimeoutRunnable = null
        scanCallback?.let { cb ->
            try {
                scanner?.stopScan(cb)
            } catch (_: SecurityException) {
                // Already lost permission — ignore
            }
        }
        scanCallback = null
    }

    fun connect(
        deviceId: String,
        timeoutMs: Long,
        serviceUuid: String?,
        characteristicUuid: String?,
        result: MethodChannel.Result
    ) {
        val adapter = bluetoothAdapter
        if (adapter == null) {
            result.error("UNAVAILABLE", "Bluetooth adapter not available", null)
            return
        }

        targetServiceUuids[deviceId] = serviceUuid?.let { UUID.fromString(it) } ?: ESC_POS_SERVICE_UUID
        targetCharUuids[deviceId] = characteristicUuid?.let { UUID.fromString(it) } ?: ESC_POS_TX_CHAR_UUID

        val device: BluetoothDevice
        try {
            device = adapter.getRemoteDevice(deviceId)
        } catch (e: Exception) {
            result.error("INVALID_DEVICE", "Invalid device ID: $deviceId", e.message)
            return
        }

        // Clean up any existing connection for this device
        cleanupConnection(deviceId)

        connectResults[deviceId] = result

        // Timeout handler
        val timeoutRunnable = Runnable {
            val pendingResult = connectResults.remove(deviceId)
            if (pendingResult != null) {
                pendingResult.error("TIMEOUT", "BLE connection timed out", null)

                try { gatts[deviceId]?.disconnect(); gatts[deviceId]?.close() } catch (_: SecurityException) {}
                gatts.remove(deviceId)
            }
        }
        mainHandler.postDelayed(timeoutRunnable, timeoutMs)

        val gattCallback = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    gatts[deviceId] = g
                    try {
                        g.requestMtu(512)
                    } catch (e: SecurityException) {
                        mainHandler.post {
                            mainHandler.removeCallbacks(timeoutRunnable)
                            connectResults.remove(deviceId)?.error("PERMISSION_DENIED", "MTU request denied", e.message)
                        }
                    }
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    mainHandler.post {
                        mainHandler.removeCallbacks(timeoutRunnable)

                        val pendingResult = connectResults.remove(deviceId)
                        if (pendingResult != null) {
                            pendingResult.error("DISCONNECTED", "BLE device disconnected during setup", null)
                        } else {
                            // Remote disconnection after fully connected
                            connectionStateCallback?.invoke(deviceId, "disconnected")
                        }

                        try { g.close() } catch (_: SecurityException) {}

                        gatts.remove(deviceId)
                        txCharacteristics.remove(deviceId)
                    }
                }
            }

            override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
                negotiatedMtus[deviceId] = if (status == BluetoothGatt.GATT_SUCCESS) mtu - 3 else 20
                try {
                    g.discoverServices()
                } catch (e: SecurityException) {
                    mainHandler.post {
                        mainHandler.removeCallbacks(timeoutRunnable)
                        connectResults.remove(deviceId)?.error("PERMISSION_DENIED", "Service discovery denied", e.message)
                    }
                }
            }

            override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    mainHandler.post {
                        mainHandler.removeCallbacks(timeoutRunnable)
                        connectResults.remove(deviceId)?.error("SERVICE_DISCOVERY_FAILED", "GATT service discovery failed with status $status", null)
                        try { g.disconnect(); g.close() } catch (_: SecurityException) {}
                        gatts.remove(deviceId)
                    }
                    return
                }

                var foundChar: BluetoothGattCharacteristic? = null

                // 1. Try target service/characteristic UUIDs
                val targetService = g.getService(targetServiceUuids[deviceId])
                if (targetService != null) {
                    val c = targetService.getCharacteristic(targetCharUuids[deviceId])
                    if (c != null && isWritable(c)) {
                        foundChar = c
                    }
                }

                // 2. Fallback: any writable characteristic
                if (foundChar == null) {
                    for (service in g.services) {
                        for (c in service.characteristics) {
                            if (isWritable(c)) {
                                foundChar = c
                                break
                            }
                        }
                        if (foundChar != null) break
                    }
                }

                mainHandler.post {
                    mainHandler.removeCallbacks(timeoutRunnable)
                    if (foundChar == null) {
                        connectResults.remove(deviceId)?.error("NO_CHARACTERISTIC", "No writable characteristic found", null)
                        try { g.disconnect(); g.close() } catch (_: SecurityException) {}
                        gatts.remove(deviceId)
                    } else {
                        txCharacteristics[deviceId] = foundChar
                        // Prefer write-with-response for reliable backpressure; the printer
                        // ACKs each chunk before we send the next, preventing buffer overflow.
                        // Fall back to write-without-response only if that is the sole option.
                        writeWithoutResponses[deviceId] =
                            (foundChar.properties and BluetoothGattCharacteristic.PROPERTY_WRITE) == 0 &&
                            (foundChar.properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) != 0
                        connectResults.remove(deviceId)?.success(null)
                        connectionStateCallback?.invoke(deviceId, "connected")
                    }
                }
            }

            override fun onCharacteristicWrite(
                g: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int
            ) {
                mainHandler.post {
                    val pendingResult = writeResults.remove(deviceId)
                    if (status == BluetoothGatt.GATT_SUCCESS) {
                        pendingResult?.success(null)
                    } else {
                        pendingResult?.error("WRITE_FAILED", "BLE write failed with status $status", null)
                    }
                }
            }
        }

        // Check if device is bonded — use autoConnect=true for bonded devices
        // as they may not be advertising, but the system can connect when they
        // become available.
        val isBonded = try {
            device.bondState == BluetoothDevice.BOND_BONDED
        } catch (_: SecurityException) {
            false
        }

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                device.connectGatt(context, isBonded, gattCallback, BluetoothDevice.TRANSPORT_LE)
            } else {
                device.connectGatt(context, isBonded, gattCallback)
            }
        } catch (e: SecurityException) {
            mainHandler.removeCallbacks(timeoutRunnable)
            connectResults.remove(deviceId)
            result.error("PERMISSION_DENIED", "Bluetooth connect permission denied", e.message)
        }
    }

    fun getMtu(deviceId: String, result: MethodChannel.Result) {
        result.success(negotiatedMtus[deviceId] ?: 20)
    }

    fun supportsWriteWithoutResponse(deviceId: String, result: MethodChannel.Result) {
        result.success(writeWithoutResponses[deviceId] ?: false)
    }

    fun write(deviceId: String, data: ByteArray, withoutResponse: Boolean, result: MethodChannel.Result) {
        val g = gatts[deviceId]
        val char = txCharacteristics[deviceId]
        if (g == null || char == null) {
            result.error("NOT_CONNECTED", "BLE device not connected: $deviceId", null)
            return
        }

        writeResults[deviceId] = result

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                // Android 13+ uses new writeCharacteristic API
                val writeType = if (withoutResponse)
                    BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                else
                    BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT

                    val writeResult = g.writeCharacteristic(char, data, writeType)
                if (writeResult != BluetoothStatusCodes.SUCCESS) {
                    writeResults.remove(deviceId)?.error("WRITE_FAILED", "writeCharacteristic returned $writeResult", null)
                }
            } else {
                @Suppress("DEPRECATION")
                char.writeType = if (withoutResponse)
                    BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                else
                    BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT

                @Suppress("DEPRECATION")
                char.value = data

                @Suppress("DEPRECATION")
                val success = g.writeCharacteristic(char)
                if (!success) {
                    writeResults.remove(deviceId)?.error("WRITE_FAILED", "writeCharacteristic returned false", null)
                }
            }
        } catch (e: SecurityException) {
            writeResults.remove(deviceId)?.error("PERMISSION_DENIED", "Bluetooth write permission denied", e.message)
        }
    }

    fun disconnect(deviceId: String, result: MethodChannel.Result) {
        cleanupConnection(deviceId)
        connectionStateCallback?.invoke(deviceId, "disconnected")
        result.success(null)
    }

    fun dispose() {
        stopScanInternal()

        val deviceIds = gatts.keys.toList()
        for (deviceId in deviceIds) {
            cleanupConnection(deviceId)
        }
    }

    private fun cleanupConnection(deviceId: String) {
        try {
            gatts[deviceId]?.disconnect()
            gatts[deviceId]?.close()
        } catch (_: SecurityException) {}

        gatts.remove(deviceId)
        txCharacteristics.remove(deviceId)
        negotiatedMtus.remove(deviceId)
        writeWithoutResponses.remove(deviceId)
        connectResults.remove(deviceId)
        writeResults.remove(deviceId)
        targetServiceUuids.remove(deviceId)
        targetCharUuids.remove(deviceId)
    }

    private fun isWritable(c: BluetoothGattCharacteristic): Boolean {
        val props = c.properties
        return (props and BluetoothGattCharacteristic.PROPERTY_WRITE) != 0 ||
                (props and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) != 0
    }
}
