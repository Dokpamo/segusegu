package dev.lorepia.app

import android.app.Application
import dev.lorepia.app.bridge.CoreClient
import dev.lorepia.app.bridge.UniFfiCoreClient
import dev.lorepia.app.platform.credentials.AndroidKeystoreCredentialStore
import dev.lorepia.app.platform.credentials.CredentialStore
import dev.lorepia.app.platform.paths.AppDirectories

class LorepiaApplication : Application() {
    @Volatile
    private var processCoreClient: CoreClient? = null
    val credentialStore: CredentialStore by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        AndroidKeystoreCredentialStore(this)
    }

    fun openCoreClient(): CoreClient {
        processCoreClient?.let { return it }
        return synchronized(this) {
            processCoreClient ?: run {
                val directories = AppDirectories.create(this)
                directories.deleteStaleStagingFiles()
                UniFfiCoreClient.open(directories.dataRoot).also { core ->
                    processCoreClient = core
                }
            }
        }
    }
}
