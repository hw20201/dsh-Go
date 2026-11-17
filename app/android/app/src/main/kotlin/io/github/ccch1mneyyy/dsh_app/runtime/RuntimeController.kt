package io.github.ccch1mneyyy.dsh_app.runtime

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.github.ccch1mneyyy.dsh_app.phone.DiagnosticsTool
import io.github.ccch1mneyyy.dsh_app.phone.skills.PhoneSkillRoute
import java.io.File

/**
 * The on-device engine is gone: this fork is remote-only (SSH / relay), so
 * the PRoot guest, its installer and the DSH process no longer exist.
 *
 * What remains is the surface the phone-side features still compile against:
 * the phase vocabulary, the status sink registry, and the phone-skill bundle
 * facade. All of it now reports the engine as permanently unavailable, so a
 * phone-skill install or replay degrades to STALE / UNAVAILABLE instead of
 * touching a guest rootfs that is no longer there.
 */
class RuntimeController private constructor(private val app: Context) {

    enum class Phase(val wire: String) {
        NOT_INSTALLED("notInstalled"), INSTALLING("installing"), INSTALLED("installed"),
        STARTING("starting"), RUNNING("running"), STOPPING("stopping"), ERROR("error"),
    }

    fun interface EventSink {
        fun emit(event: Map<String, Any?>)
    }

    private val main = Handler(Looper.getMainLooper())
    private val sinks = LinkedHashSet<EventSink>()

    /** The engine never runs in this fork. */
    val phase: Phase = Phase.NOT_INSTALLED

    fun addSink(sink: EventSink) = synchronized(sinks) { sinks += sink }
    fun removeSink(sink: EventSink) = synchronized(sinks) { sinks -= sink }

    fun status(): Map<String, Any?> = mapOf(
        "phase" to phase.wire,
        "bundledVersion" to null,
        "installedVersion" to null,
        "dshVersion" to null,
        "nodeVersion" to null,
    )

    internal fun note(line: String) {
        Log.i(TAG, line)
    }

    /** No refresh source anymore: the diagnostics tool always reports unavailable. */
    val diagnosticsTool = DiagnosticsTool { throw DiagnosticsTool.Failure("diagnostics_unavailable") }

    internal class PhoneSkillOrigin internal constructor(
        internal val runtime: RuntimeController,
        internal val generation: Int,
        internal val root: File,
    )

    /** No engine run exists to bind an origin to. */
    @Synchronized internal fun capturePhoneSkillOrigin(): PhoneSkillOrigin? = null

    internal fun phoneSkillOriginCurrent(origin: PhoneSkillOrigin): Boolean = false

    internal fun readPhoneSkillBundle(origin: PhoneSkillOrigin, name: String, revision: String?,
        descriptors: Map<String, PhoneSkillRoute.Descriptor>,
        onDone: (PhoneSkillBundleReader.Read) -> Unit) {
        main.post { onDone(PhoneSkillBundleReader.Read.Rejected(PhoneSkillBundleReader.Reason.UNAVAILABLE)) }
    }

    /** User-selected phone draft only. Without an origin there is nothing to install into. */
    internal fun savePhoneSkill(write: PhoneSkillWrite, onDone: (PhoneSkillInstallResult) -> Unit) {
        val result = PhoneSkillInstallResult.Refused.STALE
        write.finish(result)
        main.post { onDone(result) }
    }

    /** No origin is ever current without an engine run: every check is unverified. */
    internal fun checkPhoneSkillSave(binding: PhoneSkillWrite.SaveBinding,
        publication: PhoneSkillBundleInstaller.Publication, onDone: (PhoneSkillInstallResult) -> Unit) {
        val result = PhoneSkillInstallResult.BundleUnverified(
            binding.identity, publication, PhoneSkillBundleInstaller.Verification.ORIGIN_UNAVAILABLE)
        main.post { onDone(result) }
    }

    companion object {
        private const val TAG = "dsh-runtime"

        @Volatile private var instance: RuntimeController? = null

        fun get(context: Context): RuntimeController =
            instance ?: synchronized(this) {
                instance ?: RuntimeController(context.applicationContext).also { instance = it }
            }
    }
}
