package dev.lorepia.app.ui.navigation

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.navArgument
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.lorepia.app.bridge.CoreClient
import dev.lorepia.app.feature.chat.ChatRoute
import dev.lorepia.app.feature.importreview.ImportReviewRoute
import dev.lorepia.app.feature.library.LibraryRoute
import dev.lorepia.app.feature.settings.SettingsRoute
import dev.lorepia.app.platform.files.StagedDocument
import dev.lorepia.app.platform.paths.AppDirectories

@Composable
fun LorepiaNavHost(
    navController: NavHostController,
    coreClient: CoreClient,
    contentPadding: PaddingValues,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    NavHost(
        navController = navController,
        startDestination = Destination.Library.route,
        modifier = modifier,
    ) {
        composable(Destination.Library.route) { entry ->
            val refreshSignal by entry.savedStateHandle
                .getStateFlow(IMPORT_REFRESH_KEY, 0)
                .collectAsStateWithLifecycle()
            LibraryRoute(
                coreClient = coreClient,
                contentPadding = contentPadding,
                refreshSignal = refreshSignal,
                onReviewImport = { document ->
                    navController.navigate(Destination.ImportReview.routeFor(document))
                },
            )
        }
        composable(Destination.Chat.route) {
            ChatRoute(
                coreClient = coreClient,
                contentPadding = contentPadding,
                onOpenLibrary = {
                    navController.navigate(Destination.Library.route) {
                        popUpTo(navController.graph.findStartDestination().id) {
                            saveState = true
                        }
                        launchSingleTop = true
                        restoreState = true
                    }
                },
            )
        }
        composable(Destination.Settings.route) {
            SettingsRoute(
                coreClient = coreClient,
                contentPadding = contentPadding,
            )
        }
        composable(
            route = Destination.ImportReview.route,
            arguments = listOf(
                navArgument(Destination.ImportReview.PATH_ARGUMENT) {
                    type = NavType.StringType
                },
                navArgument(Destination.ImportReview.NAME_ARGUMENT) {
                    type = NavType.StringType
                },
                navArgument(Destination.ImportReview.SIZE_ARGUMENT) {
                    type = NavType.LongType
                },
            ),
        ) { entry ->
            val path = requireNotNull(
                entry.arguments?.getString(Destination.ImportReview.PATH_ARGUMENT),
            )
            val name = requireNotNull(
                entry.arguments?.getString(Destination.ImportReview.NAME_ARGUMENT),
            )
            val size = entry.arguments?.getLong(Destination.ImportReview.SIZE_ARGUMENT) ?: 0L
            ImportReviewRoute(
                coreClient = coreClient,
                document = StagedDocument(
                    path = path,
                    displayName = name,
                    sizeBytes = size,
                ),
                stagingDirectory = AppDirectories.create(context).staging,
                contentPadding = contentPadding,
                onImported = {
                    val previous = navController.previousBackStackEntry
                    val nextSignal = (
                        previous?.savedStateHandle?.get<Int>(IMPORT_REFRESH_KEY) ?: 0
                    ) + 1
                    previous?.savedStateHandle?.set(IMPORT_REFRESH_KEY, nextSignal)
                    navController.popBackStack()
                },
                onNavigateBack = navController::popBackStack,
            )
        }
    }
}

private const val IMPORT_REFRESH_KEY = "import-refresh"
