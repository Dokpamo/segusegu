package dev.lorepia.app.platform.files

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember

/**
 * Opens Android's Storage Access Framework without asking for broad storage
 * permission. Package type validation remains the Rust core's responsibility.
 */
@Composable
fun rememberCharacterDocumentPicker(
    onDocumentPicked: (Uri?) -> Unit,
): () -> Unit {
    val launcher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument(),
        onResult = onDocumentPicked,
    )
    return remember(launcher) {
        {
            launcher.launch(arrayOf("*/*"))
        }
    }
}
