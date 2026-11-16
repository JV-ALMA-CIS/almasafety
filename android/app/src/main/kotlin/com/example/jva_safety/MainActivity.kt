package com.example.jva_safety

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createNotificationChannel()
    }

    /**
     * The channel every ALMASAFETY push arrives on (the server sends
     * `channelId: "safety_alerts"`, and AndroidManifest.xml makes it the
     * default). HIGH importance so it pops up as a banner at the top of the
     * screen — with the phone's own default sound and vibration settings,
     * nothing custom or loud. People can still change or mute it in the
     * phone's app notification settings.
     */
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            "safety_alerts",
            "Safety alerts",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Things to check in ALMASAFETY: alerts, hazards, " +
                "incidents, corrective actions and reminders."
        }
        getSystemService(NotificationManager::class.java)
            ?.createNotificationChannel(channel)
    }
}
