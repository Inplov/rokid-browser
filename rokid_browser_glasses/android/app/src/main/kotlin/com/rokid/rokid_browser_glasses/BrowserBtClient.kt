package com.rokid.rokid_browser_glasses

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothSocket
import android.util.Log
import java.io.BufferedReader
import java.io.IOException
import java.io.InputStreamReader
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class BrowserBtClient(
    private val adapter: BluetoothAdapter,
    private val onMessage: (String) -> Unit,
    private val onStatus: (String) -> Unit
) {
    companion object {
        private const val TAG = "BrowserBTClient"
        val BT_UUID: UUID = UUID.fromString("a1b2c3d4-e5f6-7890-abcd-ef1234567890")
        private const val PING_INTERVAL_MS = 5_000L
        private const val PING_JSON = "{\"type\":\"ping\"}\n"
    }

    private val running = AtomicBoolean(false)
    private var thread: Thread? = null
    private val sendQueue = LinkedBlockingQueue<String>(100)

    fun start() {
        if (running.getAndSet(true)) return
        thread = Thread {
            while (running.get()) {
                tryConnect()
                if (running.get()) {
                    try { Thread.sleep(2000) } catch (_: InterruptedException) { break }
                }
            }
        }.apply { isDaemon = true; name = "BrowserBTClient"; start() }
    }

    fun stop() {
        running.set(false)
        thread?.interrupt()
    }

    fun send(msg: String) {
        sendQueue.offer(msg)
    }

    private fun tryConnect() {
        onStatus("scanning")
        try { adapter.cancelDiscovery() } catch (_: Exception) {}

        val paired = try {
            adapter.bondedDevices
        } catch (e: SecurityException) {
            Log.e(TAG, "Missing BLUETOOTH_CONNECT permission: ${e.message}")
            onStatus("permission_denied")
            return
        }

        if (paired.isNullOrEmpty()) {
            onStatus("no_paired_devices")
            return
        }

        var connected: BluetoothSocket? = null
        var connectedName = ""

        for (device in paired) {
            val s = try {
                device.createRfcommSocketToServiceRecord(BT_UUID)
            } catch (e: Exception) { continue }

            try {
                s.connect()
                connected = s
                connectedName = device.name ?: device.address
                break
            } catch (e: Exception) {
                try { s.close() } catch (_: Exception) {}
            }
        }

        if (connected == null) {
            onStatus("not_found")
            return
        }

        onStatus("connected:$connectedName")
        Log.d(TAG, "Connected to phone: $connectedName")

        val out: OutputStream = connected.outputStream
        val pingBytes = PING_JSON.toByteArray(Charsets.UTF_8)

        // Sender thread — drains queue or sends pings
        val sender = Thread {
            try {
                while (running.get()) {
                    val msg = sendQueue.poll(PING_INTERVAL_MS, TimeUnit.MILLISECONDS)
                    if (msg != null) {
                        out.write((msg + "\n").toByteArray(Charsets.UTF_8))
                        out.flush()
                    } else {
                        out.write(pingBytes)
                        out.flush()
                    }
                }
            } catch (_: Exception) {
                try { connected.close() } catch (_: Exception) {}
            }
        }.apply { isDaemon = true; start() }

        try {
            val reader = BufferedReader(
                InputStreamReader(connected.inputStream, Charsets.UTF_8)
            )
            while (running.get()) {
                val line = reader.readLine() ?: break
                if (line.isNotBlank() && !line.contains("\"type\":\"ping\"")) {
                    onMessage(line)
                }
            }
        } catch (e: IOException) {
            Log.d(TAG, "BT read error: ${e.message}")
        } finally {
            onStatus("disconnected")
            try { connected.close() } catch (_: Exception) {}
        }
    }
}
