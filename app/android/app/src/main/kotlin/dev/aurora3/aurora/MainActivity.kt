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

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
