// mob_sensors plugin — Android bridge (SensorManager).
//
// mob_dev copies this into the app's Kotlin sourceSet; the generated
// MobPluginBootstrap.registerAll() calls register() at startup, hands it the
// Activity (MobActivityAware), and records it as a permission provider
// (MobPermissionProvider: :activity_recognition -> ACTIVITY_RECOGNITION) so
// core's MobBridge.request_permission can route that capability here.
//
// The native thunks (nativeRegister + the two nativeDeliver* hooks) are
// exported directly from the sibling zig NIF mob_sensors_nif.zig. Every
// listener is keyed by the integer handle MobSensors.Server allocated; the
// server stops listeners (sensors_stop) when a read completes, a stream is
// stopped, or the caller dies, and calls sensors_stop_all when it (re)starts.
package io.mob.sensors

import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.hardware.TriggerEvent
import android.hardware.TriggerEventListener
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap

object MobSensorsBridge : io.mob.plugin.MobActivityAware, io.mob.plugin.MobPermissionProvider {
    // sensors_start result codes (mirrored in mob_sensors_nif.zig). Non-zero:
    // a call that throws returns 0 to the NIF, which reads as not started.
    private const val OK = 1
    private const val UNAVAILABLE = 2
    private const val PERMISSION = 3

    // nativeDeliverError codes (mirrored in mob_sensors_nif.zig).
    private const val ERR_UNAVAILABLE = 1

    @Volatile private var appContext: Context? = null

    private sealed class Registration {
        abstract val sensor: Sensor

        class Continuous(override val sensor: Sensor, val listener: SensorEventListener) : Registration()

        class Trigger(override val sensor: Sensor, val listener: TriggerEventListener) : Registration()
    }

    private val registrations = ConcurrentHashMap<Int, Registration>()

    // Sensor callbacks run here, off the main thread, so a burst of readings
    // never competes with UI work.
    private val handler: Handler by lazy {
        val thread = HandlerThread("MobSensors")
        thread.start()
        Handler(thread.looper)
    }

    @JvmStatic external fun nativeRegister()

    @JvmStatic external fun nativeDeliverReading(
        pid: Long,
        handle: Int,
        values: DoubleArray,
        timestampMs: Long,
        accuracy: Int,
    )

    @JvmStatic external fun nativeDeliverError(pid: Long, handle: Int, code: Int)

    @JvmStatic
    fun register() {
        nativeRegister()
    }

    override fun setActivity(activity: Activity) {
        appContext = activity.applicationContext
    }

    // Below API 29 step sensors need no runtime grant: an empty array makes
    // core's request_permission report :granted.
    override fun permissionsFor(cap: String): Array<String>? =
        if (cap == "activity_recognition") {
            if (Build.VERSION.SDK_INT >= 29) {
                arrayOf(android.Manifest.permission.ACTIVITY_RECOGNITION)
            } else {
                emptyArray()
            }
        } else {
            null
        }

    private fun sensorManager(): SensorManager? =
        appContext?.getSystemService(Context.SENSOR_SERVICE) as? SensorManager

    @JvmStatic
    fun sensors_list(): String {
        val sm = sensorManager() ?: return "[]"
        val out = JSONArray()
        for (s in sm.getSensorList(Sensor.TYPE_ALL)) {
            val o = JSONObject()
            o.put("type", s.type)
            o.put("string_type", s.stringType)
            o.put("name", s.name)
            o.put("vendor", s.vendor ?: JSONObject.NULL)
            o.put("max_range", finiteOrNull(s.maximumRange))
            o.put("resolution", finiteOrNull(s.resolution))
            o.put("wake_up", s.isWakeUpSensor)
            out.put(o)
        }
        return out.toString()
    }

    // Float -> shortest decimal double (16.46, not 16.459999084472656).
    private fun toDecimal(f: Float): Double = f.toString().toDouble()

    private fun finiteOrNull(f: Float): Any = if (f.isFinite()) toDecimal(f) else JSONObject.NULL

    private fun decimals(values: FloatArray): DoubleArray = DoubleArray(values.size) { toDecimal(values[it]) }

    private fun findSensor(sm: SensorManager, type: Int, stringType: String?): Sensor? =
        if (type >= 0) {
            sm.getDefaultSensor(type) ?: sm.getSensorList(type).firstOrNull()
        } else {
            sm.getSensorList(Sensor.TYPE_ALL).firstOrNull { it.stringType == stringType }
        }

    private fun granted(ctx: Context, perm: String): Boolean =
        ContextCompat.checkSelfPermission(ctx, perm) == PackageManager.PERMISSION_GRANTED

    private fun permitted(ctx: Context, type: Int): Boolean =
        when (type) {
            Sensor.TYPE_STEP_COUNTER, Sensor.TYPE_STEP_DETECTOR ->
                Build.VERSION.SDK_INT < 29 ||
                    granted(ctx, android.Manifest.permission.ACTIVITY_RECOGNITION)
            Sensor.TYPE_HEART_RATE, Sensor.TYPE_HEART_BEAT ->
                granted(ctx, android.Manifest.permission.BODY_SENSORS)
            else -> true
        }

    // SensorEvent.timestamp is elapsedRealtimeNanos-based; convert to Unix ms.
    private fun unixMs(eventNanos: Long): Long =
        System.currentTimeMillis() - (SystemClock.elapsedRealtimeNanos() - eventNanos) / 1_000_000

    @JvmStatic
    fun sensors_start(pid: Long, handle: Int, type: Int, stringType: String?, periodUs: Int): Int {
        val ctx = appContext ?: return UNAVAILABLE
        val sm = sensorManager() ?: return UNAVAILABLE
        // The grant is checked before the lookup: a step-counter read without
        // it reports :permission even on a device that lacks the sensor.
        if (!permitted(ctx, type)) return PERMISSION
        val sensor = findSensor(sm, type, stringType) ?: return UNAVAILABLE
        if (!permitted(ctx, sensor.type)) return PERMISSION
        sensors_stop(handle)

        return try {
            if (sensor.reportingMode == Sensor.REPORTING_MODE_ONE_SHOT) {
                startTrigger(sm, sensor, pid, handle)
            } else {
                startContinuous(sm, sensor, pid, handle, periodUs)
            }
        } catch (e: SecurityException) {
            android.util.Log.w("MobSensors", "sensors_start(${sensor.stringType}) denied: ${e.message}")
            registrations.remove(handle)
            PERMISSION
        } catch (e: RuntimeException) {
            android.util.Log.w("MobSensors", "sensors_start(${sensor.stringType}) failed: ${e.message}")
            registrations.remove(handle)
            UNAVAILABLE
        }
    }

    private fun startContinuous(sm: SensorManager, sensor: Sensor, pid: Long, handle: Int, periodUs: Int): Int {
        val listener =
            object : SensorEventListener {
                override fun onSensorChanged(event: SensorEvent) {
                    nativeDeliverReading(pid, handle, decimals(event.values), unixMs(event.timestamp), event.accuracy)
                }

                override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) = Unit
            }
        registrations[handle] = Registration.Continuous(sensor, listener)
        if (!sm.registerListener(listener, sensor, periodUs, handler)) {
            registrations.remove(handle)
            return UNAVAILABLE
        }
        return OK
    }

    // One-shot sensors (significant motion) fire once per request and then
    // disarm; re-arm after each trigger so a stream keeps reporting. A
    // one-shot read is stopped by the server after the first event.
    private fun startTrigger(sm: SensorManager, sensor: Sensor, pid: Long, handle: Int): Int {
        val listener =
            object : TriggerEventListener() {
                override fun onTrigger(event: TriggerEvent) {
                    nativeDeliverReading(pid, handle, decimals(event.values), unixMs(event.timestamp), SensorManager.SENSOR_STATUS_ACCURACY_HIGH)
                    if (registrations[handle] is Registration.Trigger) {
                        if (!sm.requestTriggerSensor(this, sensor)) nativeDeliverError(pid, handle, ERR_UNAVAILABLE)
                    }
                }
            }
        registrations[handle] = Registration.Trigger(sensor, listener)
        if (!sm.requestTriggerSensor(listener, sensor)) {
            registrations.remove(handle)
            return UNAVAILABLE
        }
        return OK
    }

    @JvmStatic
    fun sensors_stop(handle: Int) {
        val reg = registrations.remove(handle) ?: return
        val sm = sensorManager() ?: return
        when (reg) {
            is Registration.Continuous -> sm.unregisterListener(reg.listener)
            is Registration.Trigger -> sm.cancelTriggerSensor(reg.listener, reg.sensor)
        }
    }

    @JvmStatic
    fun sensors_stop_all() {
        for (handle in registrations.keys.toList()) sensors_stop(handle)
    }
}
