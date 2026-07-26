package dev.lorepia.app.ui.navigation

import android.net.Uri
import androidx.annotation.StringRes
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.ui.graphics.vector.ImageVector
import dev.lorepia.app.R
import dev.lorepia.app.platform.files.StagedDocument

sealed class Destination(
    val route: String,
    @StringRes val labelResource: Int,
) {
    sealed class Primary(
        route: String,
        @StringRes labelResource: Int,
        val icon: ImageVector,
    ) : Destination(route, labelResource)

    data object Library : Primary(
        route = "library",
        labelResource = R.string.library_title,
        icon = Icons.Outlined.Home,
    )

    data object Chat : Primary(
        route = "chat",
        labelResource = R.string.chat_title,
        icon = Icons.Outlined.ChatBubbleOutline,
    )

    data object Settings : Primary(
        route = "settings",
        labelResource = R.string.settings_title,
        icon = Icons.Outlined.Settings,
    )

    data object ImportReview : Destination(
        route = "import-review?path={path}&name={name}&size={size}",
        labelResource = R.string.import_review_title,
    ) {
        fun routeFor(document: StagedDocument): String =
            "import-review?$PATH_ARGUMENT=${Uri.encode(document.path)}" +
                "&$NAME_ARGUMENT=${Uri.encode(document.displayName)}" +
                "&$SIZE_ARGUMENT=${document.sizeBytes}"

        const val PATH_ARGUMENT = "path"
        const val NAME_ARGUMENT = "name"
        const val SIZE_ARGUMENT = "size"
    }

    data object ChatSession : Destination(
        route = "chat-session?characterId={characterId}&conversationId={conversationId}",
        labelResource = R.string.chat_title,
    ) {
        fun forCharacter(characterId: String): String =
            "chat-session?$CHARACTER_ARGUMENT=${Uri.encode(characterId)}"

        fun forConversation(conversationId: String): String =
            "chat-session?$CONVERSATION_ARGUMENT=${Uri.encode(conversationId)}"

        const val CHARACTER_ARGUMENT = "characterId"
        const val CONVERSATION_ARGUMENT = "conversationId"
    }

    companion object {
        val primaryDestinations: List<Primary> = listOf(Library, Chat, Settings)
    }
}
