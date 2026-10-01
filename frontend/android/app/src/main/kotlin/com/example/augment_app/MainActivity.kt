package com.example.augment_app

import android.Manifest
import android.content.ContentValues
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

class MainActivity : FlutterActivity(), MethodChannel.MethodCallHandler {
    companion object {
        private const val CHANNEL = "augment/voice_range"
        private const val RECORD_AUDIO_REQUEST = 812
        private const val SAMPLE_RATE = 44100
    }

    private var channel: MethodChannel? = null
    private var audioRecord: AudioRecord? = null
    private var recordingThread: Thread? = null
    private var recording = false
    private var pcmData = ByteArrayOutputStream()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler(this)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "augment/downloads").setMethodCallHandler { call, result ->
            if (call.method != "savePdf") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val name = call.argument<String>("name")
            val bytes = call.argument<ByteArray>("bytes")
            if (name.isNullOrBlank() || bytes == null) {
                result.error("INVALID_ARGS", "Missing PDF name or data", null)
                return@setMethodCallHandler
            }
            try {
                result.success(savePdfToDownloads(name, bytes))
            } catch (error: Exception) {
                result.error("DOWNLOAD_FAILED", error.message, null)
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "augment/aba_share").setMethodCallHandler { call, result ->
            when (call.method) {
                "shareToAba" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    if (bytes == null) {
                        result.error("INVALID_ARGS", "Missing bytes", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val file = File(cacheDir, "khqr_aba_payment.png")
                        FileOutputStream(file).use { it.write(bytes) }
                        val uri = androidx.core.content.FileProvider.getUriForFile(
                            this,
                            "${applicationContext.packageName}.fileprovider",
                            file
                        )
                        val intent = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                            type = "image/png"
                            putExtra(android.content.Intent.EXTRA_STREAM, uri)
                            addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            setPackage("com.paygo24.ibank")
                        }
                        val resolved = packageManager.queryIntentActivities(intent, 0)
                        if (resolved.isNotEmpty()) {
                            startActivity(intent)
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    } catch (e: Exception) {
                        result.error("ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> startRecording(result)
            "stop" -> stopRecording(result)
            else -> result.notImplemented()
        }
    }

    private fun savePdfToDownloads(rawName: String, bytes: ByteArray): String {
        val safeName = rawName.replace(Regex("[\\\\/:*?\"<>|\\p{Cntrl}]"), "_")
            .let { if (it.endsWith(".pdf", ignoreCase = true)) it else "$it.pdf" }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            throw IllegalStateException("Your Android version cannot save directly to Downloads.")
        }
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, safeName)
            put(MediaStore.Downloads.MIME_TYPE, "application/pdf")
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("Downloads folder is unavailable.")
        try {
            contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                ?: throw IllegalStateException("Could not open the Downloads file.")
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
            return "Downloads/$safeName"
        } catch (error: Exception) {
            contentResolver.delete(uri, null, null)
            throw error
        }
    }

    private fun detectFrequency(samples: ShortArray, length: Int): Double? {
        // Downsample and use YIN's cumulative mean normalized difference. It
        // handles harmonic-rich instruments more reliably than choosing the
        // largest raw autocorrelation peak.
        val size = length / 2
        if (size < 1024) return null
        val values = DoubleArray(size)
        var mean = 0.0
        for (index in 0 until size) {
            mean += samples[index * 2].toDouble() / 32768.0
        }
        mean /= size
        var energy = 0.0
        for (index in 0 until size) {
            val value = samples[index * 2].toDouble() / 32768.0 - mean
            values[index] = value
            energy += value * value
        }
        if (energy / size < 0.000015) return null
        val effectiveRate = SAMPLE_RATE / 2.0
        val minLag = maxOf(2, (effectiveRate / 2200.0).toInt())
        val maxLag = minOf(size / 2, (effectiveRate / 35.0).toInt())
        val difference = DoubleArray(maxLag + 1)
        val normalized = DoubleArray(maxLag + 1) { 1.0 }
        var runningTotal = 0.0
        for (lag in 1..maxLag) {
            var sum = 0.0
            for (index in 0 until size - lag) {
                val delta = values[index] - values[index + lag]
                sum += delta * delta
            }
            difference[lag] = sum
            runningTotal += sum
            normalized[lag] = if (runningTotal > 0.0) sum * lag / runningTotal else 1.0
        }

        var bestLag = -1
        var lag = minLag
        while (lag < maxLag) {
            if (normalized[lag] < 0.18) {
                while (lag + 1 <= maxLag && normalized[lag + 1] < normalized[lag]) lag++
                bestLag = lag
                break
            }
            lag++
        }
        if (bestLag < 0) {
            bestLag = (minLag..maxLag).minByOrNull { normalized[it] } ?: return null
            if (normalized[bestLag] > 0.32) return null
        }

        var refinedLag = bestLag.toDouble()
        if (bestLag > minLag && bestLag < maxLag) {
            val left = normalized[bestLag - 1]
            val center = normalized[bestLag]
            val right = normalized[bestLag + 1]
            val denominator = left - 2.0 * center + right
            if (kotlin.math.abs(denominator) > 1e-9) {
                val offset = (0.5 * (left - right) / denominator).coerceIn(-1.0, 1.0)
                refinedLag += offset
            }
        }
        val frequency = effectiveRate / refinedLag
        return if (frequency in 35.0..2200.0) frequency else null
    }

    private fun startRecording(result: MethodChannel.Result) {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), RECORD_AUDIO_REQUEST)
            result.error("permission_required", "Allow microphone access, then start the test again.", null)
            return
        }
        if (recording) {
            result.success(true)
            return
        }
        val minBuffer = AudioRecord.getMinBufferSize(
            SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuffer <= 0) {
            result.error("microphone_unavailable", "No microphone recording buffer is available.", null)
            return
        }
        try {
            pcmData = ByteArrayOutputStream()
            audioRecord = AudioRecord(
                // VOICE_RECOGNITION can apply device-specific processing that
                // shifts or suppresses a sung tone. MIC preserves the pitch
                // contour needed by the range test more reliably.
                MediaRecorder.AudioSource.MIC,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                minBuffer * 2,
            )
            audioRecord?.startRecording()
            recording = true
            recordingThread = Thread {
                val buffer = ByteArray(minBuffer)
                while (recording) {
                    val read = audioRecord?.read(buffer, 0, buffer.size) ?: -1
                    if (read > 0) {
                        pcmData.write(buffer, 0, read)
                        if (read >= 2048) {
                            val sampleCount = read / 2
                            val samples = ShortArray(sampleCount)
                            for (index in 0 until sampleCount) {
                                val low = buffer[index * 2].toInt() and 0xff
                                val high = buffer[index * 2 + 1].toInt()
                                samples[index] = ((high shl 8) or low).toShort()
                            }
                            val frequency = detectFrequency(samples, sampleCount)
                            if (frequency != null) {
                                runOnUiThread {
                                    channel?.invokeMethod("voicePitch", mapOf("hz" to frequency))
                                }
                            }
                        }
                    }
                }
            }.also { it.start() }
            result.success(true)
        } catch (error: Exception) {
            recording = false
            audioRecord?.release()
            audioRecord = null
            result.error("microphone_error", error.message, null)
        }
    }

    private fun stopRecording(result: MethodChannel.Result) {
        if (!recording) {
            result.error("not_recording", "Voice recording is not running.", null)
            return
        }
        recording = false
        try {
            recordingThread?.join(1200)
            audioRecord?.stop()
            audioRecord?.release()
            audioRecord = null
            val output = File(cacheDir, "voice_range_${UUID.randomUUID()}.wav")
            writeWaveFile(output, pcmData.toByteArray())
            result.success(output.absolutePath)
        } catch (error: Exception) {
            result.error("recording_error", error.message, null)
        }
    }

    private fun writeWaveFile(file: File, data: ByteArray) {
        FileOutputStream(file).use { output ->
            val totalDataLength = data.size.toLong()
            val totalLength = totalDataLength + 36
            val byteRate = SAMPLE_RATE * 2
            output.write("RIFF".toByteArray())
            output.write(intToLe(totalLength.toInt()))
            output.write("WAVEfmt ".toByteArray())
            output.write(intToLe(16))
            output.write(shortToLe(1))
            output.write(shortToLe(1))
            output.write(intToLe(SAMPLE_RATE))
            output.write(intToLe(byteRate))
            output.write(shortToLe(2))
            output.write(shortToLe(16))
            output.write("data".toByteArray())
            output.write(intToLe(totalDataLength.toInt()))
            output.write(data)
        }
    }

    private fun intToLe(value: Int) = byteArrayOf(
        (value and 0xff).toByte(), ((value shr 8) and 0xff).toByte(),
        ((value shr 16) and 0xff).toByte(), ((value shr 24) and 0xff).toByte(),
    )

    private fun shortToLe(value: Int) = byteArrayOf(
        (value and 0xff).toByte(), ((value shr 8) and 0xff).toByte(),
    )

    override fun onDestroy() {
        recording = false
        audioRecord?.release()
        audioRecord = null
        super.onDestroy()
    }
}
