package dev.lorepia.tauri.platform

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class PlatformPolicyTest {
    @Test
    fun credentialNamesAreDeterministicLowercaseHashes() {
        val first = PlatformPolicy.credentialFileName("synthetic-profile")
        val second = PlatformPolicy.credentialFileName("synthetic-profile")

        assertEquals(first, second)
        assertTrue(first.matches(Regex("[0-9a-f]{64}\\.credential")))
        assertFalse(first.contains("synthetic-profile"))
    }

    @Test
    fun sensitiveInputLimitsUseUtf8Bytes() {
        PlatformPolicy.validateReference("가".repeat(85))
        assertThrows(IllegalArgumentException::class.java) {
            PlatformPolicy.validateReference("가".repeat(86))
        }

        val maximum = PlatformPolicy.validateCredentialForWrite(
            "a".repeat(PlatformPolicy.MAXIMUM_CREDENTIAL_WRITE_BYTES),
        )
        maximum.fill(0)
        assertThrows(IllegalArgumentException::class.java) {
            PlatformPolicy.validateCredentialForWrite(
                "a".repeat(PlatformPolicy.MAXIMUM_CREDENTIAL_WRITE_BYTES + 1),
            )
        }
    }

    @Test
    fun displayNamesAreBoundedAndExtensionsAreAllowlisted() {
        val sanitized = PlatformPolicy.sanitizeDisplayName(
            "card\u0000.${"x".repeat(300)}",
        )
        assertFalse(sanitized.contains('\u0000'))
        assertEquals(PlatformPolicy.MAXIMUM_DISPLAY_NAME_CHARACTERS, sanitized.length)
        assertEquals(".charx", PlatformPolicy.stagingSuffix("card.CHARX"))
        assertEquals(".pending", PlatformPolicy.stagingSuffix("card.html"))
    }

    @Test
    fun abandonedStagingCleanupRequiresOwnedOldRegularFile() {
        val now = 2L * PlatformPolicy.ABANDONED_STAGING_AGE_MILLIS
        val old = now - PlatformPolicy.ABANDONED_STAGING_AGE_MILLIS
        assertTrue(
            PlatformPolicy.shouldRemoveAbandonedStagingFile(
                name = "${PlatformPolicy.OWNED_STAGING_PREFIX}synthetic.json",
                isRegularFile = true,
                lastModifiedMillis = old,
                nowMillis = now,
            ),
        )
        assertFalse(
            PlatformPolicy.shouldRemoveAbandonedStagingFile(
                name = "unrelated.json",
                isRegularFile = true,
                lastModifiedMillis = old,
                nowMillis = now,
            ),
        )
        assertFalse(
            PlatformPolicy.shouldRemoveAbandonedStagingFile(
                name = "${PlatformPolicy.OWNED_STAGING_PREFIX}fresh.json",
                isRegularFile = true,
                lastModifiedMillis = old + 1L,
                nowMillis = now,
            ),
        )
        assertFalse(
            PlatformPolicy.shouldRemoveAbandonedStagingFile(
                name = "${PlatformPolicy.OWNED_STAGING_PREFIX}directory",
                isRegularFile = false,
                lastModifiedMillis = old,
                nowMillis = now,
            ),
        )
    }

    @Test
    fun stagedImportDescriptionRedactsPathAndDisplayName() {
        val path = "/synthetic/private/card.json"
        val displayName = "private-card.json"
        val rendered = NativeStagedImport(
            path = path,
            displayName = displayName,
            sizeBytes = 42,
        ).toString()

        assertFalse(rendered.contains(path))
        assertFalse(rendered.contains(displayName))
        assertTrue(rendered.contains("[REDACTED]"))
    }
}
