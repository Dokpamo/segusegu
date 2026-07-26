package dev.lorepia.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import dev.lorepia.app.app.LorepiaApp

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        val application = application as LorepiaApplication
        setContent {
            LorepiaApp(
                coreClientFactory = application::openCoreClient,
                releaseCoreClient = {},
            )
        }
    }
}
