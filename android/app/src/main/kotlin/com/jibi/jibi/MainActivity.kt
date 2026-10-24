package com.jibi.jibi

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.os.CancellationSignal
import android.print.PageRange
import android.print.PrintAttributes
import android.print.PrintDocumentAdapter
import android.print.PrintDocumentInfo
import android.print.PrintManager
import java.io.FileInputStream
import java.io.FileOutputStream
import io.flutter.plugin.common.MethodCall
import android.graphics.Bitmap
import android.graphics.pdf.PdfRenderer
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import android.util.Log
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.Executors
import android.content.Intent
import android.content.ClipData
import android.net.Uri
import androidx.core.content.FileProvider
import android.provider.OpenableColumns
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

class MainActivity : FlutterFragmentActivity() {
    private var pickerResult: MethodChannel.Result? = null
    private var backupResult: MethodChannel.Result? = null
    private var backupSource: File? = null
    private var saveResult: MethodChannel.Result? = null
    private var saveSource: File? = null
    private var pendingCapture: File? = null
    private val backgroundWork = Executors.newSingleThreadExecutor()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Screenshots and the recents thumbnail are blocked from the very first
        // frame; Dart lifts the flag once the saved setting says it is off.
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE,
        )
        // The camera app can outlive this process; keep the target path so a
        // late result never leaves an unencrypted photo behind.
        savedInstanceState?.getString(STATE_PENDING_CAPTURE)?.let { pendingCapture = File(it) }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        pendingCapture?.let { outState.putString(STATE_PENDING_CAPTURE, it.absolutePath) }
    }

    override fun onDestroy() {
        backgroundWork.shutdown()
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        cleanupSharedFiles()
        cleanupStaleTemporaryFiles()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.jibi.jibi/file_sharing")
            .setMethodCallHandler { call, result ->
                if (call.method == "shareText") {
                    try {
                        val text = requireNotNull(call.argument<String>("text")).take(20000)
                        shareText(
                            text,
                            call.argument<String>("chooserTitle")?.take(60) ?: "مشاركة",
                            packageList(call.argument<List<String>>("preferredPackages")),
                        )
                        result.success(null)
                    } catch (error: Exception) {
                        Log.e(TAG, "Sharing text failed", error)
                        result.error("share_failed", "Unable to share this text.", null)
                    }
                } else if (call.method == "saveFile") {
                    saveReportFile(call, result)
                } else if (call.method == "printPdf") {
                    printReportPdf(call, result)
                } else if (call.method != "shareFile") {
                    result.notImplemented()
                } else {
                    var copy: File? = null
                    try {
                        cleanupSharedFiles()
                        val folder = File(cacheDir, SHARED_DOCUMENTS_DIR).apply { mkdirs() }
                        val source = File(requireNotNull(call.argument<String>("path"))).canonicalFile
                        val root = File(filesDir, "temporary_documents").canonicalFile
                        require(source.isFile && source.path.startsWith(root.path + File.separator))
                        val extension = source.extension.lowercase()
                        require(extension.matches(Regex("[a-z0-9]{1,10}")))
                        // A readable name (the receiving app shows it) instead of a
                        // random one; it always ends with the source's extension.
                        val readableName = sharedFileName(call.argument<String>("fileName"))
                        val sharedFile = File(
                            folder,
                            if (readableName != null) "$readableName.$extension"
                            else "jibi_${UUID.randomUUID()}.$extension",
                        )
                        copy = sharedFile
                        source.copyTo(sharedFile, overwrite = true)
                        val mime = call.argument<String>("mimeType") ?: "application/octet-stream"
                        shareCachedFile(
                            sharedFile,
                            mime,
                            "مشاركة المستند",
                            packageList(call.argument<List<String>>("preferredPackages")),
                        )
                        result.success(null)
                    } catch (error: Exception) {
                        Log.e(TAG, "Sharing a document failed", error)
                        copy?.delete()
                        result.error("share_failed", "Unable to share this document.", null)
                    }
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.jibi.jibi/document_preview")
            .setMethodCallHandler { call, result ->
                if (call.method != "renderPdf") {
                    result.notImplemented()
                } else {
                    val requestedPath = call.argument<String>("path")
                    val pageNumber = call.argument<Int>("page") ?: 0
                    // Rendering and PNG-encoding a full page takes long enough
                    // to stall the UI thread, so it runs on the worker.
                    backgroundWork.execute {
                        try {
                            val file = File(requireNotNull(requestedPath)).canonicalFile
                            val root = File(filesDir.parentFile, "files").canonicalFile
                            require(file.path.startsWith(root.path + File.separator))
                            ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
                                PdfRenderer(descriptor).use { renderer ->
                                    renderer.openPage(pageNumber).use { page ->
                                        val width = 1400
                                        val height = (width.toDouble() * page.height / page.width).toInt().coerceIn(1, 2400)
                                        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                                        try {
                                            bitmap.eraseColor(android.graphics.Color.WHITE)
                                            page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                                            val output = ByteArrayOutputStream()
                                            bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
                                            completeSuccess(
                                                result,
                                                mapOf("bytes" to output.toByteArray(), "pageCount" to renderer.pageCount),
                                            )
                                        } finally { bitmap.recycle() }
                                    }
                                }
                            }
                        } catch (error: Exception) {
                            Log.e(TAG, "Previewing a PDF failed", error)
                            completeError(result, "preview_failed", "Unable to preview this document.")
                        }
                    }
                }
            }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BACKUP_FILE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            if (call.method != "exportBackup" && call.method != "importBackup") {
                result.notImplemented()
            } else if (pickerResult != null || backupResult != null) {
                result.error("picker_in_progress", "A file picker is already open.", null)
            } else if (call.method == "importBackup") {
                backupResult = result
                startActivityForResult(
                    Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "application/zip"
                        putExtra(
                            Intent.EXTRA_MIME_TYPES,
                            arrayOf("application/zip", "application/x-zip-compressed", "application/octet-stream"),
                        )
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    },
                    IMPORT_BACKUP_REQUEST,
                )
            } else {
                try {
                    val source = File(requireNotNull(call.argument<String>("sourcePath"))).canonicalFile
                    val filesRoot = filesDir.canonicalFile
                    require(source.isFile && source.path.startsWith(filesRoot.path + File.separator))
                    val requestedName = call.argument<String>("suggestedName") ?: "Jibi_Backup.zip"
                    val safeName = requestedName.replace(Regex("[^A-Za-z0-9_.-]"), "_")
                        .take(120)
                        .ifBlank { "Jibi_Backup.zip" }
                        .let { if (it.endsWith(".zip", ignoreCase = true)) it else "$it.zip" }
                    val preferGoogleDrive = call.argument<Boolean>("preferGoogleDrive") ?: false
                    if (preferGoogleDrive) {
                        shareBackupToDrive(source, safeName, result)
                        return@setMethodCallHandler
                    }
                    backupResult = result
                    backupSource = source
                    startActivityForResult(
                        Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "application/zip"
                            putExtra(Intent.EXTRA_TITLE, safeName)
                            putExtra(Intent.EXTRA_LOCAL_ONLY, true)
                            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                        },
                        EXPORT_BACKUP_REQUEST,
                    )
                } catch (error: Exception) {
                    Log.e(TAG, "Preparing the backup export failed", error)
                    backupResult = null
                    backupSource = null
                    result.error("invalid_backup_source", "The backup source is unavailable.", null)
                }
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DOCUMENT_PICKER_CHANNEL,
        ).setMethodCallHandler { call, result ->
            if (call.method != "pickDocument" && call.method != "captureDocument") {
                result.notImplemented()
            } else if (pickerResult != null) {
                result.error("picker_in_progress", "A picker is already open.", null)
            } else if (call.method == "captureDocument") {
                startCameraCapture(result)
            } else {
                pickerResult = result
                startActivityForResult(
                    Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    },
                    PICK_DOCUMENT_REQUEST,
                )
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SCREEN_PROTECTION_CHANNEL,
        ).setMethodCallHandler { call, result ->
            if (call.method != "setEnabled") {
                result.notImplemented()
            } else {
                val enabled = call.argument<Boolean>("enabled") ?: true
                if (enabled) {
                    window.setFlags(
                        WindowManager.LayoutParams.FLAG_SECURE,
                        WindowManager.LayoutParams.FLAG_SECURE,
                    )
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                }
                result.success(null)
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EXTERNAL_LINKS_CHANNEL,
        ).setMethodCallHandler { call, result ->
            if (call.method !in EXTERNAL_LINK_METHODS) {
                result.notImplemented()
            } else {
                try {
                    result.success(openExternalLink(call))
                } catch (error: IllegalArgumentException) {
                    Log.e(TAG, "Rejected an external link request", error)
                    result.error("invalid_link", "Invalid request.", null)
                } catch (error: Exception) {
                    Log.e(TAG, "Opening an external link failed", error)
                    result.error("open_failed", "Unable to open this link.", null)
                }
            }
        }
    }

    /**
     * Opens WhatsApp, the dialer, a mail app or the browser (the support
     * screen). Returns false when nothing on the phone can handle the request;
     * the caller tells the user. The activity is started directly (no
     * resolveActivity), so no package-visibility queries are needed.
     */
    private fun openExternalLink(call: MethodCall): Boolean = when (call.method) {
        "openWhatsApp" -> {
            val view = viewIntent(httpsUri(call.argument<String>("url")))
            // WhatsApp, then WhatsApp Business, then whatever opens the link
            // (the browser shows wa.me's own "continue to chat" page).
            packageList(call.argument<List<String>>("preferredPackages")).any {
                tryStart(Intent(view).setPackage(it))
            } || tryStart(view)
        }
        "dial" -> {
            val phone = requireNotNull(call.argument<String>("phone"))
            require(phone.matches(Regex("[0-9]{6,15}")))
            // ACTION_DIAL only fills in the number; no call permission needed.
            tryStart(Intent(Intent.ACTION_DIAL, Uri.parse("tel:+$phone")))
        }
        "composeEmail" -> {
            val to = requireNotNull(call.argument<String>("to"))
            require(to.matches(Regex("[^@\\s]{1,64}@[^@\\s]{1,255}")))
            // A mailto: data URI keeps the chooser to mail apps.
            tryStart(
                Intent(Intent.ACTION_SENDTO, Uri.parse("mailto:")).apply {
                    putExtra(Intent.EXTRA_EMAIL, arrayOf(to))
                    putExtra(Intent.EXTRA_SUBJECT, (call.argument<String>("subject") ?: "").take(200))
                    putExtra(Intent.EXTRA_TEXT, (call.argument<String>("body") ?: "").take(2000))
                },
            )
        }
        else -> tryStart(viewIntent(httpsUri(call.argument<String>("url"))))
    }

    /**
     * Only the support links the app itself offers are opened (see
     * SupportContact and ExternalLinkLauncher). A new host must be added to
     * [ALLOWED_LINK_HOSTS] together with the Dart constant that uses it.
     */
    private fun httpsUri(value: String?): Uri {
        require(value != null && value.length <= 4000 && value.startsWith("https://"))
        val uri = Uri.parse(value)
        val host = uri.host?.lowercase()
        require(host != null && host in ALLOWED_LINK_HOSTS)
        return uri
    }

    private fun viewIntent(uri: Uri): Intent =
        Intent(Intent.ACTION_VIEW, uri).addCategory(Intent.CATEGORY_BROWSABLE)

    private fun tryStart(intent: Intent): Boolean =
        try {
            startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            false
        }

    /**
     * Shared decrypted documents/PDFs live for an hour. Encrypted backups handed
     * to the share sheet live for a day, because a Drive upload queued while the
     * phone is offline reads the file later.
     */
    private fun cleanupSharedFiles() {
        deleteOlderThan(File(cacheDir, SHARED_DOCUMENTS_DIR), SHARED_DOCUMENT_TTL_MS, revoke = true)
        deleteOlderThan(File(cacheDir, SHARED_BACKUPS_DIR), SHARED_BACKUP_TTL_MS, revoke = true)
    }

    /** Leftovers of interrupted imports and camera captures (plaintext). */
    private fun cleanupStaleTemporaryFiles() {
        cacheDir.listFiles()
            ?.filter {
                it.isFile && (it.name.startsWith("jibi-import-") || it.name.startsWith("jibi-restore-"))
            }
            ?.forEach { file ->
                if (System.currentTimeMillis() - file.lastModified() >= STALE_TEMP_TTL_MS) file.delete()
            }
        deleteOlderThan(File(cacheDir, CAMERA_CAPTURE_DIR), STALE_TEMP_TTL_MS, revoke = false, wipe = true)
    }

    private fun deleteOlderThan(folder: File, ttlMs: Long, revoke: Boolean, wipe: Boolean = false) {
        val cutoff = System.currentTimeMillis() - ttlMs
        folder.listFiles()?.filter { it.isFile && it.lastModified() <= cutoff }?.forEach { file ->
            try {
                if (revoke) {
                    val uri = FileProvider.getUriForFile(this, "$packageName.sharedfiles", file)
                    revokeUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                if (wipe) wipeAndDelete(file) else file.delete()
            } catch (_: Exception) { /* Retry on the next launch. */ }
        }
    }

    /**
     * Best-effort in-place overwrite (no truncation) so a plaintext photo is
     * not left recoverable in the cache, then delete.
     */
    private fun wipeAndDelete(file: File) {
        try {
            if (file.isFile) {
                java.io.RandomAccessFile(file, "rw").use { access ->
                    val zeros = ByteArray(8192)
                    var remaining = access.length()
                    access.seek(0)
                    while (remaining > 0) {
                        val chunk = minOf(remaining, zeros.size.toLong()).toInt()
                        access.write(zeros, 0, chunk)
                        remaining -= chunk
                    }
                    access.fd.sync()
                }
            }
        } catch (_: Exception) { /* Deleting below is still the important part. */ }
        file.delete()
    }

    /**
     * Builds the (already encrypted) backup ZIP off the UI thread, then opens
     * Google Drive's own upload screen when the app is installed, or the system
     * share sheet otherwise. Android does not report whether the upload later
     * finishes, so success means "the share screen was opened".
     */
    private fun shareBackupToDrive(source: File, safeName: String, result: MethodChannel.Result) {
        val folder = File(cacheDir, SHARED_BACKUPS_DIR).apply { mkdirs() }
        cleanupSharedFiles()
        backgroundWork.execute {
            val sharedZip = File(folder, safeName)
            try {
                if (sharedZip.exists()) sharedZip.delete()
                sharedZip.outputStream().use { fileOutput ->
                    ZipOutputStream(fileOutput).use { zip ->
                        zip.putNextEntry(ZipEntry(BACKUP_ZIP_ENTRY))
                        source.inputStream().use { input -> input.copyTo(zip) }
                        zip.closeEntry()
                    }
                }
            } catch (error: IOException) {
                Log.e(TAG, "Preparing the backup for sharing failed", error)
                sharedZip.delete()
                completeError(result, "backup_share_prepare_failed", "Unable to prepare the backup file.")
                return@execute
            }
            runOnUiThread {
                try {
                    shareCachedFile(
                        sharedZip,
                        "application/zip",
                        "حفظ النسخة في Google Drive",
                        listOf(DRIVE_PACKAGE),
                    )
                    // True only means the share screen opened; Android never
                    // tells us whether the upload itself finishes.
                    result.success(true)
                } catch (error: ActivityNotFoundException) {
                    Log.e(TAG, "No app can receive the backup", error)
                    sharedZip.delete()
                    result.error("no_share_target", "No app can receive the backup file.", null)
                } catch (error: Exception) {
                    Log.e(TAG, "Sharing the backup failed", error)
                    sharedZip.delete()
                    result.error("backup_share_failed", "Unable to share the backup file.", null)
                }
            }
        }
    }

    private fun startCameraCapture(result: MethodChannel.Result) {
        val folder = File(cacheDir, CAMERA_CAPTURE_DIR).apply { mkdirs() }
        val target = File(folder, "jibi-capture-${UUID.randomUUID()}.jpg")
        try {
            val uri = FileProvider.getUriForFile(this, "$packageName.sharedfiles", target)
            val intent = Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
                putExtra(MediaStore.EXTRA_OUTPUT, uri)
                clipData = ClipData.newRawUri("", uri)
                addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            pickerResult = result
            pendingCapture = target
            startActivityForResult(intent, CAPTURE_DOCUMENT_REQUEST)
        } catch (error: ActivityNotFoundException) {
            pickerResult = null
            pendingCapture = null
            target.delete()
            result.error("no_camera_app", "No camera app is available.", null)
        } catch (error: Exception) {
            Log.e(TAG, "Starting the camera failed", error)
            pickerResult = null
            pendingCapture = null
            target.delete()
            result.error("camera_failed", "Unable to start the camera.", null)
        }
    }

    private fun handleCaptureResult(resultCode: Int) {
        val result = pickerResult
        val file = pendingCapture
        pickerResult = null
        pendingCapture = null
        if (result == null) {
            // The Flutter side is gone (process was recreated): never keep the photo.
            file?.let { wipeAndDelete(it) }
            return
        }
        if (resultCode != Activity.RESULT_OK || file == null || !file.isFile || file.length() == 0L) {
            file?.let { wipeAndDelete(it) }
            result.success(null)
            return
        }
        result.success(
            mapOf(
                "path" to file.absolutePath,
                "extension" to "jpg",
                "mimeType" to "image/jpeg",
            ),
        )
    }

    /**
     * Shares plain text; opens the first of [preferredPackages] (for example
     * WhatsApp, then WhatsApp Business) that is installed, otherwise the chooser.
     */
    private fun shareText(
        text: String,
        chooserTitle: String,
        preferredPackages: List<String> = emptyList(),
    ) {
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, text)
        }
        for (candidate in preferredPackages) {
            try {
                startActivity(Intent(intent).setPackage(candidate))
                return
            } catch (_: ActivityNotFoundException) {
                // Not installed: try the next one.
            }
        }
        startActivity(Intent.createChooser(intent, chooserTitle))
    }

    /** Package names from Dart, keeping only well-formed ones. */
    private fun packageList(requested: List<String>?): List<String> =
        requested?.filter { it.matches(Regex("[A-Za-z0-9_.]{1,100}")) } ?: emptyList()

    /**
     * Opens the first of [preferredPackages] that is installed and accepts the
     * file (for example WhatsApp, then WhatsApp Business), otherwise the system
     * chooser.
     */
    private fun shareCachedFile(
        file: File,
        mimeType: String,
        chooserTitle: String,
        preferredPackages: List<String> = emptyList(),
    ) {
        val uri = FileProvider.getUriForFile(this, "$packageName.sharedfiles", file)
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = mimeType
            putExtra(Intent.EXTRA_STREAM, uri)
            clipData = ClipData.newUri(contentResolver, "ملف جيبي", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        for (candidate in preferredPackages) {
            try {
                startActivity(Intent(intent).setPackage(candidate))
                return
            } catch (_: ActivityNotFoundException) {
                // Not installed or cannot take this file: try the next one.
            }
        }
        startActivity(Intent.createChooser(intent, chooserTitle))
    }

    /**
     * A file name for the receiving app: letters (Arabic included), digits, "_"
     * and "-" only, bounded, or null when nothing usable is left.
     */
    private fun sharedFileName(requested: String?): String? =
        requested
            ?.replace(Regex("[^\\p{L}\\p{N}_-]+"), "_")
            ?.trim('_')
            ?.take(80)
            ?.takeIf { it.isNotEmpty() }

    /** A report file the app just wrote in its private temporary folder. */
    private fun reportSource(path: String): File {
        val source = File(path).canonicalFile
        val root = File(filesDir, "temporary_documents").canonicalFile
        require(source.isFile && source.path.startsWith(root.path + File.separator))
        return source
    }

    /**
     * "Save to the device": the system save-as screen, then a copy of the
     * report file. The result reaches Dart when the copy is finished (true) or
     * the user backed out (false); the temporary source lives until then.
     */
    private fun saveReportFile(call: MethodCall, result: MethodChannel.Result) {
        if (pickerResult != null || backupResult != null || saveResult != null) {
            result.error("picker_in_progress", "A file picker is already open.", null)
            return
        }
        try {
            val source = reportSource(requireNotNull(call.argument<String>("path")))
            val name = call.argument<String>("fileName")
                ?.replace(Regex("[\\\\/:*?\"<>|\\u0000-\\u001f]"), " ")
                ?.trim()
                ?.take(120)
                ?.takeIf { it.isNotEmpty() }
                ?: "report"
            val mime = call.argument<String>("mimeType")
                ?.takeIf { it.matches(Regex("[a-z0-9.+/-]{3,120}")) }
                ?: "application/octet-stream"
            saveResult = result
            saveSource = source
            startActivityForResult(
                Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = mime
                    putExtra(Intent.EXTRA_TITLE, name)
                    addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                },
                SAVE_REPORT_REQUEST,
            )
        } catch (error: Exception) {
            Log.e(TAG, "Preparing the report save failed", error)
            saveResult = null
            saveSource = null
            result.error("save_failed", "Unable to save this file.", null)
        }
    }

    private fun handleSaveReportResult(resultCode: Int, data: Intent?) {
        val result = saveResult ?: return
        val source = saveSource
        saveResult = null
        saveSource = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.success(false)
            return
        }
        val uri = data.data!!
        backgroundWork.execute {
            try {
                requireNotNull(source) { "The report source is unavailable." }
                // "wt" truncates: plain "w" may keep the tail of a longer file
                // that is being overwritten (a corrupt PDF or workbook).
                contentResolver.openOutputStream(uri, "wt").use { output ->
                    requireNotNull(output) { "Unable to open the destination." }
                    source.inputStream().use { input -> input.copyTo(output) }
                }
                runOnUiThread { result.success(true) }
            } catch (error: Exception) {
                Log.e(TAG, "Saving the report failed", error)
                runOnUiThread { result.error("save_failed", "Unable to save this file.", null) }
            }
        }
    }

    /**
     * Opens the system print screen with the report PDF. The print service
     * reads the file later, after the user picks a printer, so the job gets its
     * own copy in the cache (removed by the same cleanup as shared files).
     */
    private fun printReportPdf(call: MethodCall, result: MethodChannel.Result) {
        var copy: File? = null
        try {
            cleanupSharedFiles()
            val source = reportSource(requireNotNull(call.argument<String>("path")))
            require(source.extension.equals("pdf", ignoreCase = true))
            val folder = File(cacheDir, SHARED_DOCUMENTS_DIR).apply { mkdirs() }
            val jobFile = File(folder, "print_${UUID.randomUUID()}.pdf")
            copy = jobFile
            source.copyTo(jobFile, overwrite = true)
            val jobName = (call.argument<String>("jobName") ?: "جيبي").take(80)
            val manager = getSystemService(Context.PRINT_SERVICE) as PrintManager
            manager.print(
                jobName,
                object : PrintDocumentAdapter() {
                    override fun onLayout(
                        oldAttributes: PrintAttributes?,
                        newAttributes: PrintAttributes?,
                        cancellationSignal: CancellationSignal?,
                        callback: LayoutResultCallback?,
                        extras: Bundle?,
                    ) {
                        if (cancellationSignal?.isCanceled == true) {
                            callback?.onLayoutCancelled()
                            return
                        }
                        val info = PrintDocumentInfo.Builder(jobName)
                            .setContentType(PrintDocumentInfo.CONTENT_TYPE_DOCUMENT)
                            .setPageCount(PrintDocumentInfo.PAGE_COUNT_UNKNOWN)
                            .build()
                        callback?.onLayoutFinished(info, true)
                    }

                    override fun onWrite(
                        pages: Array<PageRange>?,
                        destination: ParcelFileDescriptor?,
                        cancellationSignal: CancellationSignal?,
                        callback: WriteResultCallback?,
                    ) {
                        try {
                            FileInputStream(jobFile).use { input ->
                                FileOutputStream(requireNotNull(destination).fileDescriptor).use { output ->
                                    input.copyTo(output)
                                }
                            }
                            callback?.onWriteFinished(arrayOf(PageRange.ALL_PAGES))
                        } catch (error: Exception) {
                            Log.e(TAG, "Writing the print job failed", error)
                            callback?.onWriteFailed(error.message)
                        }
                    }

                    // The job is over (printed or cancelled): drop its copy of
                    // the report right away instead of waiting for the cleanup.
                    override fun onFinish() {
                        jobFile.delete()
                    }
                },
                PrintAttributes.Builder().build(),
            )
            result.success(null)
        } catch (error: Exception) {
            Log.e(TAG, "Printing a report failed", error)
            copy?.delete()
            result.error("print_failed", "Unable to print this document.", null)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            PICK_DOCUMENT_REQUEST -> handleDocumentResult(resultCode, data)
            IMPORT_BACKUP_REQUEST -> handleBackupImportResult(resultCode, data)
            EXPORT_BACKUP_REQUEST -> handleBackupExportResult(resultCode, data)
            CAPTURE_DOCUMENT_REQUEST -> handleCaptureResult(resultCode)
            SAVE_REPORT_REQUEST -> handleSaveReportResult(resultCode, data)
        }
    }

    private fun handleDocumentResult(resultCode: Int, data: Intent?) {
        val result = pickerResult ?: return
        pickerResult = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.success(null)
            return
        }
        val uri = data.data!!
        // The file may come from a cloud provider (Drive), so it is copied on
        // the worker instead of blocking the UI thread.
        backgroundWork.execute {
            var target: File? = null
            try {
                val name = queryDisplayName(uri) ?: "document"
                val extension = name.substringAfterLast('.', "").lowercase()
                    .takeIf { it.matches(Regex("[A-Za-z0-9]{1,16}")) } ?: "bin"
                val importedFile = File(
                    cacheDir,
                    "jibi-import-${UUID.randomUUID()}.$extension",
                )
                target = importedFile
                contentResolver.openInputStream(uri).use { input ->
                    requireNotNull(input) { "Unable to open selected document." }
                    importedFile.outputStream().use { output -> input.copyTo(output) }
                }
                completeSuccess(
                    result,
                    mapOf(
                        "path" to importedFile.absolutePath,
                        "extension" to extension,
                        "mimeType" to (contentResolver.getType(uri) ?: "application/octet-stream"),
                    ),
                )
            } catch (error: Exception) {
                Log.e(TAG, "Copying the selected document failed", error)
                target?.delete()
                completeError(result, "document_copy_failed", "Unable to copy selected document.")
            }
        }
    }

    private fun handleBackupImportResult(resultCode: Int, data: Intent?) {
        val result = backupResult ?: return
        backupResult = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.success(null)
            return
        }
        val uri = data.data!!
        backgroundWork.execute {
            var target: File? = null
            try {
                val imported = File(cacheDir, "jibi-restore-${UUID.randomUUID()}.jibi")
                target = imported
                contentResolver.openInputStream(uri).use { rawInput ->
                    requireNotNull(rawInput) { "Unable to open selected backup." }
                    val input = BufferedInputStream(rawInput)
                    if (looksLikeZip(input)) {
                        ZipInputStream(input).use { zip ->
                            var restored = false
                            while (true) {
                                val entry = zip.nextEntry ?: break
                                if (!entry.isDirectory && entry.name == BACKUP_ZIP_ENTRY) {
                                    imported.outputStream().use { output ->
                                        copyLimited(zip, output, MAX_BACKUP_BYTES)
                                    }
                                    restored = true
                                    zip.closeEntry()
                                    break
                                }
                                zip.closeEntry()
                            }
                            require(restored) { "Backup ZIP does not contain $BACKUP_ZIP_ENTRY." }
                        }
                    } else {
                        // A raw .jibi container (for example copied out of Drive as-is).
                        imported.outputStream().use { output ->
                            copyLimited(input, output, MAX_BACKUP_BYTES)
                        }
                    }
                }
                completeSuccess(result, imported.absolutePath)
            } catch (error: Exception) {
                Log.e(TAG, "Importing the backup failed", error)
                target?.delete()
                completeError(
                    result,
                    "backup_import_failed",
                    "Unable to copy selected backup.",
                )
            }
        }
    }

    private fun looksLikeZip(input: BufferedInputStream): Boolean {
        input.mark(4)
        val header = ByteArray(4)
        val read = input.read(header)
        input.reset()
        return read == 4 && header[0] == 0x50.toByte() && header[1] == 0x4B.toByte() &&
            header[2] == 0x03.toByte() && header[3] == 0x04.toByte()
    }

    /** Copies at most [limit] bytes and fails instead of silently truncating or filling storage. */
    private fun copyLimited(input: InputStream, output: OutputStream, limit: Long) {
        val buffer = ByteArray(64 * 1024)
        var total = 0L
        while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            total += read
            if (total > limit) throw IOException("Backup exceeds the $limit byte limit.")
            output.write(buffer, 0, read)
        }
    }

    private fun handleBackupExportResult(resultCode: Int, data: Intent?) {
        val result = backupResult ?: return
        val source = backupSource
        backupResult = null
        backupSource = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.success(false)
            return
        }
        val uri = data.data!!
        backgroundWork.execute {
            try {
                requireNotNull(source) { "The backup source is unavailable." }
                contentResolver.openOutputStream(uri, "wt").use { output ->
                    requireNotNull(output) { "Unable to open backup destination." }
                    ZipOutputStream(output).use { zip ->
                        zip.putNextEntry(ZipEntry(BACKUP_ZIP_ENTRY))
                        source.inputStream().use { input -> input.copyTo(zip) }
                        zip.closeEntry()
                    }
                }
                completeSuccess(result, true)
            } catch (error: Exception) {
                Log.e(TAG, "Exporting the backup failed", error)
                completeError(result, "backup_export_failed", "Unable to export backup.")
            }
        }
    }

    /** Channel results must be delivered on the UI thread, whatever thread did the work. */
    private fun completeSuccess(result: MethodChannel.Result, value: Any?) {
        runOnUiThread { result.success(value) }
    }

    private fun completeError(result: MethodChannel.Result, code: String, message: String) {
        runOnUiThread { result.error(code, message, null) }
    }

    private fun queryDisplayName(uri: android.net.Uri): String? =
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor ->
                if (cursor.moveToFirst()) {
                    cursor.getString(cursor.getColumnIndexOrThrow(OpenableColumns.DISPLAY_NAME))
                } else {
                    null
                }
            }

    companion object {
        private const val TAG = "JibiMainActivity"
        private const val DRIVE_PACKAGE = "com.google.android.apps.docs"
        private const val SHARED_DOCUMENTS_DIR = "shared_documents"
        private const val SHARED_BACKUPS_DIR = "shared_backups"
        private const val CAMERA_CAPTURE_DIR = "camera_capture"
        private const val STATE_PENDING_CAPTURE = "pending_capture_path"
        private const val SHARED_DOCUMENT_TTL_MS = 60 * 60 * 1000L
        private const val SHARED_BACKUP_TTL_MS = 24 * 60 * 60 * 1000L
        private const val STALE_TEMP_TTL_MS = 5 * 60 * 1000L
        private const val MAX_BACKUP_BYTES = 2L * 1024 * 1024 * 1024
        private const val DOCUMENT_PICKER_CHANNEL = "com.jibi.jibi/document_source_picker"
        private const val SCREEN_PROTECTION_CHANNEL = "com.jibi.jibi/screen_protection"
        private const val EXTERNAL_LINKS_CHANNEL = "com.jibi.jibi/external_links"
        private val EXTERNAL_LINK_METHODS = setOf("openWhatsApp", "dial", "composeEmail", "openWebsite")
        private val ALLOWED_LINK_HOSTS = setOf("wa.me", "alaw9l.com", "www.alaw9l.com")
        private const val BACKUP_FILE_CHANNEL = "com.jibi.jibi/backup_file_transfer"
        private const val BACKUP_ZIP_ENTRY = "jibi_backup.jibi"
        private const val PICK_DOCUMENT_REQUEST = 1024
        private const val IMPORT_BACKUP_REQUEST = 1025
        private const val EXPORT_BACKUP_REQUEST = 1026
        private const val CAPTURE_DOCUMENT_REQUEST = 1027
        private const val SAVE_REPORT_REQUEST = 1028
    }
}
