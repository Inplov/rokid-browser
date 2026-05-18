package com.rokid.rokid_browser_phone

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.util.Log
import java.io.BufferedReader
import java.io.IOException
import java.io.InputStreamReader
import java.util.UUID
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

class BrowserBtServer(
    private val onMessage: (String) -> Unit,
    private val onStatus: (String) -> Unit
) {
    companion object {
        private const val TAG = "BrowserBTServer"
        val BT_UUID: UUID = UUID.fromString("a1b2c3d4-e5f6-7890-abcd-ef1234567890")
    }

    private val running = AtomicBoolean(false)
    private var thread: Thread? = null
    @Volatile private var serverSocket: BluetoothServerSocket? = null
    @Volatile private var clientSocket: BluetoothSocket? = null
    private val sendQueue = LinkedBlockingQueue<String>(200)

    fun start() {
        if (running.getAndSet(true)) return
        launchServerThread()
    }

    fun stop() {
        running.set(false)
        try { serverSocket?.close() } catch (_: Exception) {}
        try { clientSocket?.close() } catch (_: Exception) {}
        thread?.interrupt()
    }

    fun send(msg: String) {
        sendQueue.offer(msg)
    }

    fun reset() {
        onStatus("resetting")
        running.set(false)
        try { serverSocket?.close() } catch (_: Exception) {}
        try { clientSocket?.close() } catch (_: Exception) {}
        thread?.interrupt()
        Thread {
            try { Thread.sleep(800) } catch (_: InterruptedException) {}
            running.set(true)
            launchServerThread()
        }.apply { isDaemon = true; start() }
    }

    private fun launchServerThread() {
        thread = Thread {
            while (running.get()) {
                runServer()
                if (running.get()) {
                    try { Thread.sleep(3000) } catch (_: InterruptedException) { break }
                }
            }
        }.apply { isDaemon = true; name = "BrowserBTServer"; start() }
    }

    private fun runServer() {
        val adapter = BluetoothAdapter.getDefaultAdapter() ?: return
        var sSocket: BluetoothServerSocket? = null
        var cSocket: BluetoothSocket? = null

        try {
            sSocket = adapter.listenUsingRfcommWithServiceRecord("RokidBrowser", BT_UUID)
            serverSocket = sSocket
            onStatus("listening")
            Log.d(TAG, "Waiting for glasses to connect…")

            cSocket = sSocket.accept()
            serverSocket = null
            sSocket.close()
            clientSocket = cSocket

            val deviceName = cSocket.remoteDevice.name ?: cSocket.remoteDevice.address
            Log.d(TAG, "Glasses connected: $deviceName")
            onStatus("connected:$deviceName")

            val out = cSocket.outputStream
            val disconnected = AtomicBoolean(false)
            val lastReceived = AtomicLong(System.currentTimeMillis())

            // Reader — parses JSON state updates from glasses
            val reader = Thread {
                try {
                    val buffered = BufferedReader(
                        InputStreamReader(cSocket.inputStream, Charsets.UTF_8)
                    )
                    while (!disconnected.get()) {
                        val line = buffered.readLine() ?: break
                        lastReceived.set(System.currentTimeMillis())
                        if (line.isNotBlank() && !line.contains("\"type\":\"ping\"")) {
                            onMessage(line)
                        }
                    }
                } catch (_: IOException) {}
                disconnected.set(true)
            }.apply { isDaemon = true; start() }

            // Sender — drains command queue to glasses
            while (running.get() && !disconnected.get()) {
                if (System.currentTimeMillis() - lastReceived.get() > 15_000) {
                    Log.d(TAG, "Keepalive timeout — glasses disconnected")
                    break
                }
                val msg = sendQueue.poll(1, TimeUnit.SECONDS) ?: continue
                try {
                    out.write((msg + "\n").toByteArray(Charsets.UTF_8))
                    out.flush()
                } catch (e: IOException) {
                    Log.d(TAG, "Send failed: ${e.message}")
                    break
                }
            }
            disconnected.set(true)

        } catch (_: InterruptedException) {
        } catch (e: Exception) {
            if (running.get()) Log.d(TAG, "BT server error: ${e.message}")
        } finally {
            try { cSocket?.close() } catch (_: Exception) {}
            try { sSocket?.close() } catch (_: Exception) {}
            clientSocket = null
            if (running.get()) onStatus("disconnected")
        }
    }
}
