package io.github.ccch1mneyyy.dsh_app.runtime

import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.IBinder

/**
 * The on-device engine is gone: this fork is remote-only (SSH / relay), so
 * this service never runs. It stays as a manifest-registered stub — the
 * notification actions that used to stop the local engine now resolve to
 * no-ops, and [isRunning] is always false.
 */
class DshService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        stopSelf()
        return START_NOT_STICKY
    }

    companion object {
        const val ACTION_INSTALL = "io.github.ccch1mneyyy.dsh_app.INSTALL"
        const val ACTION_INSTALL_DONE = "io.github.ccch1mneyyy.dsh_app.INSTALL_DONE"
        const val ACTION_START = "io.github.ccch1mneyyy.dsh_app.START"
        const val ACTION_STOP = "io.github.ccch1mneyyy.dsh_app.STOP"
        const val ACTION_PHONE_STOP = "io.github.ccch1mneyyy.dsh_app.PHONE_STOP"
        private const val PHONE_TASK_SCHEME = "dsh-phone-task"
        private const val EXTRA_STOP_GENERATION = "stopGeneration"

        /** With [ACTION_INSTALL_DONE]: the unpack finished (true) or stopped. */
        const val EXTRA_INSTALL_OK = "ok"

        /** The service is in the foreground (so the controller may start DSH directly). */
        val isRunning: Boolean get() = false

        /** No notification to update: the service never runs. */
        fun updateNotification(context: Context) {}

        /** 停止操作 for exactly [taskId]. The id is the intent's data, so every task gets its own
         * PendingIntent: a newer task's button never rewrites the one still on screen. */
        fun phoneStopIntent(context: Context, taskId: Long): Intent = Intent(context, DshService::class.java)
            .setAction(ACTION_PHONE_STOP).setData(Uri.fromParts(PHONE_TASK_SCHEME, taskId.toString(), null))
    }
}
