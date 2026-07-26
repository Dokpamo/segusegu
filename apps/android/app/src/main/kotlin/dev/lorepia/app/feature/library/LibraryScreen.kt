package dev.lorepia.app.feature.library

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import dev.lorepia.app.R
import dev.lorepia.app.bridge.CharacterSummary

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LibraryScreen(
    uiState: LibraryUiState,
    isStaging: Boolean,
    stagingError: Boolean,
    onImport: () -> Unit,
    onRetry: () -> Unit,
    contentPadding: PaddingValues,
    modifier: Modifier = Modifier,
) {
    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                windowInsets = WindowInsets(0, 0, 0, 0),
                title = {
                    Text(
                        text = stringResource(R.string.library_title),
                        modifier = Modifier.semantics { heading() },
                    )
                },
            )
        },
    ) { scaffoldPadding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(scaffoldPadding)
                .padding(contentPadding)
                .padding(horizontal = 24.dp),
            contentAlignment = Alignment.Center,
        ) {
            when (uiState) {
                LibraryUiState.Loading -> CircularProgressIndicator(
                    modifier = Modifier.semantics {
                        liveRegion = LiveRegionMode.Polite
                    },
                )

                is LibraryUiState.Empty -> EmptyLibrary(
                    isStaging = isStaging,
                    stagingError = stagingError,
                    onImport = onImport,
                )

                is LibraryUiState.Content -> LibraryContent(
                    characters = uiState.characters,
                    isStaging = isStaging,
                    stagingError = stagingError,
                    onImport = onImport,
                )

                is LibraryUiState.Error -> ErrorContent(onRetry)
            }
        }
    }
}

@Composable
private fun LibraryContent(
    characters: List<CharacterSummary>,
    isStaging: Boolean,
    stagingError: Boolean,
    onImport: () -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxSize(),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            text = stringResource(R.string.character_count, characters.size),
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.semantics { heading() },
        )
        Button(
            onClick = onImport,
            enabled = !isStaging,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Icon(
                imageVector = Icons.Outlined.Add,
                contentDescription = null,
            )
            Text(
                text = if (isStaging) {
                    stringResource(R.string.staging_file)
                } else {
                    stringResource(R.string.import_character)
                },
                modifier = Modifier.padding(start = 8.dp),
            )
        }
        if (stagingError) {
            Text(
                text = stringResource(R.string.staging_failed),
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier.semantics {
                    liveRegion = LiveRegionMode.Assertive
                },
            )
        }
        LazyColumn(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            items(
                items = characters,
                key = CharacterSummary::id,
            ) { character ->
                CharacterCard(character)
            }
        }
    }
}

@Composable
private fun CharacterCard(character: CharacterSummary) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                text = character.name,
                style = MaterialTheme.typography.titleMedium,
            )
            if (character.description.isNotBlank()) {
                Text(
                    text = character.description,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun EmptyLibrary(
    isStaging: Boolean,
    stagingError: Boolean,
    onImport: () -> Unit,
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            text = stringResource(R.string.library_empty_title),
            style = MaterialTheme.typography.headlineSmall,
            textAlign = TextAlign.Center,
            modifier = Modifier.semantics { heading() },
        )
        Text(
            text = stringResource(R.string.library_empty_body),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        Button(
            onClick = onImport,
            enabled = !isStaging,
        ) {
            Icon(
                imageVector = Icons.Outlined.Add,
                contentDescription = null,
            )
            Text(
                text = if (isStaging) {
                    stringResource(R.string.staging_file)
                } else {
                    stringResource(R.string.import_character)
                },
                modifier = Modifier.padding(start = 8.dp),
            )
        }
        if (stagingError) {
            Text(
                text = stringResource(R.string.staging_failed),
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier.semantics {
                    liveRegion = LiveRegionMode.Assertive
                },
            )
        }
    }
}

@Composable
private fun ErrorContent(onRetry: () -> Unit) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            text = stringResource(R.string.core_unavailable_title),
            style = MaterialTheme.typography.titleLarge,
            textAlign = TextAlign.Center,
            modifier = Modifier.semantics { heading() },
        )
        Text(
            text = stringResource(R.string.core_unavailable_body),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        TextButton(onClick = onRetry) {
            Icon(
                imageVector = Icons.Outlined.Refresh,
                contentDescription = null,
            )
            Text(
                text = stringResource(R.string.retry),
                modifier = Modifier.padding(start = 8.dp),
            )
        }
    }
}
