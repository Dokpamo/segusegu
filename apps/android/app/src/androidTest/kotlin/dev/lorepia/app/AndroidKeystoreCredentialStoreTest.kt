package dev.lorepia.app

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.lorepia.app.platform.credentials.AndroidKeystoreCredentialStore
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidKeystoreCredentialStoreTest {
    @Test
    fun credentialRoundTripUsesEncryptedNoBackupStorage() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val store = AndroidKeystoreCredentialStore(context)
        val profileId = "instrumented-${UUID.randomUUID()}"
        val secret = "synthetic-secret-${UUID.randomUUID()}"

        try {
            store.write(profileId, secret)
            assertEquals(secret, store.read(profileId))

            val records = context.noBackupFilesDir
                .resolve("provider-credentials")
                .listFiles()
                .orEmpty()
            assertFalse(records.any { file ->
                file.readBytes().toString(Charsets.UTF_8).contains(secret)
            })

            store.delete(profileId)
            assertNull(store.read(profileId))
        } finally {
            store.delete(profileId)
        }
    }
}
