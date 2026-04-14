package com.example.pdf_viewer

import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val methodChannelName = "pdf_viewer/external_share"
    private val eventChannelName = "pdf_viewer/external_share/events"

    private var initialPayload: Map<String, Any?>? = null
    private var eventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        initialPayload = buildPayload(intent)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            methodChannelName
        ).setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
            when (call.method) {
                "getInitialSharedPayload" -> {
                    result.success(initialPayload ?: emptyMap<String, Any?>())
                }

                "clearInitialSharedPayload" -> {
                    initialPayload = null
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            eventChannelName
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)

        val payload = buildPayload(intent)
        initialPayload = payload
        if (payload != null) {
            eventSink?.success(payload)
        }
    }

    private fun buildPayload(intent: Intent?): Map<String, Any?>? {
        if (intent == null) return null

        val action = intent.action ?: return null
        val rawItems = linkedSetOf<String>()
        var hasUnsupportedPayload = false

        when (action) {
            Intent.ACTION_SEND -> {
                collectUri(intent.getParcelableExtra(Intent.EXTRA_STREAM), intent.flags, rawItems)
                collectText(intent.getCharSequenceExtra(Intent.EXTRA_TEXT), rawItems)
                collectClipData(intent.clipData, intent.flags, rawItems)
                if (rawItems.isEmpty()) {
                    hasUnsupportedPayload = intent.hasExtra(Intent.EXTRA_STREAM) ||
                        intent.hasExtra(Intent.EXTRA_TEXT) ||
                        intent.clipData != null
                }
            }

            Intent.ACTION_SEND_MULTIPLE -> {
                val items = intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                items?.forEach { collectUri(it, intent.flags, rawItems) }
                collectText(intent.getCharSequenceExtra(Intent.EXTRA_TEXT), rawItems)
                collectClipData(intent.clipData, intent.flags, rawItems)
                if (rawItems.isEmpty()) {
                    hasUnsupportedPayload = true
                }
            }

            Intent.ACTION_VIEW -> {
                collectUri(intent.data, intent.flags, rawItems)
                collectText(intent.dataString, rawItems)
                if (rawItems.isEmpty() && intent.data != null) {
                    hasUnsupportedPayload = true
                }
            }

            else -> return null
        }

        if (rawItems.isEmpty() && !hasUnsupportedPayload) {
            return null
        }

        return mapOf(
            "rawItems" to rawItems.toList(),
            "hasUnsupportedPayload" to hasUnsupportedPayload,
            "action" to action,
            "mimeType" to intent.type
        )
    }

    private fun collectUri(uri: Uri?, flags: Int, out: MutableSet<String>) {
        if (uri == null) return
        maybePersistUriPermission(uri, flags)
        out.add(uri.toString())
    }

    private fun collectText(text: CharSequence?, out: MutableSet<String>) {
        val value = text?.toString()?.trim().orEmpty()
        if (value.isNotEmpty()) {
            out.add(value)
        }
    }

    private fun collectClipData(
        clipData: android.content.ClipData?,
        flags: Int,
        out: MutableSet<String>
    ) {
        if (clipData == null) return
        for (index in 0 until clipData.itemCount) {
            val item = clipData.getItemAt(index)
            collectUri(item.uri, flags, out)
            collectText(item.text, out)
            collectText(item.htmlText, out)
        }
    }

    private fun maybePersistUriPermission(uri: Uri, flags: Int) {
        val persistableFlags = flags and
            (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        if (persistableFlags == 0) return

        try {
            contentResolver.takePersistableUriPermission(uri, persistableFlags)
        } catch (_: SecurityException) {
            // Share intents often provide only transient grants.
        } catch (_: UnsupportedOperationException) {
            // Some providers do not support persistable permissions.
        }
    }
}
