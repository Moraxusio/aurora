package dev.aurora3.aurora

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import android.content.ClipboardManager
import android.content.Context
import android.provider.OpenableColumns
import java.net.URI
import java.net.Proxy
import java.net.ProxySelector
import java.net.InetSocketAddress
import java.util.concurrent.Executors
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {
    private val inputExecutor = Executors.newSingleThreadExecutor()
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aurora3/input")
            .setMethodCallHandler { call, result ->
                if (call.method == "authProxy") {
                    val proxy = ProxySelector.getDefault()?.select(URI("https://auth.openai.com"))?.firstOrNull { it.type() == Proxy.Type.HTTP }
                    val address = proxy?.address() as? InetSocketAddress
                    result.success(if (address == null) "DIRECT" else "PROXY ${address.hostString}:${address.port}")
                } else if (call.method == "readClipboard" || call.method == "readContentUri") {
                    // Read clipboard only on an explicit paste action while the app is foreground.
                    val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    val clip = if (call.method == "readClipboard") clipboard.primaryClip else null
                    val uriArg = call.argument<String>("uri")
                    val uris = if (uriArg != null) listOf(android.net.Uri.parse(uriArg)) else
                        (0 until (clip?.itemCount ?: 0)).mapNotNull { clip?.getItemAt(it)?.uri }
                    inputExecutor.execute {
                        try {
                            if (uris.size > 8) throw IllegalArgumentException("每次最多粘贴 8 个文件")
                            var totalBytes = 0
                            val files = uris.map { uri ->
                                if (uri.scheme != "content") throw IllegalArgumentException("仅支持系统授权的 content URI")
                                var name = "attachment"
                                contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                                    if (cursor.moveToFirst()) name = cursor.getString(0) ?: name
                                }
                                // Check metadata before opening the stream, just like the Dart
                                // local/remote file paths. Never read a known credential file.
                                val basename = name.replace('\\', '/').substringAfterLast('/')
                                if (Regex("(^id_(rsa|ed25519|ecdsa)$|\\.(key|pem|p12|pfx|jks)$|^profile\\.bin$)", RegexOption.IGNORE_CASE).containsMatchIn(basename)) {
                                    throw IllegalArgumentException("为避免泄露凭据，不支持直接附加私钥、密钥库或加密配置文件")
                                }
                                val bytes = contentResolver.openInputStream(uri)?.use { input ->
                                    val out = ByteArrayOutputStream()
                                    val buffer = ByteArray(65536)
                                    while (true) {
                                        val n = input.read(buffer)
                                        if (n < 0) break
                                         if (out.size() + n > 8 * 1024 * 1024) throw IllegalArgumentException("附件过大")
                                         if (totalBytes + out.size() + n > 20 * 1024 * 1024) throw IllegalArgumentException("附件总大小不能超过 20 MiB")
                                        out.write(buffer, 0, n)
                                    }
                                    out.toByteArray()
                                }
                                    ?: throw IllegalArgumentException("无法读取粘贴内容")
                                if (bytes.size > 8 * 1024 * 1024) throw IllegalArgumentException("单个附件不能超过 8 MiB")
                                totalBytes += bytes.size
                                mapOf("name" to name, "bytes" to bytes)
                            }
                            runOnUiThread { result.success(mapOf("files" to files)) }
                        } catch (_: Exception) { runOnUiThread { result.error("input", "无法读取粘贴附件；请确认文件授权、格式及大小", null) } }
                    }
                } else result.notImplemented()
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.aurora3/keystore")
            .setMethodCallHandler { call, result ->
                if (call.method != "init") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    result.success(mapOf("key" to dataKey(), "dir" to filesDir.absolutePath))
                } catch (e: Exception) {
                    result.error("keystore", e.message ?: e.javaClass.simpleName, null)
                }
            }
    }

    override fun onDestroy() {
        inputExecutor.shutdown()
        super.onDestroy()
    }

    private fun wrapKey(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return gen.generateKey()
    }

    // The 32-byte data key is random, kept on disk only wrapped by the
    // non-exportable Keystore key. A file that cannot be unwrapped is an error:
    // it is never replaced, so a sealed profile is never silently orphaned.
    private fun dataKey(): ByteArray {
        val f = File(filesDir, "profile.key")
        val wk = wrapKey()
        if (f.exists()) {
            val raw = f.readBytes()
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, wk, GCMParameterSpec(128, raw.copyOfRange(0, 12)))
            return c.doFinal(raw, 12, raw.size - 12)
        }
        val key = ByteArray(32).also { SecureRandom().nextBytes(it) }
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, wk)
        val out = c.iv + c.doFinal(key)
        val tmp = File(filesDir, "profile.key.tmp")
        tmp.writeBytes(out)
        if (!tmp.renameTo(f)) throw IllegalStateException("cannot write key file")
        return key
    }

    companion object {
        private const val ALIAS = "aurora3-profile-wrap"
    }
}
