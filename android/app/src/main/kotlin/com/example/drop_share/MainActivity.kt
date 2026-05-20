package com.example.drop_share

import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "drop_share/sharing"
    private var methodChannel: MethodChannel? = null
    private var pendingFiles: List<String> = emptyList()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, channelName
        )
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialSharedFiles" -> {
                    result.success(pendingFiles)
                    pendingFiles = emptyList()
                }
                else -> result.notImplemented()
            }
        }
        // Intent that cold-started the app
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
        val files = pendingFiles
        if (files.isNotEmpty()) {
            pendingFiles = emptyList()
            methodChannel?.invokeMethod("onSharedFiles", files)
        }
    }

    private fun handleIntent(intent: Intent?) {
        intent ?: return
        when (intent.action) {
            Intent.ACTION_SEND -> {
                @Suppress("DEPRECATION")
                val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                    ?: return
                val path = copyToCache(uri) ?: return
                pendingFiles = listOf(path)
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                @Suppress("DEPRECATION")
                val uris =
                    intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                        ?: return
                pendingFiles = uris.mapNotNull { copyToCache(it) }
            }
        }
    }

    private fun copyToCache(uri: Uri): String? {
        return try {
            val inputStream = contentResolver.openInputStream(uri) ?: return null
            val name = resolveFileName(uri)
                ?: "shared_${System.currentTimeMillis()}"
            val dest = File(cacheDir, name)
            dest.outputStream().use { out -> inputStream.copyTo(out) }
            dest.absolutePath
        } catch (e: Exception) {
            null
        }
    }

    private fun resolveFileName(uri: Uri): String? {
        contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (cursor.moveToFirst() && idx >= 0) return cursor.getString(idx)
        }
        return uri.lastPathSegment
    }
}
