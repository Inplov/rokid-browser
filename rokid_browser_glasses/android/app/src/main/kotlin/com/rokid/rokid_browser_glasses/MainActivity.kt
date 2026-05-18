package com.rokid.rokid_browser_glasses

import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.ViewGroup
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
import android.webkit.WebView
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewFeature
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class MainActivity : FlutterActivity() {

    private val EVENT_CHANNEL  = "com.rokid.rokid_browser_glasses/events"
    private val METHOD_CHANNEL = "com.rokid.rokid_browser_glasses/methods"

    private var btClient: BrowserBtClient? = null
    @Volatile private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var passthroughView: android.view.View? = null
    private var cursorView: android.view.View? = null

    private val wifiReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == WifiManager.WIFI_STATE_CHANGED_ACTION ||
                intent.action == WifiManager.NETWORK_STATE_CHANGED_ACTION) {
                mainHandler.postDelayed({ sendWifiState() }, 500)
            }
        }
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val filter = IntentFilter().apply {
            addAction(WifiManager.WIFI_STATE_CHANGED_ACTION)
            addAction(WifiManager.NETWORK_STATE_CHANGED_ACTION)
        }
        registerReceiver(wifiReceiver, filter)
    }

    private fun findWebView(v: android.view.View): WebView? {
        if (v is WebView) return v
        if (v is ViewGroup) {
            for (i in 0 until v.childCount) {
                findWebView(v.getChildAt(i))?.let { return it }
            }
        }
        return null
    }

    // Returns the YouTube/custom fullscreen view added by webview_flutter's onShowCustomView().
    // System decor children (statusBarBackground, navigationBarBackground, the content
    // FrameLayout, etc.) all have resource IDs.  The custom view is added without an ID
    // (id == NO_ID) and covers most of the screen — we use both criteria to avoid false
    // positives from our own cursor/passthrough views (skipped by identity check first).
    private fun findFullscreenView(): android.view.View? {
        val root = window.decorView as android.view.ViewGroup
        val screenW = resources.displayMetrics.widthPixels
        val screenH = resources.displayMetrics.heightPixels
        for (i in root.childCount - 1 downTo 0) {
            val child = root.getChildAt(i)
            if (child === cursorView || child === passthroughView) continue
            if (child.id != android.view.View.NO_ID) continue  // skip all system/framework views
            if (child.visibility != android.view.View.VISIBLE) continue
            if (child.width < screenW / 2 || child.height < screenH / 2) continue
            return child
        }
        return null
    }

    @Suppress("DEPRECATION")
    private fun applyForceDark(wv: WebView, enable: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (WebViewFeature.isFeatureSupported(WebViewFeature.ALGORITHMIC_DARKENING)) {
                WebSettingsCompat.setAlgorithmicDarkeningAllowed(wv.settings, enable)
            }
        } else {
            if (WebViewFeature.isFeatureSupported(WebViewFeature.FORCE_DARK)) {
                WebSettingsCompat.setForceDark(
                    wv.settings,
                    if (enable) WebSettingsCompat.FORCE_DARK_ON else WebSettingsCompat.FORCE_DARK_OFF
                )
            }
        }
    }

    private fun wifiManager() =
        applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager

    @Suppress("DEPRECATION")
    private fun buildWifiJson(): String {
        val wm = wifiManager()
        val enabled = wm.isWifiEnabled
        val info = wm.connectionInfo
        val ssid = if (enabled && info != null && info.networkId != -1)
            info.ssid.trim('"') else ""
        val rssi = if (ssid.isNotEmpty()) info?.rssi ?: 0 else 0
        return JSONObject()
            .put("type", "wifi_state")
            .put("enabled", enabled)
            .put("ssid", ssid)
            .put("rssi", rssi)
            .toString()
    }

    @Suppress("DEPRECATION")
    private fun connectToWifi(ssid: String, password: String): Boolean {
        if (ssid.isEmpty()) return false
        val wm = wifiManager()
        if (!wm.isWifiEnabled) {
            wm.setWifiEnabled(true)
            Thread.sleep(1000)
        }
        val config = android.net.wifi.WifiConfiguration().apply {
            SSID = "\"$ssid\""
            if (password.isEmpty()) {
                allowedKeyManagement.set(android.net.wifi.WifiConfiguration.KeyMgmt.NONE)
            } else {
                preSharedKey = "\"$password\""
                allowedKeyManagement.set(android.net.wifi.WifiConfiguration.KeyMgmt.WPA_PSK)
            }
        }
        val netId = wm.addNetwork(config)
        if (netId == -1) return false
        wm.disconnect()
        wm.enableNetwork(netId, true)
        wm.reconnect()
        return true
    }

    private fun sendWifiState() {
        val json = buildWifiJson()
        btClient?.send(json)
        runOnUiThread { eventSink?.success(json) }
    }

    override fun onStart() {
        super.onStart()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val needed = arrayOf(
                android.Manifest.permission.BLUETOOTH_CONNECT,
                android.Manifest.permission.BLUETOOTH_SCAN
            ).filter {
                androidx.core.content.ContextCompat.checkSelfPermission(this, it) !=
                    android.content.pm.PackageManager.PERMISSION_GRANTED
            }
            if (needed.isNotEmpty()) requestPermissions(needed.toTypedArray(), 200)
        }
    }

    override fun onDestroy() {
        try { unregisterReceiver(wifiReceiver) } catch (_: Exception) {}
        passthroughView?.let { v ->
            try { (window.decorView as? android.view.ViewGroup)?.removeView(v) } catch (_: Exception) {}
            passthroughView = null
        }
        cursorView?.let { v ->
            try { (window.decorView as? android.view.ViewGroup)?.removeView(v) } catch (_: Exception) {}
            cursorView = null
        }
        btClient?.stop()
        btClient = null
        super.onDestroy()
    }

    // Volume keys adjust the system STREAM_MUSIC volume (for correct gain staging
    // through the audio hardware) and also notify Flutter so the WebView JS
    // volume property stays in sync.
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_DOWN) {
            val direction = when (event.keyCode) {
                KeyEvent.KEYCODE_VOLUME_UP   -> AudioManager.ADJUST_RAISE to "volume_up"
                KeyEvent.KEYCODE_VOLUME_DOWN -> AudioManager.ADJUST_LOWER to "volume_down"
                else -> null
            }
            if (direction != null) {
                val am = getSystemService(AUDIO_SERVICE) as AudioManager
                am.adjustStreamVolume(
                    AudioManager.STREAM_MUSIC,
                    direction.first,
                    AudioManager.FLAG_SHOW_UI
                )
                val json = JSONObject()
                    .put("type", "browser_cmd")
                    .put("action", direction.second)
                    .toString()
                runOnUiThread { eventSink?.success(json) }
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            METHOD_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "exitApp" -> {
                    result.success(true)
                    finishAffinity()
                }
                "wifiEnable" -> {
                    @Suppress("DEPRECATION")
                    wifiManager().setWifiEnabled(true)
                    mainHandler.postDelayed({ sendWifiState() }, 1500)
                    result.success(true)
                }
                "wifiDisable" -> {
                    @Suppress("DEPRECATION")
                    wifiManager().setWifiEnabled(false)
                    mainHandler.postDelayed({ sendWifiState() }, 1000)
                    result.success(true)
                }
                "wifiStatus" -> {
                    result.success(buildWifiJson())
                }
                "wifiConnect" -> {
                    val args = call.arguments as? Map<*, *>
                    val ssid = args?.get("ssid") as? String ?: ""
                    val password = args?.get("password") as? String ?: ""
                    val ok = connectToWifi(ssid, password)
                    mainHandler.postDelayed({ sendWifiState() }, 5000)
                    result.success(ok)
                }
                "configureWebViewZoom" -> {
                    val wv = findWebView(window.decorView)
                    if (wv != null) {
                        wv.settings.useWideViewPort = true
                        wv.settings.loadWithOverviewMode = true
                        applyForceDark(wv, true)
                    }
                    result.success(wv != null)
                }
                "setForceDark" -> {
                    val enable = call.arguments as? Boolean ?: true
                    val wv = findWebView(window.decorView)
                    if (wv != null) applyForceDark(wv, enable)
                    result.success(wv != null)
                }
                "setThirdPartyCookies" -> {
                    val args = call.arguments as? Map<*, *>
                    val block = args?.get("block") as? Boolean ?: false
                    val cm = android.webkit.CookieManager.getInstance()
                    val wv = findWebView(window.decorView)
                    if (wv != null) {
                        cm.setAcceptThirdPartyCookies(wv, !block)
                        cm.flush()
                    }
                    result.success(wv != null)
                }
                "setPassthrough" -> {
                    // Add a black native View to the window's DecorView — this composites
                    // above everything including Chrome's hardware SurfaceView for fullscreen video.
                    // A Flutter widget overlay or WebView DOM div both fall below the video layer.
                    val active = call.arguments as? Boolean ?: false
                    if (active) {
                        if (passthroughView == null) {
                            val v = android.view.View(this)
                            v.setBackgroundColor(0xD9000000.toInt())
                            v.isClickable = false
                            v.isFocusable = false
                            v.alpha = 0f
                            (window.decorView as android.view.ViewGroup).addView(
                                v,
                                android.widget.FrameLayout.LayoutParams(
                                    android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                                    android.view.ViewGroup.LayoutParams.MATCH_PARENT
                                )
                            )
                            passthroughView = v
                            v.animate().alpha(1f).setDuration(250).start()
                        }
                    } else {
                        passthroughView?.let { v ->
                            v.animate().alpha(0f).setDuration(250).withEndAction {
                                (window.decorView as? android.view.ViewGroup)?.removeView(v)
                                if (passthroughView === v) passthroughView = null
                            }.start()
                        }
                    }
                    result.success(true)
                }
                "clickAt" -> {
                    val args = call.arguments as? Map<*, *>
                    val lx = (args?.get("x") as? Number)?.toFloat() ?: 0f
                    val ly = (args?.get("y") as? Number)?.toFloat() ?: 0f
                    val isFullscreen = args?.get("fullscreen") as? Boolean ?: false
                    val density = resources.displayMetrics.density
                    val wv = findWebView(window.decorView)
                    if (wv != null) {
                        val t = android.os.SystemClock.uptimeMillis()
                        val px = lx * density
                        val py = ly * density
                        val wvLoc = IntArray(2)
                        wv.getLocationInWindow(wvLoc)

                        // fullscreen flag is set by Flutter via JS (document.fullscreenElement
                        // or YouTube's aria-label check) — same logic as the double-tap exit.
                        val fsView = if (isFullscreen) findFullscreenView() else null

                        if (fsView != null) {
                            // Fullscreen path — dispatch ONLY to the fullscreen view.
                            // Do NOT also dispatch to wv; that would cause a double-click.
                            val fsLoc = IntArray(2)
                            fsView.getLocationInWindow(fsLoc)
                            val fsX = (wvLoc[0] + px) - fsLoc[0]
                            val fsY = (wvLoc[1] + py) - fsLoc[1]
                            val downFs = MotionEvent.obtain(t, t,       MotionEvent.ACTION_DOWN, fsX, fsY, 0)
                            val upFs   = MotionEvent.obtain(t, t + 80L, MotionEvent.ACTION_UP,   fsX, fsY, 0)
                            fsView.dispatchTouchEvent(downFs)
                            mainHandler.postDelayed({
                                fsView.dispatchTouchEvent(upFs)
                                downFs.recycle()
                                upFs.recycle()
                            }, 80)
                        } else {
                            // Normal path — dispatch ONLY to the WebView (trusted event,
                            // focuses <input> fields, passes isTrusted checks).
                            val down = MotionEvent.obtain(t, t,       MotionEvent.ACTION_DOWN, px, py, 0)
                            val up   = MotionEvent.obtain(t, t + 80L, MotionEvent.ACTION_UP,   px, py, 0)
                            wv.dispatchTouchEvent(down)
                            mainHandler.postDelayed({
                                wv.dispatchTouchEvent(up)
                                down.recycle()
                                up.recycle()
                                mainHandler.postDelayed({
                                    val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
                                    imm.hideSoftInputFromWindow(wv.windowToken, 0)
                                }, 150)
                            }, 80)
                        }
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                "sendBrowserState" -> {
                    val args = call.arguments as? Map<*, *>
                    if (args != null) {
                        val json = JSONObject().apply {
                            put("type",         "browser_state")
                            put("url",          args["url"]          as? String  ?: "")
                            put("title",        args["title"]        as? String  ?: "")
                            put("loading",      args["loading"]      as? Boolean ?: false)
                            put("canGoBack",    args["canGoBack"]    as? Boolean ?: false)
                            put("canGoForward", args["canGoForward"] as? Boolean ?: false)
                        }
                        btClient?.send(json.toString())
                    }
                    result.success(true)
                }
                "bookmarkCurrent" -> {
                    val args = call.arguments as? Map<*, *>
                    val url = args?.get("url") as? String ?: ""
                    val title = args?.get("title") as? String ?: ""
                    if (url.isNotEmpty()) {
                        val json = JSONObject()
                            .put("type", "bookmark_add")
                            .put("url", url)
                            .put("title", title.ifEmpty { url })
                            .toString()
                        btClient?.send(json)
                    }
                    result.success(true)
                }
                "updateCursor" -> {
                    val args = call.arguments as? Map<*, *>
                    val lx = (args?.get("x") as? Number)?.toFloat() ?: 0f
                    val ly = (args?.get("y") as? Number)?.toFloat() ?: 0f
                    val visible = args?.get("visible") as? Boolean ?: false
                    val dragging = args?.get("dragging") as? Boolean ?: false
                    val density = resources.displayMetrics.density
                    val sizePx = (14 * density).toInt()
                    val root = window.decorView as android.view.ViewGroup
                    if (cursorView == null) {
                        val cv = android.view.View(this)
                        cv.isClickable = false
                        cv.isFocusable = false
                        root.addView(cv, android.widget.FrameLayout.LayoutParams(sizePx, sizePx))
                        cursorView = cv
                    }
                    val cv = cursorView!!
                    // Find WebView's top offset in the window to account for status bar / system UI
                    val wvOffsetY = run {
                        val wv = findWebView(root)
                        if (wv != null) {
                            val loc = IntArray(2)
                            wv.getLocationInWindow(loc)
                            loc[1].toFloat()
                        } else 0f
                    }
                    val drawable = android.graphics.drawable.GradientDrawable().apply {
                        shape = android.graphics.drawable.GradientDrawable.OVAL
                        setColor(if (dragging) 0xFFFFA500.toInt() else 0xFFFFFFFF.toInt())
                        setStroke((1.5f * density).toInt(), 0x8A000000.toInt())
                    }
                    cv.background = drawable
                    cv.x = lx * density - sizePx / 2f
                    cv.y = wvOffsetY + ly * density - sizePx / 2f
                    cv.visibility = if (visible) android.view.View.VISIBLE else android.view.View.INVISIBLE
                    // Always draw cursor above passthrough overlay and SurfaceView video layer
                    cv.bringToFront()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EVENT_CHANNEL
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events

                if (btClient == null) {
                    val btAdapter = try {
                        (getSystemService(BLUETOOTH_SERVICE) as BluetoothManager).adapter
                    } catch (e: Exception) { null }

                    if (btAdapter != null) {
                        btClient = BrowserBtClient(
                            adapter   = btAdapter,
                            onMessage = { json ->
                                runOnUiThread { eventSink?.success(json) }
                            },
                            onStatus  = { status ->
                                val statusJson = JSONObject()
                                    .put("type", "bt_status")
                                    .put("status", status)
                                    .toString()
                                runOnUiThread { eventSink?.success(statusJson) }
                            }
                        )
                        btClient?.start()
                    }
                }

                // Report WiFi state immediately so phone UI is current on connect
                mainHandler.postDelayed({ sendWifiState() }, 800)
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
    }
}
