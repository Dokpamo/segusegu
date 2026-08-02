package dev.lorepia.app.feature.settings

import dev.lorepia.app.FakeCoreClient
import dev.lorepia.app.FakeCredentialStore
import dev.lorepia.app.bridge.AuthBinding
import dev.lorepia.app.bridge.CredentialRedirectPolicy
import dev.lorepia.app.bridge.CredentialScope
import dev.lorepia.app.bridge.DiscoveryCompensationKind
import dev.lorepia.app.bridge.DiscoveryCompensationStatus
import dev.lorepia.app.bridge.DiscoveryCompensationStep
import dev.lorepia.app.bridge.DiscoveryCompensationTarget
import dev.lorepia.app.bridge.ProviderDiscoveryConnectionOptions
import dev.lorepia.app.bridge.ProviderDiscoveryInput
import dev.lorepia.app.bridge.ProviderDiscoverySource
import dev.lorepia.app.bridge.ProviderConnection
import dev.lorepia.app.bridge.ProviderLocalNetworkApproval
import dev.lorepia.app.bridge.ProviderNetworkMode
import dev.lorepia.app.bridge.ProviderNetworkPolicy
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProviderCredentialCoordinatorTest {
    @Test
    fun `supplemental curl consumes one-shot credential into exact declared slot`() = runTest {
        val secret = "synthetic-one-shot-secret"
        val core = FakeCoreClient(curlInspectionCredential = secret.toByteArray())
        val store = FakeCredentialStore()
        val coordinator = ProviderCredentialCoordinator(core, store)
        val snapshot = core.beginProviderDiscovery(
            input = discoveryInput("connection-exact", credentialSlotReady = true),
            source = ProviderDiscoverySource.Site,
            rawCurl = null,
        )

        val updated = coordinator.supplyCurlEvidence(
            snapshot = snapshot,
            rawCurl = "curl -H 'Authorization: Bearer $secret' https://raw.invalid",
            networkPolicy = publicNetworkPolicy(),
        )

        assertEquals(secret, store.values["connection-exact"])
        assertEquals(1, core.inspectProviderCurlCalls)
        assertEquals(1, core.takeProviderCurlCredentialCalls)
        assertEquals(
            "curl https://api.example.invalid/v1/chat/completions",
            core.lastSuppliedDiscoveryCurl,
        )
        assertFalse(core.lastSuppliedDiscoveryCurl.orEmpty().contains(secret))
        assertEquals(snapshot.revision + 1uL, updated.revision)
    }

    @Test
    fun `supplemental curl credential cannot upgrade keyless discovery`() = runTest {
        val core = FakeCoreClient(
            curlInspectionCredential = "must-not-persist".toByteArray(),
        )
        val store = FakeCredentialStore()
        val coordinator = ProviderCredentialCoordinator(core, store)
        val snapshot = core.beginProviderDiscovery(
            input = discoveryInput("connection-keyless", credentialSlotReady = false),
            source = ProviderDiscoverySource.Site,
            rawCurl = null,
        )

        val failure = runCatching {
            coordinator.supplyCurlEvidence(
                snapshot = snapshot,
                rawCurl = "curl https://raw.invalid",
                networkPolicy = publicNetworkPolicy(),
            )
        }.exceptionOrNull()

        assertTrue(failure is IllegalStateException)
        assertTrue(store.values.isEmpty())
        assertTrue(store.operations.isEmpty())
        assertNull(core.lastSuppliedDiscoveryCurl)
        assertEquals(1, core.takeProviderCurlCredentialCalls)
    }

    @Test
    fun `supplemental curl never overwrites an existing credential implicitly`() = runTest {
        val core = FakeCoreClient(
            curlInspectionCredential = "replacement-secret".toByteArray(),
        )
        val store = FakeCredentialStore().apply {
            values["connection-existing"] = "approved-existing-secret"
        }
        val coordinator = ProviderCredentialCoordinator(core, store)
        val snapshot = core.beginProviderDiscovery(
            input = discoveryInput("connection-existing", credentialSlotReady = true),
            source = ProviderDiscoverySource.Site,
            rawCurl = null,
        )

        val failure = runCatching {
            coordinator.supplyCurlEvidence(
                snapshot = snapshot,
                rawCurl = "curl https://raw.invalid",
                networkPolicy = publicNetworkPolicy(),
            )
        }.exceptionOrNull()

        assertTrue(failure is IllegalStateException)
        assertEquals("approved-existing-secret", store.values["connection-existing"])
        assertTrue(store.operations.isEmpty())
        assertNull(core.lastSuppliedDiscoveryCurl)
    }

    @Test
    fun `existing connection credential replacement is rejected before vault access`() = runTest {
        val connection = existingConnection()
        val core = FakeCoreClient(
            providerConnections = mutableListOf(connection),
        )
        val store = FakeCredentialStore().apply {
            values[connection.id] = "approved-existing-secret"
        }
        val coordinator = ProviderCredentialCoordinator(core, store)

        val failure = runCatching {
            coordinator.updateConnection(
                original = connection,
                updated = connection.copy(displayName = "Renamed"),
                replacementCredential = "different-account-secret",
            )
        }.exceptionOrNull()

        assertTrue(failure is IllegalArgumentException)
        assertTrue(failure?.message.orEmpty().contains("new provider connection"))
        assertEquals("approved-existing-secret", store.values[connection.id])
        assertTrue(store.operations.isEmpty())
        assertTrue(core.providerMutationOrder.isEmpty())
    }

    @Test
    fun `existing connection endpoint configuration is immutable`() = runTest {
        val connection = existingConnection()
        val core = FakeCoreClient(
            providerConnections = mutableListOf(connection),
        )
        val store = FakeCredentialStore()
        val coordinator = ProviderCredentialCoordinator(core, store)

        val failure = runCatching {
            coordinator.updateConnection(
                original = connection,
                updated = connection.copy(timeoutSeconds = connection.timeoutSeconds + 1u),
                replacementCredential = null,
            )
        }.exceptionOrNull()

        assertTrue(failure is IllegalStateException)
        assertTrue(failure?.message.orEmpty().contains("configuration are immutable"))
        assertTrue(store.operations.isEmpty())
        assertTrue(core.providerMutationOrder.isEmpty())
    }

    @Test
    fun `blank replacement retains credential and permits display name only`() = runTest {
        val connection = existingConnection()
        val core = FakeCoreClient(
            providerConnections = mutableListOf(connection),
        )
        val store = FakeCredentialStore().apply {
            values[connection.id] = "approved-existing-secret"
        }
        val coordinator = ProviderCredentialCoordinator(core, store)

        val updated = coordinator.updateConnection(
            original = connection,
            updated = connection.copy(displayName = "Renamed"),
            replacementCredential = " ",
        )

        assertEquals("Renamed", updated.displayName)
        assertEquals("approved-existing-secret", store.values[connection.id])
        assertTrue(store.operations.isEmpty())
        assertEquals(listOf("core:update:${connection.id}"), core.providerMutationOrder)
    }

    @Test
    fun `restart with in-progress native compensation becomes unknown without retry`() = runTest {
        val connectionId = "connection-restart"
        val core = FakeCoreClient()
        val store = FakeCredentialStore().apply {
            values[connectionId] = "possibly-already-deleted-secret"
        }
        val initial = core.beginProviderDiscovery(
            input = discoveryInput(connectionId, credentialSlotReady = true),
            source = ProviderDiscoverySource.Site,
            rawCurl = null,
        )
        val attemptId = checkNotNull(initial.commitAttemptId)
        val compensating = initial.copy(
            state = "compensating",
            activeOperationId = "compensation-operation",
            recoveryOperation = "compensation",
            actionRequired = null,
            failure = null,
        )
        core.providerDiscoveries[initial.sessionId] = compensating
        core.providerDiscoveryCompensationSteps[attemptId] = mutableListOf(
            credentialCompensationStep(
                snapshot = compensating,
                attemptId = attemptId,
                status = DiscoveryCompensationStatus.InProgress,
            ),
        )

        val restartedCoordinator = ProviderCredentialCoordinator(core, store)
        val reconciled = restartedCoordinator.reconcileDiscoveryCompensation(compensating)

        assertEquals("unknown_outcome", reconciled.state)
        assertEquals(
            DiscoveryCompensationStatus.OutcomeUnknown,
            core.providerDiscoveryCompensationSteps.getValue(attemptId).single().status,
        )
        assertTrue(store.operations.isEmpty())
        assertEquals(
            "possibly-already-deleted-secret",
            store.values[connectionId],
        )
    }

    @Test
    fun `unverifiable vault deletion is marked unknown and is not automatically retried`() =
        runTest {
            val connectionId = "connection-unknown"
            val core = FakeCoreClient()
            val store = FakeCredentialStore().apply {
                values[connectionId] = "synthetic-secret"
                deleteError = IllegalStateException("keystore result lost")
                inspectError = IllegalStateException("keystore unavailable")
            }
            val initial = core.beginProviderDiscovery(
                input = discoveryInput(connectionId, credentialSlotReady = true),
                source = ProviderDiscoverySource.Site,
                rawCurl = null,
            )
            val attemptId = checkNotNull(initial.commitAttemptId)
            val compensating = initial.copy(
                state = "compensating",
                activeOperationId = "compensation-operation",
                recoveryOperation = "compensation",
                actionRequired = null,
                failure = null,
            )
            core.providerDiscoveries[initial.sessionId] = compensating
            core.providerDiscoveryCompensationSteps[attemptId] = mutableListOf(
                credentialCompensationStep(
                    snapshot = compensating,
                    attemptId = attemptId,
                    status = DiscoveryCompensationStatus.Pending,
                ),
            )
            val coordinator = ProviderCredentialCoordinator(core, store)

            val unknown = coordinator.reconcileDiscoveryCompensation(compensating)
            val secondPass = coordinator.reconcileDiscoveryCompensation(unknown)

            assertEquals("unknown_outcome", unknown.state)
            assertEquals("unknown_outcome", secondPass.state)
            assertEquals(
                1,
                store.operations.count { it == "credential:delete:$connectionId" },
            )
        }
}

private fun discoveryInput(
    connectionId: String,
    credentialSlotReady: Boolean,
): ProviderDiscoveryInput = ProviderDiscoveryInput(
    connectionId = connectionId,
    displayName = "Synthetic provider",
    siteUrl = "https://api.example.invalid",
    docsUrl = null,
    credentialSlotReady = credentialSlotReady,
    preferredAssistantModelRouteId = null,
    connectionOptions = ProviderDiscoveryConnectionOptions(
        values = emptyList(),
        apiBasePath = null,
        timeoutSeconds = 30u,
        networkMode = ProviderNetworkMode.Public,
        localNetworkApproval = null,
    ),
)

private fun publicNetworkPolicy(): ProviderNetworkPolicy = ProviderNetworkPolicy(
    networkMode = ProviderNetworkMode.Public,
    localNetworkApproval = null,
)

private fun existingConnection(): ProviderConnection = ProviderConnection(
    id = "connection-existing",
    templateId = "template-existing",
    templateVersion = 1u,
    displayName = "Existing",
    apiOrigin = "https://api.example.invalid",
    apiBasePath = "/v1",
    networkMode = ProviderNetworkMode.Public,
    values = emptyList(),
    credentialSlotReady = true,
    credentialScope = CredentialScope(
        allowedOrigins = listOf("https://api.example.invalid"),
        authBinding = AuthBinding.BearerHeader,
        redirectPolicy = CredentialRedirectPolicy.Deny,
    ),
    approvedCredentialOrigins = listOf("https://api.example.invalid"),
    timeoutSeconds = 60u,
    status = "connected",
    createdAt = "2026-01-01T00:00:00Z",
    updatedAt = "2026-01-01T00:00:00Z",
)

private fun credentialCompensationStep(
    snapshot: dev.lorepia.app.bridge.ProviderDiscoverySnapshot,
    attemptId: String,
    status: DiscoveryCompensationStatus,
): DiscoveryCompensationStep = DiscoveryCompensationStep(
    id = "credential-compensation-${snapshot.pendingConnectionId}",
    commitAttemptId = attemptId,
    ordinal = 2u,
    actionId = "credential-compensation-action",
    kind = DiscoveryCompensationKind.RemoveCredentialSlot,
    target = DiscoveryCompensationTarget.RemoveCredentialSlot(
        connectionId = snapshot.pendingConnectionId,
        credentialRef = snapshot.pendingConnectionId,
    ),
    status = status,
    attemptCount = if (status == DiscoveryCompensationStatus.InProgress) 1u else 0u,
    lastFailure = null,
    createdAt = "2026-01-01T00:00:00Z",
    updatedAt = "2026-01-01T00:00:00Z",
    completedAt = null,
)
