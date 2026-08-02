package dev.lorepia.app.platform.credentials

import dev.lorepia.app.bridge.ProviderConnection

/**
 * Fails closed before a Core-provided opaque credential reference is handed
 * to Android Keystore. A corrupt or cross-wired reference must never cause one
 * provider connection to borrow another connection's secret.
 */
internal fun ProviderConnection.validatedCredentialRefForRead(): String? {
    if (!credentialSlotReady) {
        check(credentialScope == null) {
            "A credential-free provider connection has credential metadata."
        }
        return null
    }

    val scope = checkNotNull(credentialScope) {
        "The provider credential is missing its approved origin scope."
    }
    check(scope.allowedOrigins.distinct() == listOf(apiOrigin)) {
        "The provider credential reference scope is not bound to exactly its API origin."
    }
    check(approvedCredentialOrigins.distinct() == listOf(apiOrigin)) {
        "The provider connection does not carry the exact approved credential origin."
    }
    return id
}
