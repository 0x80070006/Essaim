package dev.essaim.essaim

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.app.FlutterApplication
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.io.File

class EssaimApp : FlutterApplication() {
    private val url = android.util.Base64.URL_SAFE or android.util.Base64.NO_WRAP

    private fun keystoreKey(): javax.crypto.SecretKey {
        val store = java.security.KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey("essaim", null) as javax.crypto.SecretKey?)?.let { return it }
        val generator = javax.crypto.KeyGenerator.getInstance("AES", "AndroidKeyStore")
        generator.init(android.security.keystore.KeyGenParameterSpec.Builder("essaim",
            android.security.keystore.KeyProperties.PURPOSE_ENCRYPT or android.security.keystore.KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes("GCM").setEncryptionPaddings("NoPadding").setKeySize(256).build())
        return generator.generateKey()
    }

    private fun seal(value: String): String {
        val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(javax.crypto.Cipher.ENCRYPT_MODE, keystoreKey())
        return android.util.Base64.encodeToString(cipher.iv + cipher.doFinal(android.util.Base64.decode(value, url)), url)
    }

    private fun unseal(value: String): String {
        val raw = android.util.Base64.decode(value, url)
        val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(javax.crypto.Cipher.DECRYPT_MODE, keystoreKey(), javax.crypto.spec.GCMParameterSpec(128, raw, 0, 12))
        return android.util.Base64.encodeToString(cipher.doFinal(raw, 12, raw.size - 12), url)
    }
    companion object { const val ENGINE_ID = "main" }

    override fun onCreate() {
        super.onCreate()
        val engine = FlutterEngine(this)
        MethodChannel(engine.dartExecutor.binaryMessenger, "essaim/native").setMethodCallHandler { call, result ->
            when (call.method) {
                "seal" -> result.success(seal(call.argument<String>("value")!!))
                "unseal" -> result.success(unseal(call.argument<String>("value")!!))
                "deviceName" -> result.success(Build.MODEL)
                "hasAllFiles" -> result.success(Environment.isExternalStorageManager())
                "requestAllFiles" -> {
                    startActivity(Intent(
                        Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                        Uri.parse("package:$packageName"),
                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                }
                "startService" -> {
                    startForegroundService(Intent(this, EssaimService::class.java))
                    result.success(null)
                }
                "openFile" -> {
                    val file = File(call.argument<String>("path")!!)
                    val uri = FileProvider.getUriForFile(this, "$packageName.files", file)
                    val mime = if (file.extension.equals("apk", true)) "application/vnd.android.package-archive"
                    else MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase()) ?: "*/*"
                    try {
                        startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION))
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("open", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
    }
}
