import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'secrets.dart';

// Returns dark or light color depending on the current theme brightness.
Color _c(BuildContext ctx, Color dark, Color light) =>
    Theme.of(ctx).brightness == Brightness.dark ? dark : light;

class _HistoryEntry {
  final String url;
  final String title;
  const _HistoryEntry({required this.url, required this.title});

  Map<String, String> toJson() => {'url': url, 'title': title};

  factory _HistoryEntry.fromJson(Map<String, dynamic> j) =>
      _HistoryEntry(url: j['url'] as String, title: j['title'] as String);
}

class _BookmarkEntry {
  final String url;
  final String title;
  const _BookmarkEntry({required this.url, required this.title});

  Map<String, String> toJson() => {'url': url, 'title': title};

  factory _BookmarkEntry.fromJson(Map<String, dynamic> j) =>
      _BookmarkEntry(url: j['url'] as String, title: j['title'] as String);
}

class BrowserControlScreen extends StatefulWidget {
  const BrowserControlScreen({super.key});

  @override
  State<BrowserControlScreen> createState() => _BrowserControlScreenState();
}

class _BrowserControlScreenState extends State<BrowserControlScreen> {
  static const _eventChannel =
      EventChannel('com.rokid.rokid_browser_phone/events');
  static const _methodChannel =
      MethodChannel('com.rokid.rokid_browser_phone/methods');

  final _urlController = TextEditingController();
  String _currentUrl = '';
  String _currentTitle = '';
  bool _loading = false;
  bool _canGoBack = false;
  bool _canGoForward = false;
  bool _glassesIsDark = true;
  String _btStatus = 'listening';
  bool _resetting = false;
  bool _wifiEnabled = false;
  String _wifiSsid = '';
  int _wifiRssi = 0;
  bool _wifiToggling = false;
  List<_HistoryEntry> _history = [];
  static const _historyKey = 'rokid_browser_history';
  List<_BookmarkEntry> _bookmarks = [];
  static const _bookmarksKey = 'rokid_browser_bookmarks';

  bool get _isConnected => _btStatus.startsWith('connected');

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _loadBookmarks();
    _setupEventStream();
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_historyKey);
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      if (mounted) {
        setState(() {
          _history = list
              .map((e) => _HistoryEntry.fromJson(e as Map<String, dynamic>))
              .toList();
        });
      }
    } catch (_) {}
  }

  Future<void> _saveHistory() async {
    final prefs = await SharedPreferences.getInstance();
    prefs.setString(
        _historyKey, jsonEncode(_history.map((e) => e.toJson()).toList()));
  }

  Future<void> _loadBookmarks() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_bookmarksKey);
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      if (mounted) {
        setState(() {
          _bookmarks = list
              .map((e) => _BookmarkEntry.fromJson(e as Map<String, dynamic>))
              .toList();
        });
      }
    } catch (_) {}
  }

  Future<void> _saveBookmarks() async {
    final prefs = await SharedPreferences.getInstance();
    prefs.setString(_bookmarksKey,
        jsonEncode(_bookmarks.map((e) => e.toJson()).toList()));
  }

  void _addBookmark(String url, String title) {
    if (url.isEmpty || url == 'about:blank') return;
    final label = title.isNotEmpty ? title : url;
    setState(() {
      _bookmarks.removeWhere((e) => e.url == url);
      _bookmarks.insert(0, _BookmarkEntry(url: url, title: label));
    });
    _saveBookmarks();
  }

  void _removeBookmark(String url) {
    setState(() => _bookmarks.removeWhere((e) => e.url == url));
    _saveBookmarks();
  }

  void _recordHistory(String url, String title) {
    if (url.isEmpty || url == 'about:blank') return;
    final label = title.isNotEmpty ? title : url;
    setState(() {
      _history.removeWhere((e) => e.url == url);
      _history.insert(0, _HistoryEntry(url: url, title: label));
      if (_history.length > 10) _history = _history.sublist(0, 10);
    });
    _saveHistory();
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  void _setupEventStream() {
    _eventChannel.receiveBroadcastStream().listen((dynamic event) {
      try {
        final json = jsonDecode(event as String) as Map<String, dynamic>;
        final type = json['type'] as String?;
        if (type == 'bt_status') {
          if (mounted) {
            setState(() => _btStatus = json['status'] as String? ?? 'unknown');
          }
        } else if (type == 'browser_state') {
          if (mounted) {
            final url = json['url'] as String? ?? '';
            final title = json['title'] as String? ?? '';
            final loading = json['loading'] as bool? ?? false;
            setState(() {
              _currentUrl = url;
              _currentTitle = title;
              _loading = loading;
              _canGoBack = json['canGoBack'] as bool? ?? false;
              _canGoForward = json['canGoForward'] as bool? ?? false;
            });
            if (!loading) _recordHistory(url, title);
          }
        } else if (type == 'bookmark_add') {
          final url = json['url'] as String? ?? '';
          final title = json['title'] as String? ?? '';
          if (url.isNotEmpty && mounted) _addBookmark(url, title);
        } else if (type == 'wifi_state') {
          if (mounted) {
            setState(() {
              _wifiEnabled = json['enabled'] as bool? ?? false;
              _wifiSsid = json['ssid'] as String? ?? '';
              _wifiRssi = json['rssi'] as int? ?? 0;
              _wifiToggling = false;
            });
          }
        }
      } catch (e) {
        debugPrint('Event parse error: $e');
      }
    });
  }

  Future<void> _sendCmd(Map<String, dynamic> cmd) async {
    try {
      await _methodChannel.invokeMethod('sendCommand', jsonEncode(cmd));
    } on PlatformException catch (e) {
      debugPrint('sendCommand failed: ${e.message}');
    }
  }

  void _navigate(String url) {
    var target = url.trim();
    if (target.isEmpty) return;
    if (!target.contains('.') || target.contains(' ')) {
      target =
          'https://www.google.com/search?q=${Uri.encodeComponent(target)}';
    } else if (!target.startsWith('http://') &&
        !target.startsWith('https://')) {
      target = 'https://$target';
    }
    _sendCmd({'type': 'browser_cmd', 'action': 'navigate', 'url': target});
    FocusScope.of(context).unfocus();
  }

  void _sendThemeCmd(bool dark) {
    _sendCmd({'type': 'browser_cmd', 'action': 'set_theme', 'dark': dark});
  }

  Future<void> _toggleWifi() async {
    setState(() => _wifiToggling = true);
    final action = _wifiEnabled ? 'wifi_disable' : 'wifi_enable';
    _sendCmd({'type': 'browser_cmd', 'action': action});
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted && _wifiToggling) setState(() => _wifiToggling = false);
    });
  }

  void _connectToWifi(String ssid, String password) {
    setState(() => _wifiToggling = true);
    _sendCmd({
      'type': 'browser_cmd',
      'action': 'wifi_connect',
      'ssid': ssid,
      'password': password,
    });
    Future.delayed(const Duration(seconds: 15), () {
      if (mounted && _wifiToggling) setState(() => _wifiToggling = false);
    });
  }

  void _showWifiConnectDialog() {
    final ssidCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => _WifiConnectDialog(
        ssidController: ssidCtrl,
        passController: passCtrl,
        onConnect: (ssid, pass) => _connectToWifi(ssid, pass),
      ),
    );
  }

  Future<void> _resetConnection() async {
    setState(() => _resetting = true);
    try {
      await _methodChannel.invokeMethod('resetConnection');
    } catch (_) {}
    await Future.delayed(const Duration(seconds: 1));
    if (mounted) setState(() => _resetting = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const _BannerAdWidget(),
            _StatusBar(
              btStatus: _btStatus,
              isConnected: _isConnected,
              resetting: _resetting,
              isDarkMode: _glassesIsDark,
              onReset: _resetConnection,
              onToggleTheme: () {
                setState(() => _glassesIsDark = !_glassesIsDark);
                _sendThemeCmd(_glassesIsDark);
              },
            ),
            if (_currentTitle.isNotEmpty || _currentUrl.isNotEmpty)
              _PageInfoBar(
                title: _currentTitle,
                url: _currentUrl,
                loading: _loading,
                onBookmark: _currentUrl.isNotEmpty
                    ? () => _addBookmark(_currentUrl, _currentTitle)
                    : null,
              ),
            Divider(
                height: 1,
                color: _c(context, const Color(0xFF1E1E1E),
                    const Color(0xFFE0E0E0))),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: _UrlBar(
                controller: _urlController,
                onNavigate: _navigate,
                enabled: _isConnected,
              ),
            ),
            Divider(
                height: 1,
                color: _c(context, const Color(0xFF1E1E1E),
                    const Color(0xFFE0E0E0))),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_history.isNotEmpty) ...[
                      _RecentPagesSection(
                        history: _history,
                        enabled: _isConnected,
                        onNavigate: _navigate,
                        onClear: () {
                          setState(() => _history = []);
                          _saveHistory();
                        },
                      ),
                      const SizedBox(height: 20),
                    ],
                    _WifiCard(
                      enabled: _wifiEnabled,
                      ssid: _wifiSsid,
                      rssi: _wifiRssi,
                      toggling: _wifiToggling,
                      connected: _isConnected,
                      onToggle: _isConnected ? _toggleWifi : null,
                      onAddNetwork:
                          _isConnected ? _showWifiConnectDialog : null,
                    ),
                    const SizedBox(height: 20),
                    _NavControls(
                      canGoBack: _canGoBack,
                      canGoForward: _canGoForward,
                      loading: _loading,
                      enabled: _isConnected,
                      onBack: () =>
                          _sendCmd({'type': 'browser_cmd', 'action': 'back'}),
                      onForward: () =>
                          _sendCmd({'type': 'browser_cmd', 'action': 'forward'}),
                      onReload: () =>
                          _sendCmd({'type': 'browser_cmd', 'action': 'reload'}),
                    ),
                    const SizedBox(height: 28),
                    _TrackpadControls(
                      enabled: _isConnected,
                      onScrollUp: () => _sendCmd(
                          {'type': 'browser_cmd', 'action': 'scroll_up'}),
                      onScrollDown: () => _sendCmd(
                          {'type': 'browser_cmd', 'action': 'scroll_down'}),
                      onScrollLeft: () => _sendCmd(
                          {'type': 'browser_cmd', 'action': 'scroll_left'}),
                      onScrollRight: () => _sendCmd(
                          {'type': 'browser_cmd', 'action': 'scroll_right'}),
                      onCursorMove: (dx, dy) => _sendCmd({
                        'type': 'browser_cmd',
                        'action': 'cursor_move',
                        'dx': dx,
                        'dy': dy,
                      }),
                      onCursorClick: () => _sendCmd(
                          {'type': 'browser_cmd', 'action': 'cursor_click'}),
                      onCursorLongPress: () => _sendCmd({
                        'type': 'browser_cmd',
                        'action': 'cursor_long_press',
                      }),
                      onCursorDragStart: () => _sendCmd({
                        'type': 'browser_cmd',
                        'action': 'cursor_drag_start',
                      }),
                      onCursorDragMove: (dx, dy) => _sendCmd({
                        'type': 'browser_cmd',
                        'action': 'cursor_drag_move',
                        'dx': dx,
                        'dy': dy,
                      }),
                      onCursorDragEnd: () => _sendCmd({
                        'type': 'browser_cmd',
                        'action': 'cursor_drag_end',
                      }),
                    ),
                    const SizedBox(height: 28),
                    _ZoomControls(
                      enabled: _isConnected,
                      onZoomIn: () =>
                          _sendCmd({'type': 'browser_cmd', 'action': 'zoom_in'}),
                      onZoomOut: () => _sendCmd(
                          {'type': 'browser_cmd', 'action': 'zoom_out'}),
                      onTheater: () => _sendCmd(
                          {'type': 'browser_cmd', 'action': 'video_theater'}),
                      onMinimize: () => _sendCmd(
                          {'type': 'browser_cmd', 'action': 'minimize'}),
                    ),
                    const SizedBox(height: 28),
                    _KeyboardControls(
                      enabled: _isConnected,
                      onType: (text) => _sendCmd({
                        'type': 'browser_cmd',
                        'action': 'keyboard_type',
                        'text': text,
                      }),
                      onBackspace: () => _sendCmd({
                        'type': 'browser_cmd',
                        'action': 'keyboard_backspace',
                      }),
                    ),
                    const SizedBox(height: 28),
                    _SecurityControls(
                      enabled: _isConnected,
                      onClearSession: () =>
                          _sendCmd({'type': 'browser_cmd', 'action': 'clear_session'}),
                      onSetThirdPartyCookies: (block) => _sendCmd({
                        'type': 'browser_cmd',
                        'action': 'set_third_party_cookies',
                        'block': block,
                      }),
                    ),
                    const SizedBox(height: 28),
                    _QuickLinks(
                      enabled: _isConnected,
                      onNavigate: _navigate,
                    ),
                    if (_bookmarks.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      _BookmarksSection(
                        bookmarks: _bookmarks,
                        enabled: _isConnected,
                        onNavigate: _navigate,
                        onRemove: _removeBookmark,
                      ),
                    ],
                    const SizedBox(height: 32),
                    _ExitButton(
                      enabled: _isConnected,
                      onExit: () => _sendCmd(
                          {'type': 'browser_cmd', 'action': 'exit_app'}),
                    ),
                    const SizedBox(height: 16),
                    const _DonationCard(),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Status bar ────────────────────────────────────────────────────────────────

class _StatusBar extends StatelessWidget {
  final String btStatus;
  final bool isConnected;
  final bool resetting;
  final bool isDarkMode;
  final VoidCallback onReset;
  final VoidCallback onToggleTheme;

  const _StatusBar({
    required this.btStatus,
    required this.isConnected,
    required this.resetting,
    required this.isDarkMode,
    required this.onReset,
    required this.onToggleTheme,
  });

  Color get _btColor {
    if (isConnected) return Colors.green.shade400;
    if (btStatus == 'listening') return Colors.orange.shade400;
    return Colors.red.shade400;
  }

  IconData get _btIcon {
    if (isConnected) return Icons.bluetooth_connected;
    if (btStatus == 'listening') return Icons.bluetooth_searching;
    return Icons.bluetooth_disabled;
  }

  String get _label {
    if (resetting) return 'Resetting…';
    if (isConnected) {
      final device = btStatus.contains(':')
          ? btStatus.split(':').skip(1).join(':')
          : '';
      return 'Glasses connected${device.isNotEmpty ? ": $device" : ""}';
    }
    if (btStatus == 'listening') return 'Waiting for glasses…';
    return btStatus;
  }

  @override
  Widget build(BuildContext context) {
    final mutedColor =
        _c(context, Colors.white54, const Color(0xFF666666));
    return Container(
      color: _c(context, const Color(0xFF111111), Colors.white),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(_btIcon, color: _btColor, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _label,
              style: TextStyle(
                color: _btColor,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          // Dark / light mode toggle
          IconButton(
            onPressed: onToggleTheme,
            icon: Icon(
              isDarkMode ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
              size: 18,
            ),
            color: mutedColor,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            tooltip: isDarkMode ? 'Switch to light mode' : 'Switch to dark mode',
          ),
          resetting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : TextButton.icon(
                  onPressed: onReset,
                  icon: const Icon(Icons.restart_alt, size: 16),
                  label: const Text('Reset'),
                  style: TextButton.styleFrom(
                    foregroundColor: mutedColor,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
        ],
      ),
    );
  }
}

// ── Page info bar ─────────────────────────────────────────────────────────────

class _PageInfoBar extends StatelessWidget {
  final String title;
  final String url;
  final bool loading;
  final VoidCallback? onBookmark;

  const _PageInfoBar({
    required this.title,
    required this.url,
    required this.loading,
    this.onBookmark,
  });

  @override
  Widget build(BuildContext context) {
    final primaryText = _c(context, Colors.white, const Color(0xFF1A1A1A));
    final mutedText = _c(context, Colors.white54, const Color(0xFF666666));
    return Container(
      color: _c(context, const Color(0xFF0D0D0D), const Color(0xFFF8F8F8)),
      padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
      child: Row(
        children: [
          if (loading)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            )
          else
            Icon(Icons.language, size: 14, color: mutedText),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title.isNotEmpty)
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: primaryText,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                if (url.isNotEmpty)
                  Text(
                    url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: mutedText,
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ),
          if (onBookmark != null && url.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.bookmark_add_outlined),
              onPressed: onBookmark,
              iconSize: 20,
              color: Colors.blueAccent,
              tooltip: 'Bookmark this page',
              padding: const EdgeInsets.symmetric(horizontal: 8),
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            ),
        ],
      ),
    );
  }
}

// ── URL bar ───────────────────────────────────────────────────────────────────

class _UrlBar extends StatelessWidget {
  final TextEditingController controller;
  final void Function(String) onNavigate;
  final bool enabled;

  const _UrlBar({
    required this.controller,
    required this.onNavigate,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = _c(context, Colors.white, const Color(0xFF1A1A1A));
    final mutedColor = _c(context, Colors.white38, const Color(0xFF888888));
    final fillColor =
        _c(context, const Color(0xFF1A1A1A), const Color(0xFFEEEEEE));
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            enabled: enabled,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.go,
            autocorrect: false,
            onSubmitted: onNavigate,
            style: TextStyle(color: textColor, fontSize: 15),
            decoration: InputDecoration(
              hintText:
                  enabled ? 'Search or enter URL…' : 'Connect glasses first',
              hintStyle: TextStyle(color: mutedColor, fontSize: 14),
              prefixIcon: Icon(Icons.search, color: mutedColor, size: 20),
              filled: true,
              fillColor: fillColor,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: enabled ? () => onNavigate(controller.text) : null,
          style: FilledButton.styleFrom(
            backgroundColor: Colors.blueAccent,
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
          child: const Icon(Icons.arrow_forward, size: 20),
        ),
      ],
    );
  }
}

// ── WiFi card ─────────────────────────────────────────────────────────────────

class _WifiCard extends StatelessWidget {
  final bool enabled;
  final String ssid;
  final int rssi;
  final bool toggling;
  final bool connected;
  final VoidCallback? onToggle;
  final VoidCallback? onAddNetwork;

  const _WifiCard({
    required this.enabled,
    required this.ssid,
    required this.rssi,
    required this.toggling,
    required this.connected,
    required this.onToggle,
    required this.onAddNetwork,
  });

  IconData _signalIcon() {
    if (!enabled || ssid.isEmpty) return Icons.wifi_off;
    if (rssi >= -50) return Icons.wifi;
    if (rssi >= -70) return Icons.network_wifi_3_bar;
    return Icons.network_wifi_1_bar;
  }

  Color _signalColor() {
    if (!enabled || ssid.isEmpty) return Colors.white38;
    if (rssi >= -50) return Colors.green.shade400;
    if (rssi >= -70) return Colors.orange.shade400;
    return Colors.red.shade400;
  }

  String _label() {
    if (!connected) return 'Connect glasses to see WiFi status';
    if (toggling) return enabled ? 'Turning off…' : 'Turning on…';
    if (!enabled) return 'WiFi off';
    if (ssid.isEmpty) return 'WiFi on — not connected';
    return ssid;
  }

  @override
  Widget build(BuildContext context) {
    final cardBg =
        _c(context, const Color(0xFF141414), const Color(0xFFF0F0F0));
    final borderColor =
        _c(context, const Color(0xFF2A2A2A), const Color(0xFFDDDDDD));
    final labelColor =
        _c(context, Colors.white38, const Color(0xFF888888));
    final textColor = connected
        ? _c(context, Colors.white, const Color(0xFF1A1A1A))
        : _c(context, Colors.white38, const Color(0xFF888888));
    // Signal color uses muted theme-aware color when off/disconnected
    final signalColor = (!enabled || ssid.isEmpty)
        ? _c(context, Colors.white38, const Color(0xFF888888))
        : _signalColor();
    return Container(
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        children: [
          Row(
            children: [
              Icon(_signalIcon(), color: signalColor, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'GLASSES WIFI',
                      style: TextStyle(
                        color: labelColor,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _label(),
                      style: TextStyle(
                        color: textColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              if (toggling)
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Switch(
                  value: enabled,
                  onChanged: onToggle != null ? (_) => onToggle!() : null,
                  activeThumbColor: Colors.blueAccent,
                ),
            ],
          ),
          if (connected) ...[
            const SizedBox(height: 8),
            Divider(height: 1, color: borderColor),
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: toggling ? null : onAddNetwork,
              icon: const Icon(Icons.add_circle_outline, size: 15),
              label: const Text('Add / change network',
                  style: TextStyle(fontSize: 12)),
              style: TextButton.styleFrom(
                foregroundColor: Colors.blueAccent,
                padding:
                    const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Navigation controls ───────────────────────────────────────────────────────

class _NavControls extends StatelessWidget {
  final bool canGoBack;
  final bool canGoForward;
  final bool loading;
  final bool enabled;
  final VoidCallback onBack;
  final VoidCallback onForward;
  final VoidCallback onReload;

  const _NavControls({
    required this.canGoBack,
    required this.canGoForward,
    required this.loading,
    required this.enabled,
    required this.onBack,
    required this.onForward,
    required this.onReload,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('Navigation'),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _CtrlButton(
                icon: Icons.arrow_back,
                label: 'Back',
                onPressed: (enabled && canGoBack) ? onBack : null,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _CtrlButton(
                icon: loading ? Icons.close : Icons.refresh,
                label: loading ? 'Stop' : 'Reload',
                onPressed: enabled ? onReload : null,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _CtrlButton(
                icon: Icons.arrow_forward,
                label: 'Forward',
                onPressed: (enabled && canGoForward) ? onForward : null,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ── Trackpad controls ─────────────────────────────────────────────────────────

class _TrackpadControls extends StatelessWidget {
  final bool enabled;
  final VoidCallback onScrollUp;
  final VoidCallback onScrollDown;
  final VoidCallback onScrollLeft;
  final VoidCallback onScrollRight;
  final void Function(double dx, double dy) onCursorMove;
  final VoidCallback onCursorClick;
  final VoidCallback onCursorLongPress;
  final VoidCallback onCursorDragStart;
  final void Function(double dx, double dy) onCursorDragMove;
  final VoidCallback onCursorDragEnd;

  const _TrackpadControls({
    required this.enabled,
    required this.onScrollUp,
    required this.onScrollDown,
    required this.onScrollLeft,
    required this.onScrollRight,
    required this.onCursorMove,
    required this.onCursorClick,
    required this.onCursorLongPress,
    required this.onCursorDragStart,
    required this.onCursorDragMove,
    required this.onCursorDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('Trackpad'),
        const SizedBox(height: 12),
        Center(
          child: _CornerScrollButton(
            icon: Icons.keyboard_arrow_up,
            onPressed: enabled ? onScrollUp : null,
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 160,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _CornerScrollButton(
                icon: Icons.keyboard_arrow_left,
                onPressed: enabled ? onScrollLeft : null,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _Trackpad(
                  enabled: enabled,
                  onMove: onCursorMove,
                  onTap: onCursorClick,
                  onLongPress: onCursorLongPress,
                  onDragStart: onCursorDragStart,
                  onDragMove: onCursorDragMove,
                  onDragEnd: onCursorDragEnd,
                ),
              ),
              const SizedBox(width: 8),
              _CornerScrollButton(
                icon: Icons.keyboard_arrow_right,
                onPressed: enabled ? onScrollRight : null,
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Center(
          child: _CornerScrollButton(
            icon: Icons.keyboard_arrow_down,
            onPressed: enabled ? onScrollDown : null,
          ),
        ),
      ],
    );
  }
}

class _Trackpad extends StatefulWidget {
  final bool enabled;
  final void Function(double dx, double dy) onMove;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onDragStart;
  final void Function(double dx, double dy) onDragMove;
  final VoidCallback onDragEnd;

  const _Trackpad({
    required this.enabled,
    required this.onMove,
    required this.onTap,
    required this.onLongPress,
    required this.onDragStart,
    required this.onDragMove,
    required this.onDragEnd,
  });

  @override
  State<_Trackpad> createState() => _TrackpadState();
}

class _TrackpadState extends State<_Trackpad> {
  bool _pressed = false;
  bool _dragLock = false;
  Offset? _dragStart;
  double _pendingDx = 0;
  double _pendingDy = 0;
  int _lastSentMs = 0;
  int _lastTapUpTimeMs = 0;
  Timer? _longPressTimer;
  Timer? _pendingTapTimer;
  bool _longPressTriggered = false;
  bool _isDragging = false;

  static const _longPressMs = 500;
  static const _doubleTapWindowMs = 300;
  static const _tapSlop = 12.0;

  @override
  void dispose() {
    _longPressTimer?.cancel();
    _pendingTapTimer?.cancel();
    super.dispose();
  }

  void _onPointerDown(PointerDownEvent e) {
    if (!widget.enabled) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    _dragStart = e.localPosition;
    _pendingDx = 0;
    _pendingDy = 0;
    _isDragging = false;
    _longPressTriggered = false;

    if (now - _lastTapUpTimeMs < _doubleTapWindowMs) {
      _pendingTapTimer?.cancel();
      _pendingTapTimer = null;
      _lastTapUpTimeMs = 0;
      _dragLock = true;
      setState(() => _pressed = true);
      HapticFeedback.mediumImpact();
      widget.onDragStart();
    } else {
      setState(() => _pressed = true);
      HapticFeedback.selectionClick();
      _longPressTimer?.cancel();
      _longPressTimer = Timer(const Duration(milliseconds: _longPressMs), () {
        if (mounted && !_isDragging && !_dragLock) {
          _longPressTriggered = true;
          HapticFeedback.mediumImpact();
          widget.onLongPress();
        }
      });
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!widget.enabled || _dragStart == null) return;
    _pendingDx += e.delta.dx;
    _pendingDy += e.delta.dy;

    if (!_isDragging && !_dragLock) {
      final dx = e.localPosition.dx - _dragStart!.dx;
      final dy = e.localPosition.dy - _dragStart!.dy;
      if (dx.abs() > _tapSlop || dy.abs() > _tapSlop) {
        _isDragging = true;
        _longPressTimer?.cancel();
      }
    }

    if (_isDragging || _dragLock) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastSentMs >= 50) {
        if (_dragLock) {
          widget.onDragMove(_pendingDx, _pendingDy);
        } else {
          widget.onMove(_pendingDx, _pendingDy);
        }
        _pendingDx = 0;
        _pendingDy = 0;
        _lastSentMs = now;
      }
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    if (!widget.enabled) return;
    _longPressTimer?.cancel();

    if (_dragLock) {
      if (_pendingDx.abs() > 0.5 || _pendingDy.abs() > 0.5) {
        widget.onDragMove(_pendingDx, _pendingDy);
      }
      _pendingDx = 0;
      _pendingDy = 0;
      widget.onDragEnd();
      HapticFeedback.lightImpact();
      setState(() {
        _pressed = false;
        _dragLock = false;
      });
      _dragStart = null;
      _isDragging = false;
      return;
    }

    if (_pendingDx.abs() > 0.5 || _pendingDy.abs() > 0.5) {
      widget.onMove(_pendingDx, _pendingDy);
    }
    _pendingDx = 0;
    _pendingDy = 0;

    if (!_isDragging && !_longPressTriggered) {
      HapticFeedback.selectionClick();
      _lastTapUpTimeMs = DateTime.now().millisecondsSinceEpoch;
      _pendingTapTimer?.cancel();
      _pendingTapTimer = Timer(
        const Duration(milliseconds: _doubleTapWindowMs),
        () {
          if (mounted) widget.onTap();
          _pendingTapTimer = null;
        },
      );
    }

    setState(() => _pressed = false);
    _dragStart = null;
    _isDragging = false;
    _longPressTriggered = false;
  }

  void _onPointerCancel(PointerCancelEvent e) {
    _longPressTimer?.cancel();
    _pendingTapTimer?.cancel();
    _pendingTapTimer = null;
    _pendingDx = 0;
    _pendingDy = 0;
    if (_dragLock) {
      widget.onDragEnd();
    }
    setState(() {
      _pressed = false;
      _dragLock = false;
    });
    _dragStart = null;
    _isDragging = false;
    _longPressTriggered = false;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final Color borderColor = _dragLock
        ? Colors.orangeAccent.withValues(alpha: 0.7)
        : (_pressed
            ? (isDark ? Colors.white24 : const Color(0xFF999999))
            : (isDark ? Colors.white12 : const Color(0xFFCCCCCC)));
    final Color bgColor = _dragLock
        ? const Color(0xFF2A1A00)
        : (_pressed
            ? _c(context, const Color(0xFF252525), const Color(0xFFDDDDDD))
            : _c(context, const Color(0xFF1A1A1A), const Color(0xFFEEEEEE)));
    final Color iconColor = _dragLock
        ? Colors.orangeAccent.withValues(alpha: 0.8)
        : (widget.enabled
            ? (isDark ? Colors.white24 : const Color(0xFF999999))
            : (isDark ? Colors.white12 : const Color(0xFFCCCCCC)));
    final String label = _dragLock ? 'DRAG MODE' : 'TAP · HOLD · DRAG';

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (_) {},
      onHorizontalDragUpdate: (_) {},
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        onPointerCancel: _onPointerCancel,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: borderColor),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _dragLock ? Icons.open_with : Icons.touch_app,
                  color: iconColor,
                  size: 28,
                ),
                const SizedBox(height: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: iconColor,
                    fontSize: 9,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Zoom controls ─────────────────────────────────────────────────────────────

class _ZoomControls extends StatelessWidget {
  final bool enabled;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onTheater;
  final VoidCallback onMinimize;

  const _ZoomControls({
    required this.enabled,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onTheater,
    required this.onMinimize,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('Zoom & Video'),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _CtrlButton(
                icon: Icons.zoom_out,
                label: 'Zoom Out',
                onPressed: enabled ? onZoomOut : null,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _CtrlButton(
                icon: Icons.zoom_in,
                label: 'Zoom In',
                onPressed: enabled ? onZoomIn : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _CtrlButton(
                icon: Icons.theaters,
                label: 'Theater',
                onPressed: enabled ? onTheater : null,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _CtrlButton(
                icon: Icons.fullscreen_exit,
                label: 'Exit Full',
                onPressed: enabled ? onMinimize : null,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ── Quick links ───────────────────────────────────────────────────────────────

class _QuickLinks extends StatelessWidget {
  final bool enabled;
  final void Function(String) onNavigate;

  const _QuickLinks({required this.enabled, required this.onNavigate});

  static const _links = [
    ('Google', 'https://www.google.com'),
    ('Wikipedia', 'https://en.wikipedia.org'),
    ('News', 'https://news.google.com'),
    ('YouTube', 'https://m.youtube.com'),
    ('Reddit', 'https://old.reddit.com'),
    ('Maps', 'https://maps.google.com'),
  ];

  @override
  Widget build(BuildContext context) {
    final chipBg =
        _c(context, const Color(0xFF1A1A1A), const Color(0xFFEEEEEE));
    final chipText = enabled
        ? _c(context, Colors.white, const Color(0xFF1A1A1A))
        : _c(context, Colors.white38, const Color(0xFF888888));
    final chipBorder =
        _c(context, const Color(0xFF333333), const Color(0xFFCCCCCC));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('Quick Links'),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _links.map((link) {
            return ActionChip(
              label: Text(link.$1),
              onPressed: enabled ? () => onNavigate(link.$2) : null,
              backgroundColor: chipBg,
              labelStyle: TextStyle(color: chipText, fontSize: 13),
              side: BorderSide(color: chipBorder),
            );
          }).toList(),
        ),
      ],
    );
  }
}

// ── Keyboard controls ─────────────────────────────────────────────────────────

class _KeyboardControls extends StatefulWidget {
  final bool enabled;
  final void Function(String text) onType;
  final VoidCallback onBackspace;

  const _KeyboardControls({
    required this.enabled,
    required this.onType,
    required this.onBackspace,
  });

  @override
  State<_KeyboardControls> createState() => _KeyboardControlsState();
}

class _KeyboardControlsState extends State<_KeyboardControls> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _send() {
    final text = _ctrl.text;
    if (text.isEmpty) return;
    widget.onType(text);
    _ctrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    final textColor = _c(context, Colors.white, const Color(0xFF1A1A1A));
    final mutedColor = _c(context, Colors.white38, const Color(0xFF888888));
    final fillColor =
        _c(context, const Color(0xFF1A1A1A), const Color(0xFFEEEEEE));
    final bsBorderColor = widget.enabled
        ? _c(context, Colors.white24, const Color(0xFF999999))
        : _c(context, Colors.white12, const Color(0xFFCCCCCC));
    final bsFgColor = widget.enabled
        ? _c(context, Colors.white70, const Color(0xFF333333))
        : _c(context, Colors.white24, const Color(0xFF999999));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('Keyboard'),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _ctrl,
                enabled: widget.enabled,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                style: TextStyle(color: textColor, fontSize: 15),
                decoration: InputDecoration(
                  hintText: widget.enabled
                      ? 'Type on glasses…'
                      : 'Connect glasses first',
                  hintStyle: TextStyle(color: mutedColor, fontSize: 14),
                  filled: true,
                  fillColor: fillColor,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 48,
              width: 48,
              child: OutlinedButton(
                onPressed: widget.enabled ? widget.onBackspace : null,
                style: OutlinedButton.styleFrom(
                  foregroundColor: bsFgColor,
                  side: BorderSide(color: bsBorderColor),
                  padding: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: const Icon(Icons.backspace_outlined, size: 20),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: widget.enabled ? _send : null,
              style: FilledButton.styleFrom(
                backgroundColor: Colors.blueAccent,
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              child: const Icon(Icons.keyboard_return, size: 20),
            ),
          ],
        ),
      ],
    );
  }
}

// ── Security controls ─────────────────────────────────────────────────────────

class _SecurityControls extends StatefulWidget {
  final bool enabled;
  final VoidCallback onClearSession;
  final void Function(bool block) onSetThirdPartyCookies;

  const _SecurityControls({
    required this.enabled,
    required this.onClearSession,
    required this.onSetThirdPartyCookies,
  });

  @override
  State<_SecurityControls> createState() => _SecurityControlsState();
}

class _SecurityControlsState extends State<_SecurityControls> {
  bool _blockThirdParty = false;

  @override
  Widget build(BuildContext context) {
    final cardBg =
        _c(context, const Color(0xFF141414), const Color(0xFFF0F0F0));
    final borderColor =
        _c(context, const Color(0xFF2A2A2A), const Color(0xFFDDDDDD));
    final iconColor = _c(context, Colors.white54, const Color(0xFF666666));
    final primaryText = _c(context, Colors.white, const Color(0xFF1A1A1A));
    final mutedText = _c(context, Colors.white38, const Color(0xFF888888));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('Security'),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Column(
            children: [
              Row(
                children: [
                  Icon(Icons.cookie_outlined, color: iconColor, size: 18),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Block 3rd-party cookies',
                          style: TextStyle(
                              color: primaryText,
                              fontSize: 13,
                              fontWeight: FontWeight.w500),
                        ),
                        Text(
                          'Blocks trackers, keeps logins',
                          style: TextStyle(color: mutedText, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: _blockThirdParty,
                    onChanged: widget.enabled
                        ? (v) {
                            setState(() => _blockThirdParty = v);
                            widget.onSetThirdPartyCookies(v);
                          }
                        : null,
                    activeThumbColor: Colors.blueAccent,
                  ),
                ],
              ),
              Divider(height: 1, color: borderColor),
              TextButton.icon(
                onPressed: widget.enabled
                    ? () {
                        widget.onClearSession();
                        if (_blockThirdParty) {
                          setState(() => _blockThirdParty = false);
                        }
                      }
                    : null,
                icon: const Icon(Icons.logout, size: 15),
                label: const Text('Clear session & log out',
                    style: TextStyle(fontSize: 13)),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.redAccent,
                  minimumSize: const Size(double.infinity, 44),
                  alignment: Alignment.centerLeft,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Shared widgets ────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        color: _c(context, Colors.white38, const Color(0xFF888888)),
        fontSize: 11,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.5,
      ),
    );
  }
}

class _CtrlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  const _CtrlButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final fgColor = onPressed != null
        ? _c(context, Colors.white, const Color(0xFF1A1A1A))
        : _c(context, Colors.white38, const Color(0xFF888888));
    final borderColor = onPressed != null
        ? _c(context, Colors.white24, const Color(0xFF999999))
        : _c(context, Colors.white12, const Color(0xFFCCCCCC));
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label, style: const TextStyle(fontSize: 13)),
      style: OutlinedButton.styleFrom(
        foregroundColor: fgColor,
        side: BorderSide(color: borderColor),
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}

class _CornerScrollButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;

  const _CornerScrollButton({required this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final fgColor = onPressed != null
        ? _c(context, Colors.white, const Color(0xFF1A1A1A))
        : _c(context, Colors.white38, const Color(0xFF888888));
    final borderColor = onPressed != null
        ? _c(context, Colors.white24, const Color(0xFF999999))
        : _c(context, Colors.white12, const Color(0xFFCCCCCC));
    return SizedBox(
      width: 54,
      height: 54,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: fgColor,
          side: BorderSide(color: borderColor),
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
        ),
        child: Icon(icon, size: 26),
      ),
    );
  }
}

// ── Recent pages ─────────────────────────────────────────────────────────────

class _RecentPagesSection extends StatefulWidget {
  final List<_HistoryEntry> history;
  final bool enabled;
  final void Function(String) onNavigate;
  final VoidCallback onClear;

  const _RecentPagesSection({
    required this.history,
    required this.enabled,
    required this.onNavigate,
    required this.onClear,
  });

  @override
  State<_RecentPagesSection> createState() => _RecentPagesSectionState();
}

class _RecentPagesSectionState extends State<_RecentPagesSection> {
  static const _collapsedCount = 5;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final cardBg =
        _c(context, const Color(0xFF141414), const Color(0xFFF0F0F0));
    final borderColor =
        _c(context, const Color(0xFF2A2A2A), const Color(0xFFDDDDDD));
    final primaryText = widget.enabled
        ? _c(context, Colors.white, const Color(0xFF1A1A1A))
        : _c(context, Colors.white38, const Color(0xFF888888));
    final mutedText = _c(context, Colors.white38, const Color(0xFF888888));
    final arrowColor = widget.enabled
        ? _c(context, Colors.white38, const Color(0xFF888888))
        : _c(context, Colors.white12, const Color(0xFFCCCCCC));

    final hasMore = widget.history.length > _collapsedCount;
    final visible =
        _expanded ? widget.history : widget.history.take(_collapsedCount).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
                child: _SectionLabel('Continue where you left off')),
            TextButton(
              onPressed: widget.onClear,
              style: TextButton.styleFrom(
                foregroundColor: mutedText,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Clear', style: TextStyle(fontSize: 11)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor),
          ),
          child: Column(
            children: [
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: visible.length,
                separatorBuilder: (_, __) =>
                    Divider(height: 1, color: borderColor),
                itemBuilder: (_, i) {
                  final entry = visible[i];
                  final isFirst = i == 0;
                  final isLast = i == visible.length - 1 && !hasMore;
                  return InkWell(
                    borderRadius: isFirst
                        ? const BorderRadius.vertical(top: Radius.circular(12))
                        : isLast
                            ? const BorderRadius.vertical(
                                bottom: Radius.circular(12))
                            : BorderRadius.zero,
                    onTap: widget.enabled ? () => widget.onNavigate(entry.url) : null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 11),
                      child: Row(
                        children: [
                          Icon(Icons.history, size: 15, color: mutedText),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  entry.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: primaryText,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                Text(
                                  entry.url,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: mutedText,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 6),
                          Icon(Icons.arrow_forward_ios, size: 12, color: arrowColor),
                        ],
                      ),
                    ),
                  );
                },
              ),
              if (hasMore) ...[
                Divider(height: 1, color: borderColor),
                InkWell(
                  borderRadius:
                      const BorderRadius.vertical(bottom: Radius.circular(12)),
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _expanded ? Icons.expand_less : Icons.expand_more,
                          size: 16,
                          color: mutedText,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _expanded
                              ? 'Collapse'
                              : 'Show all (${widget.history.length})',
                          style: TextStyle(
                            color: mutedText,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ── Bookmarks ─────────────────────────────────────────────────────────────────

class _BookmarksSection extends StatelessWidget {
  final List<_BookmarkEntry> bookmarks;
  final bool enabled;
  final void Function(String) onNavigate;
  final void Function(String) onRemove;

  const _BookmarksSection({
    required this.bookmarks,
    required this.enabled,
    required this.onNavigate,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final cardBg =
        _c(context, const Color(0xFF141414), const Color(0xFFF0F0F0));
    final borderColor =
        _c(context, const Color(0xFF2A2A2A), const Color(0xFFDDDDDD));
    final primaryText = enabled
        ? _c(context, Colors.white, const Color(0xFF1A1A1A))
        : _c(context, Colors.white38, const Color(0xFF888888));
    final mutedText = _c(context, Colors.white38, const Color(0xFF888888));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('Bookmarks'),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor),
          ),
          child: ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: bookmarks.length,
            separatorBuilder: (_, __) => Divider(height: 1, color: borderColor),
            itemBuilder: (_, i) {
              final entry = bookmarks[i];
              final isFirst = i == 0;
              final isLast = i == bookmarks.length - 1;
              return InkWell(
                borderRadius: isFirst
                    ? const BorderRadius.vertical(top: Radius.circular(12))
                    : isLast
                        ? const BorderRadius.vertical(bottom: Radius.circular(12))
                        : BorderRadius.zero,
                onTap: enabled ? () => onNavigate(entry.url) : null,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                  child: Row(
                    children: [
                      Icon(Icons.bookmark_outline, size: 15, color: mutedText),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              entry.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: primaryText,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            Text(
                              entry.url,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: mutedText, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: () => onRemove(entry.url),
                        color: mutedText,
                        padding: EdgeInsets.zero,
                        constraints:
                            const BoxConstraints(minWidth: 32, minHeight: 32),
                        tooltip: 'Remove bookmark',
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ── Exit button ───────────────────────────────────────────────────────────────

class _ExitButton extends StatelessWidget {
  final bool enabled;
  final VoidCallback onExit;

  const _ExitButton({required this.enabled, required this.onExit});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        icon: const Icon(Icons.power_settings_new, size: 18),
        label: const Text('Exit Glasses App'),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.red.shade400,
          side: BorderSide(color: Colors.red.shade400.withValues(alpha: 0.5)),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        onPressed: enabled
            ? () => showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Exit Glasses App'),
                    content: const Text(
                        'This will close the browser on the glasses. Continue?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(true),
                        style: TextButton.styleFrom(
                            foregroundColor: Colors.red.shade400),
                        child: const Text('Exit'),
                      ),
                    ],
                  ),
                ).then((confirmed) {
                  if (confirmed == true) onExit();
                })
            : null,
      ),
    );
  }
}

// ── Banner ad ─────────────────────────────────────────────────────────────────

class _BannerAdWidget extends StatefulWidget {
  const _BannerAdWidget();

  @override
  State<_BannerAdWidget> createState() => _BannerAdWidgetState();
}

class _BannerAdWidgetState extends State<_BannerAdWidget> {
  BannerAd? _ad;
  bool _loaded = false;

  static const _adUnitId = admobBannerUnitId;

  @override
  void initState() {
    super.initState();
    _ad = BannerAd(
      adUnitId: _adUnitId,
      size: AdSize.banner,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (_) => setState(() => _loaded = true),
        onAdFailedToLoad: (ad, _) => ad.dispose(),
      ),
    )..load();
  }

  @override
  void dispose() {
    _ad?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded || _ad == null) return const SizedBox.shrink();
    return SizedBox(
      width: _ad!.size.width.toDouble(),
      height: _ad!.size.height.toDouble(),
      child: AdWidget(ad: _ad!),
    );
  }
}

// ── Donation card ─────────────────────────────────────────────────────────────

class _DonationCard extends StatelessWidget {
  const _DonationCard();

  static const _kofiUrl = kofiUrl;

  @override
  Widget build(BuildContext context) {
    final cardBg =
        _c(context, const Color(0xFF141414), const Color(0xFFF0F0F0));
    final borderColor =
        _c(context, const Color(0xFF2A2A2A), const Color(0xFFDDDDDD));
    final textColor =
        _c(context, Colors.white70, const Color(0xFF444444));
    final mutedText =
        _c(context, Colors.white38, const Color(0xFF888888));

    return Container(
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          const Icon(Icons.favorite_outline, color: Colors.pinkAccent, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Support this project',
                  style: TextStyle(
                    color: textColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  'Free & open source — donations keep it alive',
                  style: TextStyle(color: mutedText, fontSize: 11),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => launchUrl(
              Uri.parse(_kofiUrl),
              mode: LaunchMode.externalApplication,
            ),
            style: TextButton.styleFrom(
              foregroundColor: Colors.pinkAccent,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Donate', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

// ── WiFi connect dialog ───────────────────────────────────────────────────────

class _WifiConnectDialog extends StatefulWidget {
  final TextEditingController ssidController;
  final TextEditingController passController;
  final void Function(String ssid, String password) onConnect;

  const _WifiConnectDialog({
    required this.ssidController,
    required this.passController,
    required this.onConnect,
  });

  @override
  State<_WifiConnectDialog> createState() => _WifiConnectDialogState();
}

class _WifiConnectDialogState extends State<_WifiConnectDialog> {
  bool _obscurePass = true;

  @override
  Widget build(BuildContext context) {
    final dialogBg =
        _c(context, const Color(0xFF1A1A1A), Colors.white);
    final fieldBg =
        _c(context, const Color(0xFF252525), const Color(0xFFEEEEEE));
    final textColor = _c(context, Colors.white, const Color(0xFF1A1A1A));
    final labelColor = _c(context, Colors.white54, const Color(0xFF666666));
    final eyeColor = _c(context, Colors.white38, const Color(0xFF888888));

    return AlertDialog(
      backgroundColor: dialogBg,
      title: Text(
        'Connect Glasses to WiFi',
        style: TextStyle(color: textColor, fontSize: 16),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: widget.ssidController,
            autofocus: true,
            style: TextStyle(color: textColor),
            decoration: InputDecoration(
              labelText: 'Network name (SSID)',
              labelStyle: TextStyle(color: labelColor),
              filled: true,
              fillColor: fieldBg,
              border: const OutlineInputBorder(borderSide: BorderSide.none),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: widget.passController,
            obscureText: _obscurePass,
            style: TextStyle(color: textColor),
            decoration: InputDecoration(
              labelText: 'Password (leave blank for open networks)',
              labelStyle: TextStyle(color: labelColor),
              filled: true,
              fillColor: fieldBg,
              border: const OutlineInputBorder(borderSide: BorderSide.none),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscurePass ? Icons.visibility_off : Icons.visibility,
                  color: eyeColor,
                  size: 20,
                ),
                onPressed: () => setState(() => _obscurePass = !_obscurePass),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel', style: TextStyle(color: labelColor)),
        ),
        FilledButton(
          onPressed: () {
            final ssid = widget.ssidController.text.trim();
            if (ssid.isEmpty) return;
            widget.onConnect(ssid, widget.passController.text);
            Navigator.pop(context);
          },
          style: FilledButton.styleFrom(backgroundColor: Colors.blueAccent),
          child: const Text('Connect'),
        ),
      ],
    );
  }
}
