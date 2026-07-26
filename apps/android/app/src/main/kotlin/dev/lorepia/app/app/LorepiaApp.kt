package dev.lorepia.app.app

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import dev.lorepia.app.R
import dev.lorepia.app.bridge.CoreClient
import dev.lorepia.app.platform.credentials.CredentialStore
import dev.lorepia.app.ui.navigation.Destination
import dev.lorepia.app.ui.navigation.LorepiaNavHost
import dev.lorepia.app.ui.theme.LorepiaTheme

@Composable
fun LorepiaApp(
    coreClientFactory: () -> CoreClient,
    credentialStore: CredentialStore,
    releaseCoreClient: (CoreClient) -> Unit = CoreClient::close,
) {
    LorepiaTheme {
        val appViewModel: AppViewModel = viewModel(
            factory = AppViewModel.factory(
                coreClientFactory = coreClientFactory,
                releaseCoreClient = releaseCoreClient,
            ),
        )
        val uiState by appViewModel.uiState.collectAsStateWithLifecycle()

        when (uiState) {
            AppUiState.Loading -> LoadingApp()
            is AppUiState.Error -> CoreUnavailable(onRetry = appViewModel::retry)
            is AppUiState.Ready -> {
                val coreClient = appViewModel.coreClient
                if (coreClient == null) {
                    CoreUnavailable(onRetry = appViewModel::retry)
                } else {
                    ConnectedApp(coreClient, credentialStore)
                }
            }
        }
    }
}

@Composable
private fun ConnectedApp(
    coreClient: CoreClient,
    credentialStore: CredentialStore,
) {
    val navController = rememberNavController()
    val backStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = backStackEntry?.destination?.route
    val showPrimaryNavigation = Destination.primaryDestinations.any {
        it.route == currentRoute
    }

    Scaffold(
        bottomBar = {
            if (showPrimaryNavigation) {
                NavigationBar {
                    Destination.primaryDestinations.forEach { destination ->
                        val label = stringResource(destination.labelResource)
                        NavigationBarItem(
                            selected = currentRoute == destination.route,
                            onClick = {
                                navController.navigate(destination.route) {
                                    popUpTo(navController.graph.findStartDestination().id) {
                                        saveState = true
                                    }
                                    launchSingleTop = true
                                    restoreState = true
                                }
                            },
                            icon = {
                                Icon(
                                    imageVector = destination.icon,
                                    contentDescription = null,
                                )
                            },
                            label = {
                                Text(label)
                            },
                            alwaysShowLabel = true,
                        )
                    }
                }
            }
        },
    ) { contentPadding ->
        LorepiaNavHost(
            navController = navController,
            coreClient = coreClient,
            credentialStore = credentialStore,
            contentPadding = contentPadding,
            modifier = Modifier.fillMaxSize(),
        )
    }
}

@Composable
private fun LoadingApp() {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        CircularProgressIndicator()
        Text(
            text = stringResource(R.string.loading),
            modifier = Modifier.padding(top = 16.dp),
        )
    }
}

@Composable
private fun CoreUnavailable(onRetry: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(
            text = stringResource(R.string.core_unavailable_title),
            style = MaterialTheme.typography.headlineSmall,
            textAlign = TextAlign.Center,
            modifier = Modifier.semantics { heading() },
        )
        Text(
            text = stringResource(R.string.core_unavailable_body),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = 8.dp, bottom = 16.dp),
        )
        Button(onClick = onRetry) {
            Text(stringResource(R.string.retry))
        }
    }
}
