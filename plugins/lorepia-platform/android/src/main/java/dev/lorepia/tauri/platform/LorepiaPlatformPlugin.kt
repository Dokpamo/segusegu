package dev.lorepia.tauri.platform

import android.app.Activity
import android.content.Intent
import androidx.activity.result.ActivityResult
import androidx.appcompat.app.AppCompatActivity
import app.tauri.annotation.ActivityCallback
import app.tauri.annotation.Command
import app.tauri.annotation.InvokeArg
import app.tauri.annotation.TauriPlugin
import app.tauri.plugin.Invoke
import app.tauri.plugin.JSObject
import app.tauri.plugin.Plugin
import java.util.concurrent.atomic.AtomicBoolean

@InvokeArg
internal class ReferenceArgs {
    lateinit var reference: String
}

@InvokeArg
internal class CredentialArgs {
    lateinit var reference: String
    lateinit var value: String
}

@InvokeArg
internal class StagedPathArgs {
    lateinit var path: String
}

@TauriPlugin
class LorepiaPlatformPlugin(private val activity: Activity) : Plugin(activity) {
    private val workQueues = PlatformWorkQueues()
    private val pickerInFlight = AtomicBoolean(false)
    private val credentials = AndroidCredentialStore(activity.applicationContext)
    private val stager = AndroidImportStager(
        activity.contentResolver,
        activity.cacheDir.resolve(IMPORT_STAGING_DIRECTORY).absoluteFile,
    )

    @Command
    fun dataRoot(invoke: Invoke) {
        try {
            val root = activity.filesDir.resolve(DATA_ROOT_DIRECTORY).absoluteFile
            check(root.mkdirs() || root.isDirectory) { "storage unavailable" }
            invoke.resolve(JSObject().put("path", root.absolutePath))
        } catch (_: Exception) {
            invoke.reject("storage unavailable", "storage_unavailable")
        }
    }

    @Command
    fun credentialStatus(invoke: Invoke) {
        workQueues.executeCredential {
            try {
                val args = invoke.parseArgs(ReferenceArgs::class.java)
                val response = JSObject().put(
                    "status",
                    credentials.status(args.reference).wireValue,
                )
                invoke.resolve(response)
            } catch (_: Exception) {
                invoke.resolve(JSObject().put("status", NativeCredentialStatus.UNREADABLE.wireValue))
            }
        }
    }

    @Command
    fun readCredential(invoke: Invoke) {
        workQueues.executeCredential {
            try {
                val args = invoke.parseArgs(ReferenceArgs::class.java)
                invoke.resolve(JSObject().put("value", credentials.read(args.reference)))
            } catch (_: Exception) {
                invoke.reject("credential unavailable", "credential_unavailable")
            }
        }
    }

    @Command
    fun storeCredential(invoke: Invoke) {
        workQueues.executeCredential {
            try {
                val args = invoke.parseArgs(CredentialArgs::class.java)
                credentials.store(args.reference, args.value)
                invoke.resolve()
            } catch (_: CredentialRecoveryRequiredException) {
                invoke.reject(
                    "credential recovery requires user attention",
                    "credential_recovery_required",
                )
            } catch (_: Exception) {
                invoke.reject("credential unavailable", "credential_unavailable")
            }
        }
    }

    @Command
    fun deleteCredential(invoke: Invoke) {
        workQueues.executeCredential {
            try {
                val args = invoke.parseArgs(ReferenceArgs::class.java)
                credentials.delete(args.reference)
                invoke.resolve()
            } catch (_: Exception) {
                invoke.reject("credential unavailable", "credential_unavailable")
            }
        }
    }

    @Command
    fun pickImport(invoke: Invoke) {
        if (!pickerInFlight.compareAndSet(false, true)) {
            invoke.reject("file picker is busy", "busy")
            return
        }
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                putExtra(
                    Intent.EXTRA_MIME_TYPES,
                    arrayOf(
                        "application/json",
                        "application/zip",
                        "application/octet-stream",
                    ),
                )
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivityForResult(invoke, intent, "onImportPicked")
        } catch (_: Exception) {
            pickerInFlight.set(false)
            invoke.reject("file selection failed", "selection_failed")
        }
    }

    @ActivityCallback
    private fun onImportPicked(invoke: Invoke, result: ActivityResult) {
        val uri = result.data?.data
        if (result.resultCode != Activity.RESULT_OK || uri == null) {
            pickerInFlight.set(false)
            invoke.resolve(JSObject().put("selected", false))
            return
        }

        workQueues.executeStaging {
            try {
                val staged = stager.stage(uri)
                invoke.resolve(
                    JSObject()
                        .put("selected", true)
                        .put("path", staged.path)
                        .put("displayName", staged.displayName)
                        .put("sizeBytes", staged.sizeBytes),
                )
            } catch (_: SelectedImportTooLarge) {
                invoke.reject("selected file is too large", "selected_file_too_large")
            } catch (_: Exception) {
                invoke.reject("file selection failed", "selection_failed")
            } finally {
                pickerInFlight.set(false)
            }
        }
    }

    @Command
    fun discardStagedImport(invoke: Invoke) {
        workQueues.executeStaging {
            try {
                val args = invoke.parseArgs(StagedPathArgs::class.java)
                stager.discard(args.path)
                invoke.resolve()
            } catch (_: Exception) {
                invoke.reject("storage unavailable", "storage_unavailable")
            }
        }
    }

    override fun onDestroy(activity: AppCompatActivity) {
        workQueues.shutdownNow()
        pickerInFlight.set(false)
    }

    private companion object {
        const val DATA_ROOT_DIRECTORY = "lorepia-data"
        const val IMPORT_STAGING_DIRECTORY = "import-staging"
    }
}
