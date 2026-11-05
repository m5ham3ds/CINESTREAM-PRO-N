package com.m5ham3ds.cinestreampron.downloads

import android.graphics.BitmapFactory
import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.zip.GZIPInputStream

/**
 * HLS-only response adapter for hosts that disguise MPEG-TS segments as images.
 * It is app-owned so the download pipeline does not depend on an `internal`
 * implementation detail exported by the BetterPlayer Android module.
 *
 * Normal playlists, keys, and media bytes pass through unchanged. Only known
 * wrapper signatures are decoded; malformed recognized wrappers fail closed.
 */
@UnstableApi
internal class DisguisedHlsSegmentDataSource(
    private val upstream: DataSource,
) : DataSource {
    private var buffered: ByteArray? = null
    private var bufferedOffset = 0
    private var passthroughPrefix: ByteArray? = null
    private var prefixOffset = 0

    override fun addTransferListener(transferListener: TransferListener) {
        upstream.addTransferListener(transferListener)
    }

    override fun open(dataSpec: DataSpec): Long {
        resetBuffers()
        val upstreamLength = upstream.open(dataSpec)
        // Byte-range requests cannot safely be unwrapped because the response
        // may not contain the complete image/container payload.
        if (dataSpec.position != 0L || dataSpec.length != C.LENGTH_UNSET.toLong() ||
            upstreamLength > MAX_BUFFER_BYTES || !shouldInspect(dataSpec)
        ) {
            return upstreamLength
        }

        val output = ByteArrayOutputStream(
            if (upstreamLength in 1..INITIAL_BUFFER_BYTES.toLong()) upstreamLength.toInt() else 32 * 1024,
        )
        val chunk = ByteArray(32 * 1024)
        try {
            while (true) {
                val count = upstream.read(chunk, 0, chunk.size)
                if (count == C.RESULT_END_OF_INPUT) break
                if (count <= 0) continue
                output.write(chunk, 0, count)
                if (output.size() > MAX_BUFFER_BYTES) {
                    // Keep the bytes already read and continue from the upstream
                    // source on demand instead of buffering an unexpectedly large
                    // segment or risking excessive memory use.
                    passthroughPrefix = output.toByteArray()
                    return upstreamLength
                }
            }

            val original = output.toByteArray()
            val decoded = DisguisedHlsSegmentUnwrapper.unwrap(original)
            buffered = decoded ?: original
            bufferedOffset = 0
            return buffered!!.size.toLong()
        } catch (error: Exception) {
            close()
            if (error is IOException) throw error
            throw IOException("Unable to unwrap HLS segment response.", error)
        }
    }

    override fun read(target: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0
        val data = buffered
        if (data != null) {
            if (bufferedOffset >= data.size) return C.RESULT_END_OF_INPUT
            val count = minOf(length, data.size - bufferedOffset)
            System.arraycopy(data, bufferedOffset, target, offset, count)
            bufferedOffset += count
            return count
        }

        val prefix = passthroughPrefix
        if (prefix != null && prefixOffset < prefix.size) {
            val count = minOf(length, prefix.size - prefixOffset)
            System.arraycopy(prefix, prefixOffset, target, offset, count)
            prefixOffset += count
            if (prefixOffset >= prefix.size) {
                passthroughPrefix = null
                prefixOffset = 0
            }
            return count
        }
        return upstream.read(target, offset, length)
    }

    override fun getUri(): Uri? = upstream.uri

    override fun getResponseHeaders(): Map<String, List<String>> = upstream.responseHeaders

    override fun close() {
        resetBuffers()
        upstream.close()
    }

    private fun resetBuffers() {
        buffered = null
        bufferedOffset = 0
        passthroughPrefix = null
        prefixOffset = 0
    }

    private fun shouldInspect(dataSpec: DataSpec): Boolean {
        val contentType = upstream.responseHeaders.entries
            .firstOrNull { it.key.equals("Content-Type", ignoreCase = true) }
            ?.value?.firstOrNull().orEmpty().lowercase()
        val path = dataSpec.uri.path.orEmpty().lowercase()
        if (path.endsWith(".m3u8") || path.endsWith(".mpd") ||
            path.contains("/manifest") || path.contains("/playlist")
        ) return false
        return contentType.startsWith("image/") ||
            contentType.contains("text/html") ||
            contentType.contains("octet-stream") ||
            contentType.isBlank() ||
            path.endsWith(".png") || path.endsWith(".webp") ||
            path.endsWith(".jpg") || path.endsWith(".jpeg")
    }

    class Factory(private val upstreamFactory: DataSource.Factory) : DataSource.Factory {
        override fun createDataSource(): DataSource =
            DisguisedHlsSegmentDataSource(upstreamFactory.createDataSource())
    }

    private companion object {
        const val INITIAL_BUFFER_BYTES = 256 * 1024
        const val MAX_BUFFER_BYTES = 32 * 1024 * 1024
    }
}

/** Decodes the transport wrappers used by DLHD-style disguised HLS segments. */
internal object DisguisedHlsSegmentUnwrapper {
    private const val TS_PACKET_SIZE = 188
    private const val MAX_DECOMPRESSED_BYTES = 64 * 1024 * 1024

    fun unwrap(bytes: ByteArray): ByteArray? {
        if (isTransportStream(bytes, 0)) return null

        if (isWebP(bytes)) {
            extractWebpExif(bytes)?.let { return checked(it, "WebP EXIF") }
            throw IOException("WebP HLS segment does not contain an MPEG-TS payload.")
        }

        if (isPng(bytes)) {
            findPngTrailer(bytes)?.let { return checked(it, "PNG trailer") }
            extractPngPixels(bytes)?.let { return it }
            throw IOException("PNG HLS segment does not contain an MPEG-TS payload.")
        }

        findMarker(bytes, RAW_MARKER)?.let { offset ->
            return checked(bytes.copyOfRange(offset + RAW_MARKER.size, bytes.size), "TIKTIKRAW")
        }
        findMarker(bytes, GZIP_MARKER)?.let { offset ->
            val payload = bytes.copyOfRange(offset + GZIP_MARKER.size, bytes.size)
            return checked(gunzip(payload), "TIKTIKTSGZ")
        }

        // Some image hosts prepend a small binary header rather than exposing
        // one of the known signatures. Accept only a valid MPEG-TS sync pattern.
        val offset = findTransportStream(bytes)
        return if (offset >= 0) checked(bytes.copyOfRange(offset, bytes.size), "prefixed TS") else null
    }

    private fun isTransportStream(bytes: ByteArray, offset: Int): Boolean {
        if (offset < 0 || offset + TS_PACKET_SIZE >= bytes.size ||
            bytes[offset] != 0x47.toByte() ||
            bytes[offset + TS_PACKET_SIZE] != 0x47.toByte()
        ) return false
        // A third sync byte makes false positives in ordinary binary media
        // (for example fMP4) substantially less likely.
        return offset + (2 * TS_PACKET_SIZE) >= bytes.size ||
            bytes[offset + (2 * TS_PACKET_SIZE)] == 0x47.toByte()
    }

    private fun checked(payload: ByteArray, source: String): ByteArray {
        if (!isTransportStream(payload, 0)) {
            throw IOException("Invalid MPEG-TS payload in $source wrapper.")
        }
        return payload
    }

    private fun isPng(bytes: ByteArray): Boolean = bytes.size >= PNG_SIGNATURE.size &&
        PNG_SIGNATURE.indices.all { bytes[it] == PNG_SIGNATURE[it] }

    private fun isWebP(bytes: ByteArray): Boolean = bytes.size >= 12 &&
        ascii(bytes, 0, 4) == "RIFF" && ascii(bytes, 8, 4) == "WEBP"

    private fun extractWebpExif(bytes: ByteArray): ByteArray? {
        var offset = 12
        while (offset + 8 <= bytes.size) {
            val tag = ascii(bytes, offset, 4)
            val size = uint32LittleEndian(bytes, offset + 4) ?: return null
            offset += 8
            if (size < 0 || size > bytes.size - offset) return null
            if (tag == "EXIF") return bytes.copyOfRange(offset, offset + size)
            offset += size + (size and 1)
        }
        return null
    }

    private fun findPngTrailer(bytes: ByteArray): ByteArray? {
        var offset = 8
        while (offset + 12 <= bytes.size) {
            val size = uint32BigEndian(bytes, offset) ?: return null
            val tag = ascii(bytes, offset + 4, 4)
            if (size < 0 || size > bytes.size - offset - 12) return null
            offset += size + 12
            if (tag == "IEND") {
                if (isTransportStream(bytes, offset)) return bytes.copyOfRange(offset, bytes.size)
                return null
            }
        }
        return null
    }

    private fun extractPngPixels(bytes: ByteArray): ByteArray? {
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return null
        try {
            val pixelCount = bitmap.width.toLong() * bitmap.height.toLong()
            if (pixelCount <= 0 || pixelCount > 24_000_000L) return null
            val pixels = IntArray(pixelCount.toInt())
            bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
            val rgb = ByteArray(pixels.size * 3)
            var out = 0
            pixels.forEach { pixel ->
                rgb[out++] = ((pixel ushr 16) and 0xff).toByte()
                rgb[out++] = ((pixel ushr 8) and 0xff).toByte()
                rgb[out++] = (pixel and 0xff).toByte()
            }
            if (rgb.size < 12 || ascii(rgb, 0, 8) != "TIKTIKPX") return null
            val size = uint32BigEndian(rgb, 8) ?: return null
            if (size <= 0 || size > rgb.size - 12) return null
            return checked(gunzip(rgb.copyOfRange(12, 12 + size)), "TIKTIKPX")
        } finally {
            bitmap.recycle()
        }
    }

    private fun findTransportStream(bytes: ByteArray): Int {
        for (offset in 0 until (bytes.size - TS_PACKET_SIZE)) {
            if (isTransportStream(bytes, offset)) return offset
        }
        return -1
    }

    private fun findMarker(bytes: ByteArray, marker: ByteArray): Int? {
        if (marker.size > bytes.size) return null
        for (offset in 0..(bytes.size - marker.size)) {
            var matches = true
            for (index in marker.indices) {
                if (bytes[offset + index] != marker[index]) {
                    matches = false
                    break
                }
            }
            if (matches) return offset
        }
        return null
    }

    private fun gunzip(bytes: ByteArray): ByteArray {
        try {
            GZIPInputStream(ByteArrayInputStream(bytes)).use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(16 * 1024)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (output.size().toLong() + count > MAX_DECOMPRESSED_BYTES) {
                        throw IOException("Disguised HLS segment exceeds the decompression limit.")
                    }
                    output.write(buffer, 0, count)
                }
                return output.toByteArray()
            }
        } catch (error: IOException) {
            throw error
        } catch (error: Exception) {
            throw IOException("Invalid gzip payload in disguised HLS segment.", error)
        }
    }

    private fun ascii(bytes: ByteArray, offset: Int, length: Int): String =
        if (offset < 0 || length < 0 || offset + length > bytes.size) ""
        else String(bytes, offset, length, Charsets.US_ASCII)

    private fun uint32BigEndian(bytes: ByteArray, offset: Int): Int? {
        if (offset < 0 || offset + 4 > bytes.size) return null
        val value = ByteBuffer.wrap(bytes, offset, 4).order(ByteOrder.BIG_ENDIAN).int
        return if (value < 0) null else value
    }

    private fun uint32LittleEndian(bytes: ByteArray, offset: Int): Int? {
        if (offset < 0 || offset + 4 > bytes.size) return null
        val value = ByteBuffer.wrap(bytes, offset, 4).order(ByteOrder.LITTLE_ENDIAN).int
        return if (value < 0) null else value
    }

    private val PNG_SIGNATURE = byteArrayOf(
        0x89.toByte(), 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    )
    private val RAW_MARKER = "TIKTIKRAW".toByteArray(Charsets.US_ASCII)
    private val GZIP_MARKER = "TIKTIKTSGZ".toByteArray(Charsets.US_ASCII)
}
