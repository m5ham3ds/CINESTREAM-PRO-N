package com.m5ham3ds.cinestreampron.streaming

import android.annotation.SuppressLint
import android.content.Context
import android.net.Uri
import android.os.Build
import android.util.Log
import android.os.Handler
import android.os.Looper
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale

/**
 * Minimal native counterpart of OpenStream's off-screen WebEmbedResolver.
 * It never returns an HTML embed URL as a stream; only intercepted media and
 * subtitle resources leave the WebView. The bridge exposes no arbitrary Dart
 * callbacks to the page.
 */
class OpenStreamWebEmbedBridge(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())

    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        if (call.method != "resolveEmbed" && call.method != "resolveUrl" && call.method != "resolveCloudflare") return false
        val args = call.arguments as? Map<*, *> ?: run {
            result.error("bad_arguments", "Expected embed resolver arguments.", null)
            return true
        }
        val url = args["url"]?.toString().orEmpty()
        val uri = runCatching { Uri.parse(url) }.getOrNull()
        if (uri == null || (uri.scheme != "https" && uri.scheme != "http") || uri.host.isNullOrBlank() || !uri.userInfo.isNullOrEmpty()) {
            result.error("invalid_url", "Only valid HTTP(S) embed URLs are accepted.", null)
            return true
        }
        // Uri.host is nullable in Android's API. The URL was validated above,
        // so normalize it once to a non-null host for the resolver's String API.
        val host = uri.host.orEmpty()
        val referer = args["referer"]?.toString()?.takeIf {
            val ref = runCatching { Uri.parse(it) }.getOrNull()
            ref != null && (ref.scheme == "http" || ref.scheme == "https") &&
                !ref.host.isNullOrBlank() && ref.userInfo.isNullOrEmpty()
        } ?: "${uri.scheme}://$host/"
        val sourceName = args["sourceName"]?.toString()?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?.take(80) ?: host
        val timeout = (args["timeoutMs"] as? Number)?.toLong()?.coerceIn(4000L, 22000L) ?: 18000L
        if (call.method == "resolveCloudflare") {
            main.post { resolveCloudflare(url, timeout, result) }
        } else {
            main.post { resolve(url, referer, sourceName, timeout, result) }
        }
        return true
    }

    /**
     * Mirrors OpenStream's hidden-browser clearance flow for sites such as AnimePahe.
     * It only waits for the ordinary cf_clearance cookie; interactive Turnstile is
     * not automated and returns a clear timeout error.
     */
    @SuppressLint("SetJavaScriptEnabled")
    private fun resolveCloudflare(url: String, timeoutMs: Long, result: MethodChannel.Result) {
        val uri = Uri.parse(url)
        val origin = "${uri.scheme}://${uri.host}/"
        val cookieManager = CookieManager.getInstance()
        cookieManager.setAcceptCookie(true)
        // A stale clearance may still be present after Cloudflare starts
        // rejecting it. Remove only this host's cf_clearance cookie before
        // asking the hidden browser for a fresh one.
        cookieManager.setCookie(origin, "cf_clearance=; Max-Age=0; path=/")
        cookieManager.setCookie(origin, "cf_clearance=; Max-Age=0; path=/; domain=${uri.host}")
        cookieManager.flush()
        var completed = false
        lateinit var webView: WebView
        lateinit var poll: Runnable
        lateinit var timeout: Runnable

        fun cleanup() {
            main.removeCallbacks(poll)
            main.removeCallbacks(timeout)
            runCatching { webView.stopLoading() }
            runCatching { webView.loadUrl("about:blank") }
            runCatching { webView.webChromeClient = null }
            runCatching { webView.webViewClient = WebViewClient() }
            runCatching { webView.destroy() }
            cookieManager.flush()
        }

        fun finish(success: Boolean) {
            if (completed) return
            val cookies = cookieManager.getCookie(origin).orEmpty()
            if (success && !cookies.contains("cf_clearance=")) return
            completed = true
            val userAgent = runCatching { webView.settings.userAgentString }.getOrDefault(ANDROID_CHROME_USER_AGENT)
            cleanup()
            if (success) {
                result.success(mapOf("cookies" to cookies, "userAgent" to userAgent))
            } else {
                result.error(
                    "cloudflare_clearance_timeout",
                    "The automatic Cloudflare check did not issue cf_clearance. The site may require an interactive Turnstile check.",
                    mapOf("hasCookie" to cookies.contains("cf_clearance=")),
                )
            }
        }

        webView = WebView(context).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.databaseEnabled = false
            settings.allowFileAccess = false
            settings.allowContentAccess = false
            settings.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            settings.javaScriptCanOpenWindowsAutomatically = false
            settings.setSupportMultipleWindows(false)
            settings.cacheMode = WebSettings.LOAD_NO_CACHE
            settings.userAgentString = ANDROID_CHROME_USER_AGENT
            cookieManager.setAcceptThirdPartyCookies(this, true)
            webChromeClient = WebChromeClient()
            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
                    val target = request?.url ?: return true
                    return target.scheme != "https" && target.scheme != "http"
                }

                override fun onPageFinished(view: WebView?, finishedUrl: String?) {
                    super.onPageFinished(view, finishedUrl)
                    if (cookieManager.getCookie(origin).orEmpty().contains("cf_clearance=")) {
                        finish(true)
                    }
                }
            }
        }

        poll = object : Runnable {
            override fun run() {
                if (completed) return
                if (cookieManager.getCookie(origin).orEmpty().contains("cf_clearance=")) {
                    finish(true)
                } else {
                    main.postDelayed(this, 500L)
                }
            }
        }
        timeout = Runnable { finish(false) }
        main.postDelayed(poll, 500L)
        main.postDelayed(timeout, timeoutMs)
        webView.loadUrl(origin)
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun resolve(url: String, referer: String, sourceName: String, timeoutMs: Long, result: MethodChannel.Result) {
        val streams = linkedMapOf<String, CapturedResource>()
        val subtitles = linkedMapOf<String, CapturedResource>()
        var completed = false
        var settle: Runnable? = null
        var timeoutRunnable: Runnable? = null
        lateinit var webView: WebView

        fun cleanup() {
            settle?.let(main::removeCallbacks)
            timeoutRunnable?.let(main::removeCallbacks)
            runCatching { webView.stopLoading() }
            runCatching { webView.loadUrl("about:blank") }
            runCatching { webView.removeJavascriptInterface(BRIDGE_NAME) }
            runCatching { webView.webChromeClient = null }
            runCatching { webView.webViewClient = WebViewClient() }
            runCatching { webView.destroy() }
        }

        fun finish() {
            if (completed) return
            completed = true
            cleanup()
            val response = streams.values.map { it.toMap(subtitles.values.toList()) }
            if (response.isEmpty()) {
                val host = runCatching { Uri.parse(url).host }.getOrNull().orEmpty()
                Log.w(TAG, "$sourceName exposed no playable media URL (host=$host, subtitles=${subtitles.size})")
                result.error(
                    "no_media_found",
                    "$sourceName loaded but exposed no playable media URL. Check host availability, player initialization, or an interactive challenge.",
                    mapOf("host" to host, "capturedMedia" to 0, "capturedSubtitles" to subtitles.size),
                )
            } else {
                Log.i(TAG, "$sourceName exposed ${response.size} playable media URL(s)")
                result.success(response)
            }
        }

        fun settleAfterCapture() {
            settle?.let(main::removeCallbacks)
            settle = Runnable { finish() }.also { main.postDelayed(it, SETTLE_MS) }
        }

        fun capture(resourceUrl: String, quality: String?, headers: Map<String, String> = emptyMap()) {
            if (completed || !isMediaUrl(resourceUrl)) return
            val normalized = safeHttpUrl(resourceUrl) ?: return
            val passthrough = headers.filterKeys {
                it.equals("Referer", true) || it.equals("Origin", true) || it.equals("User-Agent", true) || it.equals("Cookie", true)
            }
            val merged = linkedMapOf<String, String>()
            merged["User-Agent"] = BROWSER_USER_AGENT
            if (!referer.isNullOrBlank()) {
                merged["Referer"] = referer
                runCatching { Uri.parse(referer).let { if (it.host != null) merged["Origin"] = it.scheme + "://" + it.host } }
            }
            merged.putAll(passthrough)
            runCatching { CookieManager.getInstance().getCookie(normalized)?.takeIf { it.isNotBlank() }?.let { merged.putIfAbsent("Cookie", it) } }
            streams[normalized] = CapturedResource(normalized, quality ?: inferQuality(normalized), merged)
            settleAfterCapture()
        }

        fun captureSubtitle(resourceUrl: String, label: String? = null, headers: Map<String, String> = emptyMap()) {
            if (completed || !isSubtitleUrl(resourceUrl)) return
            val normalized = safeHttpUrl(resourceUrl) ?: return
            val merged = linkedMapOf<String, String>()
            merged["User-Agent"] = BROWSER_USER_AGENT
            if (!referer.isNullOrBlank()) {
                merged["Referer"] = referer
                runCatching { Uri.parse(referer).let { if (it.host != null) merged["Origin"] = it.scheme + "://" + it.host } }
            }
            merged.putAll(headers)
            runCatching { CookieManager.getInstance().getCookie(normalized)?.takeIf { it.isNotBlank() }?.let { merged.putIfAbsent("Cookie", it) } }
            subtitles[normalized] = CapturedResource(normalized, label ?: "Subtitle", merged)
        }

        fun parseMetadataValue(value: Any?, inheritedQuality: String? = null, inheritedHeaders: Map<String, String> = emptyMap()) {
            if (completed) return
            when (value) {
                is JSONObject -> {
                    val quality = value.optString("quality").takeIf { it.isNotBlank() }
                        ?: value.optString("label").takeIf { it.isNotBlank() }
                        ?: inheritedQuality
                    val headers = linkedMapOf<String, String>().apply {
                        putAll(inheritedHeaders)
                        val nested = value.optJSONObject("headers")
                        if (nested != null) {
                            val iterator = nested.keys()
                            while (iterator.hasNext()) {
                                val key = iterator.next()
                                val headerValue = nested.optString(key)
                                if (headerValue.isNotBlank()) put(key, headerValue)
                            }
                        }
                    }
                    listOf("url", "file", "src", "link", "stream").forEach { key ->
                        val candidate = value.optString(key).trim()
                        if (candidate.isNotEmpty() && candidate != "null") {
                            when {
                                isMediaUrl(candidate) -> capture(candidate, quality, headers)
                                isSubtitleUrl(candidate) -> captureSubtitle(candidate, quality, headers)
                            }
                        }
                    }
                    val keys = value.keys()
                    while (keys.hasNext() && !completed) {
                        val key = keys.next()
                        val child = value.opt(key)
                        if (child is JSONObject || child is JSONArray) {
                            parseMetadataValue(child, quality, headers)
                        } else if (child is String && (child.trimStart().startsWith("{") || child.trimStart().startsWith("["))) {
                            val nestedText = child.trim()
                            if (nestedText.length <= MAX_METADATA_BYTES) {
                                runCatching {
                                    val nested: Any = if (nestedText.startsWith("[")) JSONArray(nestedText) else JSONObject(nestedText)
                                    parseMetadataValue(nested, quality, headers)
                                }
                            }
                        }
                    }
                }
                is JSONArray -> {
                    for (index in 0 until value.length()) {
                        if (completed) break
                        parseMetadataValue(value.opt(index), inheritedQuality, inheritedHeaders)
                    }
                }
                is String -> {
                    when {
                        isMediaUrl(value) -> capture(value, inheritedQuality, inheritedHeaders)
                        isSubtitleUrl(value) -> captureSubtitle(value, inheritedQuality, inheritedHeaders)
                    }
                }
            }
        }

        fun parseMetadataPayload(payload: String, quality: String? = null, headers: Map<String, String> = emptyMap()) {
            val text = payload.trim()
            if (text.isEmpty() || text.length > MAX_METADATA_BYTES) return
            runCatching {
                val root: Any = if (text.startsWith("[")) JSONArray(text) else JSONObject(text)
                parseMetadataValue(root, quality, headers)
            }
        }

        webView = WebView(context).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.databaseEnabled = false
            settings.allowFileAccess = false
            settings.allowContentAccess = false
            settings.mediaPlaybackRequiresUserGesture = false
            // OpenStream permits mixed HTTP media inside its isolated player WebView;
            // some embedded hosts still serve their manifest/segments over HTTP.
            settings.mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
            settings.javaScriptCanOpenWindowsAutomatically = false
            settings.setSupportMultipleWindows(false)
            settings.cacheMode = WebSettings.LOAD_NO_CACHE
            settings.userAgentString = BROWSER_USER_AGENT
            CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
            addJavascriptInterface(object {
                @JavascriptInterface
                fun captureStream(resourceUrl: String, quality: String?) {
                    main.post { capture(resourceUrl, quality) }
                }
                @JavascriptInterface
                fun captureSubtitle(resourceUrl: String, label: String?) {
                    main.post { captureSubtitle(resourceUrl, label) }
                }
                @JavascriptInterface
                fun captureMetadata(payload: String) {
                    main.post { parseMetadataPayload(payload) }
                }
            }, BRIDGE_NAME)
            webChromeClient = WebChromeClient()
            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
                    val target = request?.url ?: return true
                    if (target.scheme != "https" && target.scheme != "http") return true
                    // Mirror OpenStream: subframes and HTTP redirects stay in
                    // the player, while unrelated top-level ad navigation is blocked.
                    if (request.isForMainFrame) {
                        // WebResourceRequest.isRedirect is only available from API 24.
                        // Keep redirects in the resolver while guarding older Android.
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && request.isRedirect) {
                            return false
                        }
                        return !sharesRootWith(target.host.orEmpty(), Uri.parse(url).host.orEmpty())
                    }
                    return false
                }

                override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest?): android.webkit.WebResourceResponse? {
                    val requestUrl = request?.url?.toString().orEmpty()
                    val headers = request?.requestHeaders.orEmpty()
                    if (isMediaUrl(requestUrl)) {
                        main.post { capture(requestUrl, inferQuality(requestUrl), headers) }
                    } else if (isSubtitleUrl(requestUrl)) {
                        main.post { captureSubtitle(requestUrl, null, headers) }
                    }
                    return super.shouldInterceptRequest(view, request)
                }

                override fun onPageFinished(view: WebView?, finishedUrl: String?) {
                    super.onPageFinished(view, finishedUrl)
                    view?.evaluateJavascript(INJECT_CAPTURE_SCRIPT, null)
                }
            }
        }

        val timeout = Runnable { finish() }
        timeoutRunnable = timeout
        main.postDelayed(timeout, timeoutMs)
        // Keep timeout active even when there are no matching network resources.
        webView.loadUrl(url, if (referer.isNullOrBlank()) emptyMap() else mapOf("Referer" to referer))
        // The callback is removed in finish(), and the WebView is always destroyed.
    }

    private data class CapturedResource(
        val url: String,
        val quality: String?,
        val headers: Map<String, String>
    ) {
        fun toMap(subtitles: List<CapturedResource>): Map<String, Any?> = mapOf(
            "url" to url,
            "quality" to quality,
            "headers" to headers,
            "subtitles" to subtitles.map { subtitle ->
                mapOf(
                    "url" to subtitle.url,
                    "label" to subtitle.quality,
                    "language" to languageGuess(subtitle.quality),
                    "headers" to subtitle.headers,
                    "format" to subtitle.url.substringAfterLast('.', "").substringBefore('?')
                )
            }
        )

        // CapturedResource is a nested data class and has no reference to the
        // outer bridge instance, so this helper belongs in its own scope.
        private fun languageGuess(label: String?): String =
            label?.takeIf { it.length in 2..5 } ?: "und"
    }


    private fun sharesRootWith(first: String, second: String): Boolean {
        fun root(host: String): String = host.lowercase(Locale.ROOT).split('.').takeLast(2).joinToString(".")
        return root(first) == root(second)
    }

    private fun safeHttpUrl(value: String): String? = runCatching {
        val uri = Uri.parse(value)
        if ((uri.scheme == "https" || uri.scheme == "http") && !uri.host.isNullOrBlank() && uri.userInfo.isNullOrEmpty()) uri.toString() else null
    }.getOrNull()

    private fun isMediaUrl(value: String): Boolean {
        val lower = value.lowercase(Locale.ROOT).substringBefore('#')
        if (BLOCKED_MEDIA_MARKERS.any(lower::contains)) return false
        return lower.substringBefore('?').let { path ->
            path.endsWith(".m3u8") || path.endsWith(".mp4") || path.endsWith(".mpd") ||
                path.endsWith(".webm") || path.endsWith(".m4v") ||
                path.contains("/manifest") || path.contains("/playlist")
        }
    }

    private fun isSubtitleUrl(value: String): Boolean {
        val path = value.lowercase(Locale.ROOT).substringBefore('?').substringBefore('#')
        return path.endsWith(".vtt") || path.endsWith(".srt") || path.endsWith(".ass") || path.endsWith(".ssa")
    }

    private fun inferQuality(url: String): String? {
        val match = Regex("(?:^|[^0-9])(2160|1440|1080|720|576|480|360)p?(?:[^0-9]|$)", RegexOption.IGNORE_CASE).find(url)
        return match?.groupValues?.get(1)?.plus("p")
    }

    private companion object {
        const val TAG = "OpenStreamWebEmbedBridge"
        const val BRIDGE_NAME = "FlixQuestSniffer"
        const val SETTLE_MS = 1500L
        const val MAX_METADATA_BYTES = 4 * 1024 * 1024
        val BLOCKED_MEDIA_MARKERS = listOf("googleads", "doubleclick", "telemetry", "/ads/", "vast")
        const val BROWSER_USER_AGENT = "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36"
        const val ANDROID_CHROME_USER_AGENT = "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
        const val INJECT_CAPTURE_SCRIPT = """
(function(){
  if (window.__flixQuestCaptureInstalled) return;
  window.__flixQuestCaptureInstalled = true;
  var bridge = window.FlixQuestSniffer;
  function reportUrl(u) {
    try {
      if (!u || !bridge) return;
      var value = String(u);
      if (/\.(m3u8|mp4|mpd|webm|m4v)(?:[?#]|$)|\/(manifest|playlist)(?:[?#]|$)/i.test(value)) bridge.captureStream(value, null);
      else if (/\.(vtt|srt|ass|ssa)(?:[?#]|$)/i.test(value)) bridge.captureSubtitle(value, null);
    } catch(e) {}
  }
  function reportMetadata(text) {
    try {
      if (bridge && typeof text === 'string' && text.length > 0 && text.length <= 4194304) bridge.captureMetadata(text);
    } catch(e) {}
  }
  var oldFetch = window.fetch;
  if (oldFetch) window.fetch = function(){
    var p = oldFetch.apply(this, arguments);
    return p.then(function(r){
      try { reportUrl(r.url); } catch(e) {}
      try { r.clone().text().then(reportMetadata).catch(function(){}); } catch(e) {}
      return r;
    });
  };
  var oldOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function(method, url){ this.__fqUrl = url; return oldOpen.apply(this, arguments); };
  var oldSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send = function(){
    this.addEventListener('load', function(){
      try { reportUrl(this.responseURL || this.__fqUrl); } catch(e) {}
      try { if (typeof this.responseText === 'string') reportMetadata(this.responseText); } catch(e) {}
      try {
        if (typeof this.responseText === 'string') {
          var matches = this.responseText.match(/https?:\/\/[^\s"'<>]+\.(?:m3u8|mp4|mpd|vtt)(?:\?[^\s"'<>]*)?/ig) || [];
          matches.forEach(reportUrl);
        }
      } catch(e) {}
    });
    return oldSend.apply(this, arguments);
  };
  try { performance.getEntriesByType('resource').forEach(function(e){ reportUrl(e.name); }); } catch(e) {}
  try { window.open = function(){ return null; }; } catch(e) {}
  var attempts = 0;
  var nudge = setInterval(function(){
    attempts++;
    try {
      document.querySelectorAll('video').forEach(function(video){
        video.muted = true;
        var played = video.play();
        if (played && played.catch) played.catch(function(){});
      });
      var selectors = '.vjs-big-play-button, .jw-display-icon-container, .plyr__control--overlaid, #play, .play-button, .play-btn, [aria-label="Play"], button[class*="play"]';
      var button = document.querySelector(selectors);
      if (button) button.click();
    } catch(e) {}
    if (attempts >= 8) clearInterval(nudge);
  }, 1200);
})();
"""
    }
}
