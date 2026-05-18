import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

const _kGreen = Color(0xFF00FF00);
const _kBlack = Color(0xFF000000);
const _kSoftGreen = Color(0xFF88FF88);

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  static const _eventChannel =
      EventChannel('com.rokid.rokid_browser_glasses/events');
  static const _methodChannel =
      MethodChannel('com.rokid.rokid_browser_glasses/methods');

  late final WebViewController _webController;
  bool _webViewReady = false;
  String _url = '';
  String _title = 'ROKID BROWSER';
  bool _loading = false;
  bool _connected = false;
  String _btStatus = 'scanning';
  bool _canGoBack = false;

  double _cursorX = 0;
  double _cursorY = 0;
  bool _cursorVisible = false;
  bool _cursorDragging = false;
  Timer? _cursorHideTimer;

  double _pageZoom = 0.75;
  bool _webViewConfigured = false;
  bool _isDark = true;
  Timer? _configRetryTimer;
  bool _passthrough = false;
  int _lastGestureMs = 0; // debounce for touchpad swipes
  static const _gestureDebounceMs = 700;

  // Double-tap detection for centre-button (play/pause → single, minimize/back → double)
  Timer? _centerTapTimer;
  int _lastCenterTapMs = 0;
  static const _centerDoubleTapMs = 300;

  @override
  void initState() {
    super.initState();
    _initWebView();
    _setupEventStream();
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final size = MediaQuery.of(context).size;
        setState(() {
          _cursorX = size.width / 2;
          _cursorY = size.height / 2;
        });
      }
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _cursorHideTimer?.cancel();
    _configRetryTimer?.cancel();
    _centerTapTimer?.cancel();
    super.dispose();
  }

  void _initWebView() {
    _webController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(_kBlack)
      ..setUserAgent(
        'Mozilla/5.0 (Linux; Android 12; Pixel 6) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/120.0.0.0 Mobile Safari/537.36',
      )
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (url) {
          setState(() {
            _url = url;
            _loading = true;
          });
          _sendState(url: url, loading: true);
          if (!_webViewConfigured) {
            _startConfigureRetry();
          }
        },
        onPageFinished: (url) async {
          // Patch matchMedia + setForceDark BEFORE the viewport change below,
          // so Google's layout-triggered re-check of prefers-color-scheme
          // already sees our override and doesn't switch to light mode.
          await _applyTheme(_isDark);

          // Reset viewport and apply persistent zoom for the AR display
          final zoom = _pageZoom.toStringAsFixed(2);
          await _webController.runJavaScript('''
(function(){
  var m=document.querySelector('meta[name="viewport"]');
  if(!m){m=document.createElement('meta');m.name='viewport';document.head.appendChild(m);}
  m.content='width=device-width,initial-scale=1.0,maximum-scale=5.0,minimum-scale=0.1';
  if(document.body)document.body.style.zoom='$zoom';
  document.querySelectorAll('video').forEach(function(v){v.muted=false;if(v.volume>0.5)v.volume=0.5;});
})();''');
          // Re-apply after zoom/viewport change triggers Google's layout re-check
          await _applyTheme(_isDark);

          final title = await _webController.getTitle() ?? '';
          final canGoBack = await _webController.canGoBack();
          final canGoForward = await _webController.canGoForward();
          if (mounted) {
            setState(() {
              _url = url;
              _title = title.isNotEmpty ? title : 'ROKID BROWSER';
              _loading = false;
              _canGoBack = canGoBack;
            });
          }
          _sendState(
            url: url,
            title: title,
            loading: false,
            canGoBack: canGoBack,
            canGoForward: canGoForward,
          );
        },
        onWebResourceError: (_) {
          if (mounted) setState(() => _loading = false);
        },
      ));

    // Enable mixed content and configure Android-specific settings
    if (defaultTargetPlatform == TargetPlatform.android) {
      final android = _webController.platform as AndroidWebViewController;
      android.setMixedContentMode(MixedContentMode.compatibilityMode);
      // Prevent OS accessibility font scaling from inflating page text
      android.setTextZoom(100);
      // Allow media (e.g. YouTube) to play without requiring a tap gesture
      android.setMediaPlaybackRequiresUserGesture(false);
    }

    setState(() => _webViewReady = true);
  }

  void _startConfigureRetry() {
    _configRetryTimer?.cancel();
    _configRetryTimer = Timer.periodic(const Duration(milliseconds: 150), (t) async {
      if (!mounted) { t.cancel(); return; }
      try {
        final ok = await _methodChannel.invokeMethod<bool>('configureWebViewZoom');
        if (ok == true) {
          t.cancel();
          _webViewConfigured = true;
          await _applyTheme(_isDark);
        }
      } catch (_) {}
    });
  }

  void _setupEventStream() {
    _eventChannel.receiveBroadcastStream().listen((dynamic event) {
      try {
        final json = jsonDecode(event as String) as Map<String, dynamic>;
        final type = json['type'] as String?;
        if (type == 'bt_status') {
          final status = json['status'] as String? ?? 'unknown';
          if (mounted) {
            setState(() {
              _btStatus = status;
              _connected = status.startsWith('connected');
            });
          }
        } else if (type == 'browser_cmd') {
          _handleCommand(json);
        }
      } catch (e) {
        debugPrint('Event parse error: $e');
      }
    });
  }

  Future<void> _applyTheme(bool dark) async {
    try {
      await _methodChannel.invokeMethod('setForceDark', dark);
    } catch (_) {}
    if (dark) {
      await _webController.runJavaScript(r'''
(function(){
  if(window.__rokidThemeInterval)clearInterval(window.__rokidThemeInterval);
  // Defined once outside enforce() — recreating closures every 400ms is wasteful
  var _skip={SCRIPT:1,STYLE:1,VIDEO:1,CANVAS:1,IMG:1,HEAD:1,LINK:1,META:1,NOSCRIPT:1,INPUT:1,TEXTAREA:1};
  var _svg={PATH:1,CIRCLE:1,RECT:1,POLYGON:1,POLYLINE:1,LINE:1,ELLIPSE:1,USE:1,G:1,SVG:1,SYMBOL:1};
  // #808080 is readable on both dark and light backgrounds — avoids the need for
  // per-element background detection which is expensive and unreliable in shadow DOM.
  function _walk(root){
    var all=root.querySelectorAll('*');
    for(var i=0;i<all.length;i++){
      var el=all[i];
      if(!_skip[el.tagName]){
        el.style.setProperty('color','#808080','important');
        if(_svg[el.tagName])el.style.setProperty('fill','#808080','important');
      }
      if(el.shadowRoot)_walk(el.shadowRoot);
    }
  }
  function enforce(){
    // Don't mutate styles while the user is actively typing — avoids disrupting focus/selection
    var ae=document.activeElement;
    if(ae&&(ae.tagName==='INPUT'||ae.tagName==='TEXTAREA'||ae.isContentEditable))return;
    // Override JS matchMedia so sites that check via JS see dark
    var _o=window.__rokidOrigMM||(window.__rokidOrigMM=window.matchMedia);
    window.matchMedia=function(q){
      if(typeof q==='string'&&q.indexOf('prefers-color-scheme')>=0)
        return{matches:q.replace(/\s/g,'').indexOf('dark')>=0,media:q,onchange:null,
          addListener:function(){},removeListener:function(){},
          addEventListener:function(){},removeEventListener:function(){},
          dispatchEvent:function(){return false;}};
      return _o.call(this,q);
    };
    // Meta color-scheme — triggers live CSS prefers-color-scheme re-evaluation
    var meta=document.querySelector('meta[name="color-scheme"]');
    if(!meta&&document.head){meta=document.createElement('meta');meta.name='color-scheme';document.head.appendChild(meta);}
    if(meta)meta.content='dark';
    document.documentElement.style.colorScheme='dark';
    // CSS: base dark background + YouTube CSS variable overrides for components
    // that read CSS custom properties (these do cross shadow DOM boundaries).
    var s=document.getElementById('__rk');
    if(!s&&document.head){s=document.createElement('style');s.id='__rk';document.head.appendChild(s);}
    if(s)s.textContent=':root{color-scheme:dark!important;--yt-spec-text-secondary:#808080!important;--yt-spec-text-disabled:#808080!important;--yt-spec-icon-inactive:#808080!important;--yt-spec-icon-disabled:#808080!important;}html,body{background:#000!important;color:#808080!important;}';
    // Framework-specific dark attributes (YouTube reads `dark`, many CMSes read data-theme)
    document.documentElement.setAttribute('dark','');
    document.documentElement.setAttribute('data-theme','dark');
    document.documentElement.setAttribute('data-color-mode','dark');
    document.documentElement.classList.add('dark');
    // Remove any stale brightness overlay from earlier version
    var ov=document.getElementById('__rk_ov');if(ov)ov.remove();
    // Walk light DOM + all shadow roots and force inline !important color/fill.
    _walk(document);
  }
  enforce();
  window.__rokidThemeInterval=setInterval(enforce,400);
})();''');
    } else {
      await _webController.runJavaScript(r'''
(function(){
  if(window.__rokidThemeInterval){clearInterval(window.__rokidThemeInterval);window.__rokidThemeInterval=null;}
  if(window.__rokidOrigMM){window.matchMedia=window.__rokidOrigMM;window.__rokidOrigMM=null;}
  var meta=document.querySelector('meta[name="color-scheme"]');
  if(meta)meta.content='light';
  document.documentElement.style.colorScheme='';
  var s=document.getElementById('__rk');if(s)s.remove();
  var ov=document.getElementById('__rk_ov');if(ov)ov.remove();
  document.documentElement.removeAttribute('dark');
  document.documentElement.removeAttribute('data-theme');
  document.documentElement.removeAttribute('data-color-mode');
  document.documentElement.classList.remove('dark');
  // Remove all inline color/fill we forced in dark mode (including shadow DOM).
  function _clean(root){
    var all=root.querySelectorAll('*');
    for(var i=0;i<all.length;i++){
      all[i].style.removeProperty('color');
      all[i].style.removeProperty('fill');
      if(all[i].shadowRoot)_clean(all[i].shadowRoot);
    }
  }
  _clean(document);
})();''');
    }
  }

  Future<void> _handleCommand(Map<String, dynamic> cmd) async {
    final action = cmd['action'] as String?;
    switch (action) {
      case 'navigate':
        final url = cmd['url'] as String? ?? '';
        if (url.isNotEmpty) {
          var loadUrl = url;
          if (!loadUrl.startsWith('http://') &&
              !loadUrl.startsWith('https://')) {
            loadUrl = 'https://$loadUrl';
          }
          _webController.loadRequest(Uri.parse(loadUrl));
        }
      case 'back':
        _webController.goBack();
      case 'forward':
        _webController.goForward();
      case 'reload':
        _webController.reload();
      case 'scroll_down':
        _webController.runJavaScript('window.scrollBy(0, 120)');
      case 'scroll_up':
        _webController.runJavaScript('window.scrollBy(0, -120)');
      case 'scroll_left':
        _webController.runJavaScript('window.scrollBy(-80, 0)');
      case 'scroll_right':
        _webController.runJavaScript('window.scrollBy(80, 0)');
      case 'zoom_in':
        _pageZoom = (_pageZoom + 0.1).clamp(0.3, 3.0);
        _webController.runJavaScript(
          "document.documentElement.style.background='#000';"
          "document.body.style.background='#000';"
          "document.body.style.zoom='${_pageZoom.toStringAsFixed(2)}';",
        );
      case 'zoom_out':
        _pageZoom = (_pageZoom - 0.1).clamp(0.3, 3.0);
        _webController.runJavaScript(
          "document.documentElement.style.background='#000';"
          "document.body.style.background='#000';"
          "document.body.style.zoom='${_pageZoom.toStringAsFixed(2)}';",
        );
      case 'set_theme':
        final dark = cmd['dark'] as bool? ?? true;
        if (mounted) setState(() => _isDark = dark);
        if (_url.isNotEmpty) await _applyTheme(dark);
      case 'minimize':
        _exitFullscreen();
      case 'video_theater':
        _webController.runJavaScript('''
(function(){
  var v=document.querySelector('video');
  if(!v)return;
  // Force full-black background
  document.documentElement.style.cssText='background:#000!important;overflow:hidden!important';
  document.body.style.cssText='background:#000!important;overflow:hidden!important;margin:0!important;padding:0!important';
  // Pin video to fill entire viewport
  v.style.cssText='position:fixed!important;top:0!important;left:0!important;width:100vw!important;height:100vh!important;z-index:2147483647!important;background:#000!important;object-fit:contain!important';
  v.muted=false; v.volume=1;
  // Hide everything else in the body
  Array.from(document.body.children).forEach(function(el){
    if(!el.contains(v)&&el!==v){el.style.setProperty('display','none','important');}
  });
})()''');
      case 'cursor_move':
        final dx = (cmd['dx'] as num?)?.toDouble() ?? 0;
        final dy = (cmd['dy'] as num?)?.toDouble() ?? 0;
        if (mounted) {
          final size = MediaQuery.of(context).size;
          setState(() {
            _cursorX = (_cursorX + dx * 2.5).clamp(0, size.width);
            _cursorY = (_cursorY + dy * 2.5).clamp(0, size.height);
            _cursorVisible = true;
          });
          _resetCursorHideTimer();
          _syncCursor();
        }
      case 'cursor_click':
        final cx = _cursorX;
        final cy = _cursorY;
        // Use the same fullscreen detection as the double-tap exit handler:
        // document.fullscreenElement covers HTML5 fullscreen; the YouTube
        // aria-label check covers its custom player fullscreen mode.
        bool isFullscreen = false;
        try {
          final fsResult = await _webController.runJavaScriptReturningResult(r'''
(function(){
  if(document.fullscreenElement)return true;
  var fb=document.querySelector('.ytp-fullscreen-button');
  if(fb){var l=(fb.getAttribute('aria-label')||'').toLowerCase();if(l.includes('exit')||l.includes('minimize'))return true;}
  return false;
})()''');
          isFullscreen = fsResult == true || fsResult.toString() == 'true';
        } catch (_) {}
        bool nativeOk = false;
        try {
          nativeOk = await _methodChannel.invokeMethod<bool>('clickAt', {
                'x': cx,
                'y': cy,
                'fullscreen': isFullscreen,
              }) ??
              false;
        } catch (_) {}
        if (!nativeOk) {
          // JS fallback for when the WebView isn't found yet
          _webController.runJavaScript('''
(function(x,y){
  var el=document.elementFromPoint(x,y);
  if(!el)return;
  try{var id=Date.now();var tc=new Touch({identifier:id,target:el,clientX:x,clientY:y,pageX:x,pageY:y,screenX:x,screenY:y,radiusX:1,radiusY:1,rotationAngle:0,force:1});el.dispatchEvent(new TouchEvent('touchstart',{bubbles:true,cancelable:true,touches:[tc],changedTouches:[tc]}));el.dispatchEvent(new TouchEvent('touchend',{bubbles:true,cancelable:true,touches:[],changedTouches:[tc]}));}catch(e){}
  ['mouseover','mousedown','mouseup','click'].forEach(function(t){el.dispatchEvent(new MouseEvent(t,{bubbles:true,cancelable:true,view:window,clientX:x,clientY:y}));});
  if(el.tagName==='INPUT'||el.tagName==='TEXTAREA'||el.isContentEditable)el.focus();
  if(el.tagName==='IFRAME'){try{var r=el.getBoundingClientRect();var fx=x-r.left,fy=y-r.top;var fi=el.contentDocument&&el.contentDocument.elementFromPoint(fx,fy);if(fi){['mouseover','mousedown','mouseup','click'].forEach(function(t){fi.dispatchEvent(new MouseEvent(t,{bubbles:true,cancelable:true,view:el.contentWindow,clientX:fx,clientY:fy}));});if(fi.tagName==='INPUT'||fi.tagName==='TEXTAREA'||fi.isContentEditable)fi.focus();}}catch(e){}}
})(${cx.toStringAsFixed(1)},${cy.toStringAsFixed(1)})''');
        }
      case 'cursor_long_press':
        final cx = _cursorX.toInt();
        final cy = _cursorY.toInt();
        _webController.runJavaScript('''
(function(x,y){
  var el=document.elementFromPoint(x,y);
  if(!el)return;
  el.dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,cancelable:true,view:window,clientX:x,clientY:y}));
})($cx,$cy)''');
      case 'clear_session':
        _webController.clearCache();
        _webController.clearLocalStorage();
        WebViewCookieManager().clearCookies();
        _webController.runJavaScript(
            'try{localStorage.clear();sessionStorage.clear();}catch(e){}');
        if (mounted) {
          setState(() {
            _url = '';
            _title = 'ROKID BROWSER';
            _canGoBack = false;
            _cursorVisible = false;
            _cursorDragging = false;
          });
        }
        _webController.loadRequest(Uri.parse('about:blank'));
      case 'set_third_party_cookies':
        final block = cmd['block'] as bool? ?? false;
        try {
          await _methodChannel
              .invokeMethod('setThirdPartyCookies', {'block': block});
        } catch (_) {}
      case 'cursor_drag_start':
        if (mounted) {
          setState(() => _cursorDragging = true);
          _syncCursor();
        }
        _webController.runJavaScript('''
(function(x,y){
  window.__rokidDragId=Date.now()&0xFFFF;
  window.__rokidDragEl=document.elementFromPoint(x,y)||document.body;
  try{
    var tc=new Touch({identifier:window.__rokidDragId,target:window.__rokidDragEl,
      clientX:x,clientY:y,pageX:x+window.pageXOffset,pageY:y+window.pageYOffset,
      screenX:x,screenY:y,radiusX:1,radiusY:1,rotationAngle:0,force:1});
    window.__rokidDragEl.dispatchEvent(new TouchEvent('touchstart',
      {bubbles:true,cancelable:true,touches:[tc],targetTouches:[tc],changedTouches:[tc]}));
  }catch(e){}
})(${_cursorX.toInt()},${_cursorY.toInt()})''');
      case 'cursor_drag_move':
        final ddx = (cmd['dx'] as num?)?.toDouble() ?? 0;
        final ddy = (cmd['dy'] as num?)?.toDouble() ?? 0;
        if (mounted) {
          final size = MediaQuery.of(context).size;
          setState(() {
            _cursorX = (_cursorX + ddx * 2.5).clamp(0, size.width);
            _cursorY = (_cursorY + ddy * 2.5).clamp(0, size.height);
            _cursorVisible = true;
          });
          _resetCursorHideTimer();
          _syncCursor();
          // Scroll the page like a phone swipe (negate delta: drag up = scroll down)
          _webController.runJavaScript('''
(function(x,y,dx,dy){
  window.scrollBy(-dx*3,-dy*3);
  var el=window.__rokidDragEl||document.body;
  var id=window.__rokidDragId||1;
  try{
    var tc=new Touch({identifier:id,target:el,
      clientX:x,clientY:y,pageX:x+window.pageXOffset,pageY:y+window.pageYOffset,
      screenX:x,screenY:y,radiusX:1,radiusY:1,rotationAngle:0,force:1});
    document.dispatchEvent(new TouchEvent('touchmove',
      {bubbles:true,cancelable:true,touches:[tc],targetTouches:[tc],changedTouches:[tc]}));
  }catch(e){}
})(${_cursorX.toInt()},${_cursorY.toInt()},${ddx.toStringAsFixed(2)},${ddy.toStringAsFixed(2)})''');
        }
      case 'cursor_drag_end':
        if (mounted) {
          setState(() => _cursorDragging = false);
          _syncCursor();
        }
        _webController.runJavaScript('''
(function(x,y){
  var el=window.__rokidDragEl||document.body;
  var id=window.__rokidDragId||1;
  try{
    var tc=new Touch({identifier:id,target:el,
      clientX:x,clientY:y,pageX:x+window.pageXOffset,pageY:y+window.pageYOffset,
      screenX:x,screenY:y,radiusX:1,radiusY:1,rotationAngle:0,force:0});
    document.dispatchEvent(new TouchEvent('touchend',
      {bubbles:true,cancelable:true,touches:[],targetTouches:[],changedTouches:[tc]}));
  }catch(e){}
  window.__rokidDragEl=null;window.__rokidDragId=null;
})(${_cursorX.toInt()},${_cursorY.toInt()})''');
      case 'keyboard_type':
        final text = cmd['text'] as String? ?? '';
        if (text.isNotEmpty) {
          final encoded = jsonEncode(text);
          _webController.runJavaScript('''
(function(t){
  // Resolve the truly focused element, piercing shadow roots and iframes.
  // document.activeElement returns the shadow HOST when focus is inside a shadow root,
  // and the <iframe> element when focus is inside a frame — we must drill through both.
  function _deepActive(doc){
    var el=doc.activeElement;
    if(!el)return null;
    if(el.shadowRoot&&el.shadowRoot.activeElement)return _deepActive(el.shadowRoot);
    if(el.tagName==='IFRAME'){
      try{var id=el.contentDocument&&_deepActive(el.contentDocument);if(id)return id;}catch(e){}
    }
    return el;
  }
  var el=_deepActive(document);
  if(!el||(el.tagName!=='INPUT'&&el.tagName!=='TEXTAREA'&&!el.isContentEditable))return;
  el.focus();
  // execCommand('insertText') is the correct way to type into framework-controlled inputs
  // (React, Angular, Polymer) — it triggers their synthetic input events and works on
  // ALL input types including password fields (unlike setRangeText which throws for password).
  if(document.execCommand('insertText',false,t))return;
  // Fallback for browsers where execCommand is disabled: native value setter + input event.
  // The native setter bypasses React's overridden setter, then firing 'input' notifies React.
  try{
    if(el.isContentEditable){el.textContent+=t;}
    else{
      var proto=el.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;
      var setter=Object.getOwnPropertyDescriptor(proto,'value').set;
      setter.call(el,el.value+t);
    }
    el.dispatchEvent(new InputEvent('input',{bubbles:true,data:t,inputType:'insertText'}));
    el.dispatchEvent(new Event('change',{bubbles:true}));
  }catch(e){}
})($encoded)''');
        }
      case 'keyboard_backspace':
        _webController.runJavaScript('''
(function(){
  function _deepActive(doc){
    var el=doc.activeElement;
    if(!el)return null;
    if(el.shadowRoot&&el.shadowRoot.activeElement)return _deepActive(el.shadowRoot);
    if(el.tagName==='IFRAME'){try{var id=el.contentDocument&&_deepActive(el.contentDocument);if(id)return id;}catch(e){}}
    return el;
  }
  var el=_deepActive(document);
  if(!el||(el.tagName!=='INPUT'&&el.tagName!=='TEXTAREA'&&!el.isContentEditable))return;
  el.focus();
  if(document.execCommand('delete',false,null))return;
  try{
    if(el.isContentEditable){document.execCommand('delete',false,null);}
    else{var s=el.selectionStart;if(s>0){el.setRangeText('',s-1,s,'end');el.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'deleteContentBackward'}));}}
  }catch(e){}
})()''');
      case 'volume_up':
        _adjustMediaVolume(0.05);
      case 'volume_down':
        _adjustMediaVolume(-0.05);
      case 'wifi_enable':
        _methodChannel.invokeMethod('wifiEnable');
      case 'wifi_disable':
        _methodChannel.invokeMethod('wifiDisable');
      case 'exit_app':
        _methodChannel.invokeMethod('exitApp').catchError((_) {});
      case 'wifi_connect':
        _methodChannel.invokeMethod('wifiConnect', {
          'ssid': cmd['ssid'] as String? ?? '',
          'password': cmd['password'] as String? ?? '',
        });
    }
  }

  void _resetCursorHideTimer() {
    _cursorHideTimer?.cancel();
    _cursorHideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() => _cursorVisible = false);
        _syncCursor();
      }
    });
  }

  // Push cursor state to the native Android layer so it remains visible above
  // SurfaceView fullscreen video, which renders above Flutter's widget tree.
  void _syncCursor() {
    _methodChannel.invokeMethod('updateCursor', {
      'x': _cursorX,
      'y': _cursorY,
      'visible': _cursorVisible,
      'dragging': _cursorDragging,
    }).catchError((_) {});
  }

  // ── Passthrough / glasses gesture controls ───────────────────────────────

  /// Hardware key handler for Rokid touchpad gestures.
  /// Swipe forward (DPAD_RIGHT) → toggle passthrough.
  /// Swipe back  (DPAD_LEFT)  → reload page.
  /// Tap/centre                → pause/play media.
  /// Volume keys are intercepted natively in MainActivity and arrive here
  /// as browser_cmd events (volume_up / volume_down), not as hardware keys.
  bool _onHardwareKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    final k = event.logicalKey;

    if (k == LogicalKeyboardKey.arrowRight) {
      if (now - _lastGestureMs < _gestureDebounceMs) return true; // debounce
      _lastGestureMs = now;
      _togglePassthrough();
      return true;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      if (now - _lastGestureMs < _gestureDebounceMs) return true;
      _lastGestureMs = now;
      if (_url.isNotEmpty) _webController.reload();
      return true;
    }
    if (k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.mediaPlayPause ||
        k == LogicalKeyboardKey.space) {
      if (now - _lastCenterTapMs < _centerDoubleTapMs) {
        // Double-tap: cancel the deferred single-tap and run minimize-or-back
        _centerTapTimer?.cancel();
        _centerTapTimer = null;
        _lastCenterTapMs = 0;
        _handleCenterDoubleTap();
      } else {
        _lastCenterTapMs = now;
        _centerTapTimer?.cancel();
        _centerTapTimer = Timer(
          const Duration(milliseconds: _centerDoubleTapMs),
          () {
            _centerTapTimer = null;
            if (mounted) _toggleMediaPlayback();
          },
        );
      }
      return true;
    }
    return false;
  }

  void _bookmarkCurrent() {
    if (_url.isEmpty) return;
    _methodChannel.invokeMethod('bookmarkCurrent', {
      'url': _url,
      'title': _title,
    }).catchError((_) {});
  }

  void _togglePassthrough() {
    if (!mounted) return;
    setState(() => _passthrough = !_passthrough);
    // A Flutter overlay and a DOM div both fail when YouTube fullscreens a video —
    // Chrome renders the video on a hardware SurfaceView layer above both.
    // The only reliable fix is a native Android View added to the Activity's
    // DecorView (window root), which composites above the hardware video layer.
    _methodChannel.invokeMethod('setPassthrough', _passthrough).catchError((_) {});
  }

  void _toggleMediaPlayback() {
    _webController.runJavaScript('''
(function(){
  var v=document.querySelector('video');
  if(v){if(v.paused)v.play();else v.pause();return;}
  // Fallback: simulate space bar for sites with custom players
  ['keydown','keyup'].forEach(function(t){
    document.dispatchEvent(new KeyboardEvent(t,{key:' ',keyCode:32,code:'Space',bubbles:true,cancelable:true}));
  });
})();''');
  }

  Future<void> _handleCenterDoubleTap() async {
    final result = await _webController.runJavaScriptReturningResult(r'''
(function(){
  if(document.fullscreenElement){document.exitFullscreen();return true;}
  var fb=document.querySelector('.ytp-fullscreen-button');
  if(fb){var l=(fb.getAttribute('aria-label')||'').toLowerCase();if(l.includes('exit')||l.includes('minimize')){fb.click();return true;}}
  return false;
})()''');
    final inFullscreen = result == true || result.toString() == 'true';
    if (!inFullscreen && _canGoBack) _webController.goBack();
  }

  void _exitFullscreen() {
    _webController.runJavaScript(r'''
(function(){
  if(document.fullscreenElement){document.exitFullscreen();return;}
  var fb=document.querySelector('.ytp-fullscreen-button');
  if(fb){var l=(fb.getAttribute('aria-label')||'').toLowerCase();if(l.includes('exit')||l.includes('minimize')){fb.click();return;}}
  document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',keyCode:27,code:'Escape',bubbles:true,cancelable:true}));
})()''');
  }

  /// Fine-grained media volume control.
  /// Step size shrinks at low volumes so the user can reach near-silent
  /// levels without jumping straight to muted.
  void _adjustMediaVolume(double delta) {
    final dir = delta > 0 ? 1 : -1;
    _webController.runJavaScript('''
(function(dir){
  var changed=false;
  document.querySelectorAll('video,audio').forEach(function(m){
    // Adaptive step: 0.01 below 0.10, 0.03 below 0.30, 0.05 otherwise
    var step = m.volume < 0.10 ? 0.01 : m.volume < 0.30 ? 0.03 : 0.05;
    m.volume=Math.max(0,Math.min(1,m.volume+dir*step));
    changed=true;
  });
  if(!changed){
    var key=dir>0?'ArrowUp':'ArrowDown';
    ['keydown','keyup'].forEach(function(t){
      document.dispatchEvent(new KeyboardEvent(t,{key:key,code:key,bubbles:true,cancelable:true}));
    });
  }
})($dir)
''');
  }

  Future<void> _sendState({
    String? url,
    String? title,
    bool? loading,
    bool? canGoBack,
    bool? canGoForward,
  }) async {
    try {
      await _methodChannel.invokeMethod('sendBrowserState', {
        'url': url ?? _url,
        'title': title ?? _title,
        'loading': loading ?? _loading,
        'canGoBack': canGoBack ?? false,
        'canGoForward': canGoForward ?? false,
      });
    } on PlatformException catch (e) {
      debugPrint('sendState failed: ${e.message}');
    }
  }

  Widget _buildWebView() {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidWebViewWidget(
        AndroidWebViewWidgetCreationParams(
          controller: _webController.platform,
          displayWithHybridComposition: false,
        ),
      ).build(context);
    }
    return WebViewWidget(controller: _webController);
  }

  void _goBack() {
    if (_canGoBack) _webController.goBack();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_canGoBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _canGoBack) _webController.goBack();
      },
      // GestureDetector wraps the whole screen as a fallback swipe input.
      // translucent behaviour lets the WebView underneath still receive taps.
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragEnd: (details) {
          final v = details.primaryVelocity ?? 0;
          final now = DateTime.now().millisecondsSinceEpoch;
          if (now - _lastGestureMs < _gestureDebounceMs) return;
          _lastGestureMs = now;
          if (v > 400) {
            _togglePassthrough();
          } else if (v < -400) {
            if (_url.isNotEmpty) _webController.reload();
          }
        },
        child: Scaffold(
          backgroundColor: _kBlack,
          body: Stack(
            children: [
              if (_webViewReady && _url.isNotEmpty)
                // Virtual Display (TextureView) rendering — required for Rokid AR
                // waveguide. Default Hybrid Composition (SurfaceView) only composites
                // at the top-left corner on this display pipeline.
                _buildWebView()
              else
                _WaitingOverlay(btStatus: _btStatus, connected: _connected),

              // ── HUD (always on top, visible even in passthrough) ──────────
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _HudBar(
                  title: _title,
                  url: _url,
                  loading: _loading,
                  connected: _connected,
                  canGoBack: _canGoBack,
                  passthrough: _passthrough,
                  onBack: _goBack,
                  onBookmark: _url.isNotEmpty ? _bookmarkCurrent : null,
                ),
              ),
              // Cursor is rendered as a native Android View in the DecorView
              // (see updateCursor in MainActivity.kt) so it stays visible above
              // YouTube's SurfaceView fullscreen video layer.
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Waiting overlay ──────────────────────────────────────────────────────────

class _WaitingOverlay extends StatefulWidget {
  final String btStatus;
  final bool connected;
  const _WaitingOverlay({required this.btStatus, required this.connected});

  @override
  State<_WaitingOverlay> createState() => _WaitingOverlayState();
}

class _WaitingOverlayState extends State<_WaitingOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl =
        AnimationController(vsync: this, duration: const Duration(seconds: 2))
          ..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.3, end: 1.0)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FadeTransition(
            opacity: _anim,
            child: const Icon(Icons.language, color: _kGreen, size: 48),
          ),
          const SizedBox(height: 16),
          const Text(
            'ROKID BROWSER',
            style: TextStyle(
              color: _kGreen,
              fontSize: 14,
              fontWeight: FontWeight.bold,
              letterSpacing: 4,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            widget.connected
                ? 'CONNECTED — WAITING FOR URL'
                : widget.btStatus.toUpperCase(),
            style: TextStyle(
              color:
                  widget.connected ? _kSoftGreen : const Color(0xFFFF4444),
              fontSize: 9,
              letterSpacing: 2,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── AR HUD bar ───────────────────────────────────────────────────────────────

class _HudBar extends StatelessWidget {
  final String title;
  final String url;
  final bool loading;
  final bool connected;
  final bool canGoBack;
  final bool passthrough;
  final VoidCallback onBack;
  final VoidCallback? onBookmark;

  const _HudBar({
    required this.title,
    required this.url,
    required this.loading,
    required this.connected,
    required this.canGoBack,
    required this.passthrough,
    required this.onBack,
    this.onBookmark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _kBlack.withValues(alpha: 0.85),
      padding: const EdgeInsets.fromLTRB(6, 28, 10, 6),
      child: Row(
        children: [
          // Back button — always present, dims when unavailable
          GestureDetector(
            onTap: canGoBack ? onBack : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Icon(
                Icons.arrow_back_ios,
                color: canGoBack ? _kGreen : _kGreen.withValues(alpha: 0.25),
                size: 10,
              ),
            ),
          ),
          const SizedBox(width: 4),
          if (loading)
            const SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: _kGreen,
              ),
            )
          else
            const Icon(Icons.language, color: _kGreen, size: 10),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              url.isNotEmpty ? url : title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _kSoftGreen,
                fontSize: 9,
                letterSpacing: 0.3,
              ),
            ),
          ),
          if (url.isNotEmpty && onBookmark != null) ...[
            const SizedBox(width: 3),
            GestureDetector(
              onTap: onBookmark,
              child: Icon(
                Icons.bookmark_add_outlined,
                color: _kGreen.withValues(alpha: 0.75),
                size: 9,
              ),
            ),
          ],
          // Passthrough mode indicator
          if (passthrough) ...[
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(3),
              ),
              child: const Text(
                'PASS',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 7,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                ),
              ),
            ),
          ],
          const SizedBox(width: 6),
          Container(
            width: 4,
            height: 4,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: connected ? _kGreen : const Color(0xFFFF4444),
            ),
          ),
        ],
      ),
    );
  }
}
