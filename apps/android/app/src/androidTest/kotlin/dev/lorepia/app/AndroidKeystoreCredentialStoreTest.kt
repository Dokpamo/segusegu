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
        val connectionId = "instrumented-${UUID.randomUUID()}"
        val secret = "synthetic-secret-${UUID.randomUUID()}"

        try {
            store.write(connectionId, secret)
            assertEquals(secret, store.read(connectionId))

            val records = context.noBackupFilesDir
                .resolve("provider-credentials")
                .listFiles()
                .orEmpty()
            assertFalse(records.any { file ->
                file.readBytes().toString(Charsets.UTF_8).contains(secret)
            })

            store.delete(connectionId)
            assertNull(store.read(connectionId))
        } finally {
            store.delete(connectionId)
        }
    }

    @Test
    fun immutableConnectionIdPreservesCredentialAcrossStoreInstances() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val legacyWriter = AndroidKeystoreCredentialStore(context)
        val migratedReader = AndroidKeystoreCredentialStore(context)
        val connectionId = "legacy-profile-id-${UUID.randomUUID()}"
        val secret = "synthetic-migrated-secret-${UUID.randomUUID()}"

        try {
            legacyWriter.write(connectionId, secret)
            assertEquals(secret, migratedReader.read(connectionId))
            migratedReader.write(connectionId, "$secret-replaced")
            assertEquals("$secret-replaced", legacyWriter.read(connectionId))
        } finally {
            migratedReader.delete(connectionId)
        }
    }
}
