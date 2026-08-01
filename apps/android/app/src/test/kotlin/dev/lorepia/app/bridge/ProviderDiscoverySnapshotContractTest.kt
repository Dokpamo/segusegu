package dev.lorepia.app.bridge

import dev.lorepia.app.FakeCoreClient
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertTrue
import org.junit.Test

class ProviderDiscoverySnapshotContractTest {
    @Test
    fun `snapshot schema drift fails closed`() = runTest {
        val snapshot = snapshot().copy(snapshotSchemaVersion = 2u)

        val failure = runCatching {
            validateProviderDiscoverySnapshotContract(snapshot)
        }.exceptionOrNull()

        assertTrue(failure is IllegalStateException)
        assertTrue(failure?.message.orEmpty().contains("schema version"))
    }

    @Test
    fun `snapshot network projection cannot infer missing LAN approval`() = runTest {
        val snapshot = snapshot().copy(
            connectionOptions = snapshot().connectionOptions.copy(
                networkMode = ProviderNetworkMode.ApprovedLocalNetwork,
                localNetworkApproval = null,
            ),
        )

        val failure = runCatching {
            validateProviderDiscoverySnapshotContract(snapshot)
        }.exceptionOrNull()

        assertTrue(failure is IllegalStateException)
        assertTrue(failure?.message.orEmpty().contains("network policy"))
    }
}

private suspend fun snapshot(): ProviderDiscoverySnapshot =
    FakeCoreClient().beginProviderDiscovery(
        input = ProviderDiscoveryInput(
            connectionId = "snapshot-contract-connection",
            displayName = "Snapshot contract provider",
            siteUrl = "https://api.example.invalid",
            docsUrl = null,
            credentialSlotReady = false,
            preferredAssistantModelRouteId = null,
            connectionOptions = ProviderDiscoveryConnectionOptions(
                values = emptyList(),
                apiBasePath = null,
                timeoutSeconds = 30u,
                networkMode = ProviderNetworkMode.Public,
                localNetworkApproval = null,
            ),
        ),
        source = ProviderDiscoverySource.Site,
        rawCurl = null,
    )
