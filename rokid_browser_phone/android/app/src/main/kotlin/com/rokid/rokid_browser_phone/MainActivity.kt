package com.rokid.rokid_browser_phone

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val METHOD_CHANNEL = "com.rokid.rokid_browser_phone/methods"
    private val EVENT_CHANNEL  = "com.rokid.rokid_browser_phone/events"

    private var btServer: BrowserBtServer? = null
    @Volatile private var eventSink: EventChannel.EventSink? = null

    override fun onStart() {
        super.onStart()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val needed = arrayOf(Manifest.permission.BLUETOOTH_CONNECT)
                .filter {
                    ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
                }
            if (needed.isNotEmpty()) requestPermissions(needed.toTypedArray(), 200)
        }
    }

    override fun onDestroy() {
        btServer?.stop()
        btServer = null
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "sendCommand" -> {
                        val json = call.arguments as? String ?: ""
                        if (json.isNotEmpty()) btServer?.send(json)
                        result.success(true)
                    }
                    "resetConnection" -> {
                        btServer?.reset()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events

                    if (btServer == null) {
                        btServer = BrowserBtServer(
                            onMessage = { json ->
                                runOnUiThread { eventSink?.success(json) }
                            },
                            onStatus = { status ->
                                val statusJson = "{\"type\":\"bt_status\",\"status\":\"$status\"}"
                                runOnUiThread { eventSink?.success(statusJson) }
                            }
                        )
                        btServer?.start()
                    }

                    runOnUiThread {
                        events?.success("{\"type\":\"bt_status\",\"status\":\"listening\"}")
                    }
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
    }
}
