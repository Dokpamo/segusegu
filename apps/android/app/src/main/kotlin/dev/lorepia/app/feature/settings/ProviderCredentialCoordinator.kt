package dev.lorepia.app.feature.settings

import dev.lorepia.app.bridge.CoreClient
import dev.lorepia.app.bridge.DiscoveryCompensationKind
import dev.lorepia.app.bridge.DiscoveryCompensationStatus
import dev.lorepia.app.bridge.DiscoveryCompensationTarget
import dev.lorepia.app.bridge.DiscoveryFailure
import dev.lorepia.app.bridge.ProviderConnection
import dev.lorepia.app.bridge.ProviderConnectionDraft
import dev.lorepia.app.bridge.ProviderDiscoveryInput
import dev.lorepia.app.bridge.ProviderDiscoverySnapshot
import dev.lorepia.app.bridge.ProviderDiscoverySource
import dev.lorepia.app.bridge.ProviderNetworkPolicy
import dev.lorepia.app.platform.credentials.CredentialStore
import dev.lorepia.app.platform.credentials.CredentialRecordStatus
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * Serializes mutations that cross the Rust database and Android Keystore.
 *
 * Android Keystore and SQLite cannot participate in one physical transaction.
 * This coordinator therefore writes the credential first and restores the
 * previous encrypted value if the core mutation fails or is cancelled. Deletes
 * use the inverse operation and restore the credential if the database refuses
 * the deletion. The caller never persists credential material in UI state
 * beyond the active editor.
 */
class ProviderCredentialCoordinator(
    private val coreClient: CoreClient,
    private val credentialStore: CredentialStore,
) {
    suspend fun beginDiscovery(
        input: ProviderDiscoveryInput,
        source: ProviderDiscoverySource,
        rawCurl: String?,
        credential: String?,
    ): ProviderDiscoverySnapshot = PROCESS_MUTATION_MUTEX.withLock {
        val normalized = credential?.takeIf(String::isNotBlank)
        requireCredentialSlotIsUnused(input.connectionId)
        try {
            if (normalized != null) {
                credentialStore.write(input.connectionId, normalized)
            }
            val snapshot = coreClient.beginProviderDiscovery(
                input = input.copy(credentialSlotReady = normalized != null),
                source = source,
                rawCurl = rawCurl,
            )
            validateDiscoverySlot(snapshot)
            snapshot
        } catch (cancellation: CancellationException) {
            rollbackNewDiscoverySlot(input.connectionId, normalized != null, cancellation)
            throw cancellation
        } catch (error: Throwable) {
            rollbackNewDiscoverySlot(input.connectionId, normalized != null, error)
            throw error
        }
    }

    suspend fun beginCurlDiscovery(
        input: ProviderDiscoveryInput,
        redactedCurl: String,
        credential: ByteArray?,
    ): ProviderDiscoverySnapshot = PROCESS_MUTATION_MUTEX.withLock {
        require(redactedCurl.isNotBlank()) { "The redacted cURL input must not be blank." }
        requireCredentialSlotIsUnused(input.connectionId)
        val hasCredential = credential != null
        try {
            if (credential != null) {
                require(credential.isNotEmpty()) { "The cURL credential handoff was empty." }
                credentialStore.writeBytes(input.connectionId, credential)
            }
            val snapshot = coreClient.beginProviderDiscovery(
                input = input.copy(credentialSlotReady = hasCredential),
                source = ProviderDiscoverySource.Curl,
                rawCurl = redactedCurl,
            )
            validateDiscoverySlot(snapshot)
            snapshot
        } catch (cancellation: CancellationException) {
            rollbackNewDiscoverySlot(input.connectionId, hasCredential, cancellation)
            throw cancellation
        } catch (error: Throwable) {
            rollbackNewDiscoverySlot(input.connectionId, hasCredential, error)
            throw error
        }
    }

    suspend fun continueDiscovery(
        snapshot: ProviderDiscoverySnapshot,
        envelope: dev.lorepia.app.bridge.ProviderDiscoveryActionEnvelope,
        credentialRequired: Boolean,
    ): ProviderDiscoverySnapshot {
        validateDiscoverySlot(snapshot)
        val credential = if (credentialRequired) {
            readDiscoveryCredential(snapshot)
        } else {
            null
        }
        return coreClient.continueProviderDiscovery(
            sessionId = snapshot.sessionId,
            envelope = envelope,
            credential = credential,
        ).also(::validateDiscoverySlot)
    }

    /**
     * Parses supplemental cURL exactly once through Core, persists a one-shot
     * handoff only into the already-declared exact discovery slot, and supplies
     * only the redacted cURL as durable evidence.
     *
     * Replacing an existing native credential requires a separate flow. This
     * method fails closed and clears the newly handed-off bytes instead of
     * silently overwriting a vault record.
     */
    suspend fun supplyCurlEvidence(
        snapshot: ProviderDiscoverySnapshot,
        rawCurl: String,
        networkPolicy: ProviderNetworkPolicy,
    ): ProviderDiscoverySnapshot = PROCESS_MUTATION_MUTEX.withLock {
        validateDiscoverySlot(snapshot)
        require(rawCurl.isNotBlank()) { "The discovery cURL evidence must not be blank." }
        val inspection = coreClient.inspectProviderCurl(rawCurl, networkPolicy)
        var handedOffCredential: ByteArray? = null
        var wroteNewCredential = false
        try {
            handedOffCredential = inspection.credentialHandoffId?.let { handoffId ->
                checkNotNull(coreClient.takeProviderCurlCredential(handoffId)) {
                    "The cURL credential handoff expired or was already consumed."
                }
            }
            if (handedOffCredential != null) {
                check(
                    snapshot.credentialSlotExpected &&
                        snapshot.credentialSlotId == snapshot.pendingConnectionId,
                ) {
                    "This keyless discovery cannot adopt a supplemental cURL credential. " +
                        "Restart setup with the cURL source."
                }
                when (credentialStore.inspect(snapshot.pendingConnectionId)) {
                    CredentialRecordStatus.Missing -> {
                        credentialStore.writeBytes(
                            snapshot.pendingConnectionId,
                            handedOffCredential,
                        )
                        wroteNewCredential = true
                    }
                    CredentialRecordStatus.Available -> error(
                        "A credential already exists for this discovery. " +
                            "Replacing it requires restarting setup and explicit confirmation.",
                    )
                    CredentialRecordStatus.Unreadable -> error(
                        "The existing discovery credential cannot be decrypted. " +
                            "Restart setup before supplying another credential.",
                    )
                }
            }
            coreClient.supplyProviderDiscoveryCurlEvidence(
                sessionId = snapshot.sessionId,
                expectedRevision = snapshot.revision,
                rawCurl = inspection.redactedCurl,
            ).also(::validateDiscoverySlot)
        } catch (cancellation: CancellationException) {
            rollbackSupplementalCredential(
                snapshot.pendingConnectionId,
                wroteNewCredential,
                cancellation,
            )
            throw cancellation
        } catch (error: Throwable) {
            rollbackSupplementalCredential(
                snapshot.pendingConnectionId,
                wroteNewCredential,
                error,
            )
            throw error
        } finally {
            handedOffCredential?.fill(0)
        }
    }

    suspend fun cancelDiscovery(
        snapshot: ProviderDiscoverySnapshot,
    ): ProviderDiscoverySnapshot = PROCESS_MUTATION_MUTEX.withLock {
        validateDiscoverySlot(snapshot)
        val cancelled = coreClient.cancelProviderDiscovery(
            snapshot.sessionId,
            snapshot.revision,
        )
        validateDiscoverySlot(cancelled)
        cleanupTerminalDiscoveryCredential(cancelled)
        cancelled
    }

    suspend fun commitDiscovery(
        snapshot: ProviderDiscoverySnapshot,
    ): ProviderConnection = PROCESS_MUTATION_MUTEX.withLock {
        validateDiscoverySlot(snapshot)
        val credentialConfirmed = if (snapshot.credentialSlotExpected) {
            credentialStore.inspect(snapshot.pendingConnectionId) ==
                CredentialRecordStatus.Available
        } else {
            false
        }
        coreClient.commitProviderDiscovery(
            sessionId = snapshot.sessionId,
            credentialReferenceConfirmed = credentialConfirmed,
        )
    }

    suspend fun reconcileDiscoveryCredential(snapshot: ProviderDiscoverySnapshot) =
        PROCESS_MUTATION_MUTEX.withLock {
            validateDiscoverySlot(snapshot)
            cleanupTerminalDiscoveryCredential(snapshot)
        }

    /**
     * Continues the durable compensation recipe until Core reaches a native
     * credential deletion step, performs exactly that typed deletion, and
     * reports the verified result before Core continues its database steps.
     *
     * A process death after the step is claimed is intentionally not retried
     * here. Core recovery moves that persistent effect to unknown-outcome
     * reconciliation instead.
     */
    suspend fun reconcileDiscoveryCompensation(
        snapshot: ProviderDiscoverySnapshot,
    ): ProviderDiscoverySnapshot = PROCESS_MUTATION_MUTEX.withLock {
        validateDiscoverySlot(snapshot)
        var current = snapshot
        if (current.state != "compensating" || current.failure != null) {
            cleanupTerminalDiscoveryCredential(current)
            return@withLock current
        }
        current = driveAlreadyLockedCompensation(current)
        cleanupTerminalDiscoveryCredential(current)
        current
    }

    suspend fun resumeDiscoveryCompensation(
        snapshot: ProviderDiscoverySnapshot,
    ): ProviderDiscoverySnapshot = PROCESS_MUTATION_MUTEX.withLock {
        validateDiscoverySlot(snapshot)
        var current = if (snapshot.failure != null) {
            coreClient.resumeProviderDiscoveryCompensation(snapshot.sessionId)
        } else {
            snapshot
        }
        if (current.state != "compensating" || current.failure != null) {
            cleanupTerminalDiscoveryCredential(current)
            return@withLock current
        }
        current = driveAlreadyLockedCompensation(current)
        cleanupTerminalDiscoveryCredential(current)
        current
    }

    suspend fun createConnection(
        draft: ProviderConnectionDraft,
        credential: String?,
    ): ProviderConnection = PROCESS_MUTATION_MUTEX.withLock {
        withContext(NonCancellable) {
            val normalizedCredential = credential?.takeIf(String::isNotBlank)
            if (draft.approvedCredentialOrigin != null) {
                requireNotNull(normalizedCredential) {
                    "A credential is required for the approved credential origin."
                }
            } else {
                require(normalizedCredential == null) {
                    "A credential-free connection cannot store a credential."
                }
            }

            val previous = credentialStore.read(draft.id)
            check(previous == null) {
                "The new provider connection ID is already bound to a credential."
            }
            var credentialChanged = false
            try {
                if (normalizedCredential != null) {
                    credentialStore.write(draft.id, normalizedCredential)
                    credentialChanged = true
                }
                coreClient.createProviderConnection(draft)
            } catch (cancellation: CancellationException) {
                if (credentialChanged) {
                    rollbackCredential(draft.id, previous, cancellation)
                }
                throw cancellation
            } catch (error: Throwable) {
                if (credentialChanged) {
                    rollbackCredential(draft.id, previous, error)
                }
                throw error
            }
        }
    }

    suspend fun updateConnection(
        original: ProviderConnection,
        updated: ProviderConnection,
        replacementCredential: String?,
    ): ProviderConnection = PROCESS_MUTATION_MUTEX.withLock {
        withContext(NonCancellable) {
            require(replacementCredential.isNullOrBlank()) {
                "An existing provider credential cannot be replaced under the same " +
                    "connection ID. Create a new provider connection so provider-native " +
                    "reasoning state cannot cross account boundaries."
            }
            check(updated == original.copy(displayName = updated.displayName)) {
                "Existing provider endpoint and connection configuration are immutable. " +
                    "Create a new provider connection for configuration changes."
            }
            coreClient.upsertProviderConnection(updated)
        }
    }

    suspend fun deleteConnection(connection: ProviderConnection) =
        PROCESS_MUTATION_MUTEX.withLock {
            withContext(NonCancellable) {
                if (!connection.credentialSlotReady) {
                    coreClient.deleteProviderConnection(connection.id)
                    return@withContext
                }
                val credentialRef = connection.id

                val status = credentialStore.inspect(credentialRef)
                if (status != CredentialRecordStatus.Available) {
                    coreClient.deleteProviderConnection(connection.id)
                    credentialStore.delete(credentialRef)
                    return@withContext
                }
                val previous = credentialStore.read(credentialRef)
                try {
                    credentialStore.delete(credentialRef)
                    coreClient.deleteProviderConnection(connection.id)
                } catch (cancellation: CancellationException) {
                    rollbackCredential(credentialRef, previous, cancellation)
                    throw cancellation
                } catch (error: Throwable) {
                    rollbackCredential(credentialRef, previous, error)
                    throw error
                }
            }
        }

    private suspend fun rollbackCredential(
        credentialRef: String,
        previous: String?,
        originalError: Throwable,
    ) {
        withContext(NonCancellable) {
            try {
                if (previous == null) {
                    credentialStore.delete(credentialRef)
                } else {
                    credentialStore.write(credentialRef, previous)
                }
            } catch (rollbackError: Throwable) {
                originalError.addSuppressed(rollbackError)
            }
        }
    }

    private suspend fun requireCredentialSlotIsUnused(connectionId: String) {
        check(credentialStore.inspect(connectionId) == CredentialRecordStatus.Missing) {
            "The new provider connection ID is already bound to a credential record."
        }
    }

    private suspend fun readDiscoveryCredential(snapshot: ProviderDiscoverySnapshot): String {
        check(snapshot.credentialSlotExpected) {
            "This discovery action requires a credential, but no credential slot was declared."
        }
        check(snapshot.credentialSlotId == snapshot.pendingConnectionId) {
            "The discovery credential slot does not match the pending connection."
        }
        check(
            credentialStore.inspect(snapshot.pendingConnectionId) ==
                CredentialRecordStatus.Available,
        ) {
            "The provider credential is missing or cannot be decrypted."
        }
        return checkNotNull(credentialStore.read(snapshot.pendingConnectionId)) {
            "The provider credential disappeared while preparing the request."
        }
    }

    private fun validateDiscoverySlot(snapshot: ProviderDiscoverySnapshot) {
        check(snapshot.pendingConnectionId.isNotBlank()) {
            "The discovery snapshot has no pending connection identity."
        }
        if (snapshot.credentialSlotExpected) {
            check(snapshot.credentialSlotId == snapshot.pendingConnectionId) {
                "The discovery snapshot contains a cross-wired credential slot."
            }
        } else {
            check(snapshot.credentialSlotId == null) {
                "The discovery snapshot exposes an unexpected credential slot."
            }
        }
    }

    private suspend fun cleanupTerminalDiscoveryCredential(
        snapshot: ProviderDiscoverySnapshot,
    ) {
        if (
            snapshot.credentialSlotExpected &&
            snapshot.state in setOf("failed", "cancelled")
        ) {
            if (
                credentialStore.inspect(snapshot.pendingConnectionId) !=
                CredentialRecordStatus.Missing
            ) {
                credentialStore.delete(snapshot.pendingConnectionId)
            }
        }
    }

    private suspend fun driveAlreadyLockedCompensation(
        initial: ProviderDiscoverySnapshot,
    ): ProviderDiscoverySnapshot {
        var current = initial
        while (current.state == "compensating" && current.failure == null) {
            current = coreClient.continueProviderDiscoveryCompensation(current.sessionId)
            if (current.state != "compensating" || current.failure != null) break
            val attemptId = checkNotNull(current.commitAttemptId) {
                "Compensating discovery has no immutable commit attempt."
            }
            val step = coreClient
                .listProviderDiscoveryCompensationSteps(attemptId)
                .firstOrNull { candidate ->
                    candidate.kind == DiscoveryCompensationKind.RemoveCredentialSlot &&
                        candidate.status != DiscoveryCompensationStatus.Completed
                }
            if (step == null) continue
            if (
                step.status == DiscoveryCompensationStatus.Failed ||
                step.status == DiscoveryCompensationStatus.OutcomeUnknown
            ) {
                break
            }
            if (step.status == DiscoveryCompensationStatus.InProgress) {
                // A previous process may have performed the vault deletion and
                // died before recording its result. Repeating that persistent
                // native effect would invent an outcome, so move the durable
                // state to explicit reconciliation instead.
                current = coreClient.markProviderDiscoveryCredentialCompensationUnknown(
                    sessionId = current.sessionId,
                    stepId = step.id,
                )
                break
            }
            val claimed = coreClient.startProviderDiscoveryCredentialCompensation(
                sessionId = current.sessionId,
                stepId = step.id,
            )
            val target = claimed.target as? DiscoveryCompensationTarget.RemoveCredentialSlot
                ?: error("Core returned a non-credential target for native compensation.")
            check(claimed.status == DiscoveryCompensationStatus.InProgress) {
                "Native credential compensation was not durably claimed."
            }
            validateCredentialCompensationTarget(current, target)
            current = withContext(NonCancellable) {
                completeCredentialDeletion(current, claimed.id, target)
            }
        }
        return current
    }

    private fun validateCredentialCompensationTarget(
        snapshot: ProviderDiscoverySnapshot,
        target: DiscoveryCompensationTarget.RemoveCredentialSlot,
    ) {
        check(snapshot.credentialSlotExpected) {
            "Core requested credential compensation for a keyless discovery."
        }
        check(snapshot.credentialSlotId == snapshot.pendingConnectionId) {
            "Discovery credential metadata is not bound to its pending connection."
        }
        check(
            target.connectionId == snapshot.pendingConnectionId &&
                target.credentialRef == snapshot.pendingConnectionId,
        ) {
            "Credential compensation target is not the exact pending connection slot."
        }
    }

    private suspend fun completeCredentialDeletion(
        snapshot: ProviderDiscoverySnapshot,
        stepId: String,
        target: DiscoveryCompensationTarget.RemoveCredentialSlot,
    ): ProviderDiscoverySnapshot {
        val deletionError = runCatching {
            credentialStore.delete(target.credentialRef)
        }.exceptionOrNull()
        val status = runCatching {
            credentialStore.inspect(target.credentialRef)
        }.getOrNull()
        return when (status) {
            CredentialRecordStatus.Missing ->
                coreClient.completeProviderDiscoveryCredentialCompensation(
                    sessionId = snapshot.sessionId,
                    stepId = stepId,
                )
            CredentialRecordStatus.Available,
            CredentialRecordStatus.Unreadable,
            -> coreClient.failProviderDiscoveryCredentialCompensation(
                sessionId = snapshot.sessionId,
                stepId = stepId,
                failure = DiscoveryFailure(
                    code = "native_credential_delete_failed",
                    messageKey = "provider.discovery.native_credential_delete_failed",
                    recoverable = true,
                ),
            )
            null -> {
                // Neither success nor failure can be proven. Never retry the
                // native side effect automatically.
                deletionError?.let { _ -> Unit }
                coreClient.markProviderDiscoveryCredentialCompensationUnknown(
                    sessionId = snapshot.sessionId,
                    stepId = stepId,
                )
            }
        }
    }

    private suspend fun rollbackNewDiscoverySlot(
        connectionId: String,
        credentialWasWritten: Boolean,
        originalError: Throwable,
    ) {
        if (!credentialWasWritten) return
        withContext(NonCancellable) {
            try {
                credentialStore.delete(connectionId)
            } catch (rollbackError: Throwable) {
                originalError.addSuppressed(rollbackError)
            }
        }
    }

    private suspend fun rollbackSupplementalCredential(
        connectionId: String,
        credentialWasWritten: Boolean,
        originalError: Throwable,
    ) {
        if (!credentialWasWritten) return
        withContext(NonCancellable) {
            try {
                credentialStore.delete(connectionId)
            } catch (rollbackError: Throwable) {
                originalError.addSuppressed(rollbackError)
            }
        }
    }

    private companion object {
        /**
         * One Settings destination is not the process boundary: saved
         * back-stack entries can own multiple ViewModels/coordinators. Keep
         * each cross-store mutation serialized across all of them.
         */
        val PROCESS_MUTATION_MUTEX = Mutex()
    }
}
