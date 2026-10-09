//! mob_sensors_nif — Android NIF for the mob_sensors plugin.
//!
//! Bridges to SensorManager through the plugin-owned Kotlin object
//! `io.mob.sensors.MobSensorsBridge`. Its inbound thunks are exported directly
//! from this file (zig emits the C-ABI `Java_` symbols).
//!
//! Build path: compiled via `addZigObject` from `-Dplugin_zig_nifs`, reaching
//! mob-core ERTS / JNI bindings through `@import("erts")` / `@import("jni")`.
//! `get_jenv` + `g_jvm` are mob-core exports linked into the same `.so`.
//!
//! Message shapes sent to the server pid (see src/mob_sensors_nif.erl):
//!   {mob_sensors_native, Handle, reading, [float()], UnixMs, Accuracy | nil}
//!   {mob_sensors_native, Handle, error, permission | unavailable}
const std = @import("std");
const erts = @import("erts");
const jni = @import("jni");

// mob-core exports (linked into the same .so). NOT duplicated.
extern fn get_jenv(attached: *c_int) ?*jni.JNIEnv;
extern var g_jvm: ?*jni.JavaVM;

// sensors_start result codes (mirrored in MobSensorsBridge.kt). Non-zero, so
// the 0 a call returns when Kotlin threw reads as "not started".
const START_OK: jni.JInt = 1;
const START_UNAVAILABLE: jni.JInt = 2;
const START_PERMISSION: jni.JInt = 3;

// nativeDeliverError codes (mirrored in MobSensorsBridge.kt).
const ERR_PERMISSION: c_int = 2;

// Android SensorEvent.values is at most 16 floats (TYPE_POSE_6DOF uses 15).
const MAX_VALUES = 32;

// mob-core's jni module leaves GetDoubleArrayRegion and ExceptionOccurred
// untyped (?*anyopaque); these are their jni.h signatures.
const GetDoubleArrayRegionFn = *const fn (env: *jni.JNIEnv, arr: jni.JObject, start: jni.JInt, len: jni.JInt, buf: [*]f64) callconv(.c) void;
const ExceptionOccurredFn = *const fn (env: *jni.JNIEnv) callconv(.c) jni.JObject;

const Methods = struct {
    list: jni.JMethodID = null,
    start: jni.JMethodID = null,
    stop: jni.JMethodID = null,
    stop_all: jni.JMethodID = null,
};

var g_m: Methods = .{};
var g_cls: jni.JClass = null;

// A missing method leaves a NoSuchMethodError pending on the JNIEnv; clear it
// so later lookups and calls aren't shadowed by it (MOB-77).
inline fn cacheMethod(jenv: *jni.JNIEnv, cls: jni.JClass, name: [*:0]const u8, sig: [*:0]const u8) jni.JMethodID {
    const m = jni.getStaticMethodID(jenv, cls, name, sig);
    if (m == null) jni.exceptionClear(jenv);
    return m;
}

export fn Java_io_mob_sensors_MobSensorsBridge_nativeRegister(jenv: *jni.JNIEnv, cls: jni.JClass) callconv(.c) void {
    g_cls = jni.newGlobalRef(jenv, cls);
    if (g_cls == null) return;
    g_m.list = cacheMethod(jenv, cls, "sensors_list", "()Ljava/lang/String;");
    g_m.start = cacheMethod(jenv, cls, "sensors_start", "(JIILjava/lang/String;I)I");
    g_m.stop = cacheMethod(jenv, cls, "sensors_stop", "(I)V");
    g_m.stop_all = cacheMethod(jenv, cls, "sensors_stop_all", "()V");
}

inline fn detachIfAttached(attached: c_int) void {
    if (attached != 0) {
        if (g_jvm) |jvm| jni.detachCurrentThread(jvm);
    }
}

inline fn pidToJlong(pid: erts.ErlNifPid) jni.JLong {
    if (@sizeOf(erts.ERL_NIF_TERM) == @sizeOf(jni.JLong)) {
        return @bitCast(pid.pid);
    }
    return @intCast(pid.pid);
}

inline fn pidFromLong(jpid: jni.JLong) erts.ErlNifPid {
    if (@sizeOf(erts.ERL_NIF_TERM) == @sizeOf(jni.JLong)) {
        return .{ .pid = @bitCast(jpid) };
    }
    const low: u32 = @truncate(@as(u64, @bitCast(jpid)));
    return .{ .pid = low };
}

// ── Inbound delivery thunks — Kotlin sensor callbacks call these ─────────
export fn Java_io_mob_sensors_MobSensorsBridge_nativeDeliverReading(
    jenv: *jni.JNIEnv,
    cls: jni.JClass,
    pid_long: jni.JLong,
    handle: jni.JInt,
    values: jni.JObject,
    ts_ms: jni.JLong,
    accuracy: jni.JInt,
) callconv(.c) void {
    _ = cls;
    var pid = pidFromLong(pid_long);
    const get_region: GetDoubleArrayRegionFn = @ptrCast(@alignCast(jenv.*.GetDoubleArrayRegion orelse return));
    var doubles: [MAX_VALUES]f64 = undefined;
    const len: usize = @intCast(@max(0, @min(jni.getArrayLength(jenv, values), MAX_VALUES)));
    if (len > 0) get_region(jenv, values, 0, @intCast(len), &doubles);
    // enif_make_double rejects NaN / inf: drop such a sample.
    for (doubles[0..len]) |d| if (!std.math.isFinite(d)) return;

    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    var terms: [MAX_VALUES]erts.ERL_NIF_TERM = undefined;
    for (0..len) |i| terms[i] = erts.enif_make_double(env, doubles[i]);
    const msg = erts.makeTuple(env, .{
        erts.atom(env, "mob_sensors_native"),
        erts.enif_make_int(env, handle),
        erts.atom(env, "reading"),
        erts.makeList(env, terms[0..len]),
        erts.enif_make_int64(env, ts_ms),
        // Trigger sensors carry no accuracy; Kotlin passes Int.MIN_VALUE.
        if (accuracy == std.math.minInt(jni.JInt)) erts.atom(env, "nil") else erts.enif_make_int(env, accuracy),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

export fn Java_io_mob_sensors_MobSensorsBridge_nativeDeliverError(
    jenv: *jni.JNIEnv,
    cls: jni.JClass,
    pid_long: jni.JLong,
    handle: jni.JInt,
    code: c_int,
) callconv(.c) void {
    _ = jenv;
    _ = cls;
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const reason = if (code == ERR_PERMISSION) erts.atom(env, "permission") else erts.atom(env, "unavailable");
    const msg = erts.makeTuple(env, .{
        erts.atom(env, "mob_sensors_native"),
        erts.enif_make_int(env, handle),
        erts.atom(env, "error"),
        reason,
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

// ── NIFs ──────────────────────────────────────────────────────────────────

fn makeBinary(env: ?*erts.ErlNifEnv, bytes: []const u8) erts.ERL_NIF_TERM {
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_alloc_binary(bytes.len, &bin) == 0) return erts.badarg(env);
    @memcpy(bin.data[0..bytes.len], bytes);
    return erts.enif_make_binary(env, &bin);
}

// {error, Reason}: list() could not ask SensorManager. MobSensors.Server maps
// it to [] (the public list/0 is unchanged); MobSensors.SelfTest fails on it,
// since a host where it happens can never see a sensor (MOB-418).
fn listError(env: ?*erts.ErlNifEnv, comptime reason: [:0]const u8) erts.ERL_NIF_TERM {
    return erts.makeTuple(env, .{ erts.atom(env, "error"), erts.atom(env, reason) });
}

/// list() -> JSON binary describing every sensor, or {error, Reason}:
///   bridge_not_registered  nativeRegister never ran (MobPluginBootstrap did not
///                          call register()) or the sensors_list lookup failed
///   no_jni_env             no JNIEnv for this scheduler thread
///   no_activity            the bootstrap never handed the bridge an Activity
///   bridge_exception       sensors_list threw (the exception is cleared)
///   string_unavailable     GetStringUTFChars failed (out of memory)
fn nif_list(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    if (g_cls == null or g_m.list == null) return listError(env, "bridge_not_registered");
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return listError(env, "no_jni_env");
    defer detachIfAttached(attached);

    const jstr: jni.JString = jenv.*.CallStaticObjectMethod.?(jenv, g_cls, g_m.list);
    const exception_occurred: ExceptionOccurredFn = @ptrCast(@alignCast(jenv.*.ExceptionOccurred.?));
    const thrown = exception_occurred(jenv);
    if (thrown != null) {
        jni.exceptionClear(jenv);
        jni.deleteLocalRef(jenv, thrown);
        if (jstr != null) jni.deleteLocalRef(jenv, jstr);
        return listError(env, "bridge_exception");
    }
    // sensors_list returns null only when it has no Context (no Activity yet).
    if (jstr == null) return listError(env, "no_activity");
    defer jni.deleteLocalRef(jenv, jstr);

    const chars = jni.getStringUTFChars(jenv, jstr) orelse return listError(env, "string_unavailable");
    defer jni.releaseStringUTFChars(jenv, jstr, chars);
    return makeBinary(env, std.mem.span(chars));
}

/// start(Handle, TypeCode, StringType | nil, PeriodUs) -> ok | unavailable | permission
fn nif_start(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var handle: c_int = 0;
    var type_code: c_int = 0;
    var period_us: c_int = 0;
    if (erts.enif_get_int(env, argv[0], &handle) == 0 or
        erts.enif_get_int(env, argv[1], &type_code) == 0 or
        erts.enif_get_int(env, argv[3], &period_us) == 0) return erts.badarg(env);

    // Vendor string type, NUL-terminated for NewStringUTF; absent (nil) for
    // standard types.
    var type_buf: [256]u8 = @splat(0);
    var has_string_type = false;
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_inspect_binary(env, argv[2], &bin) != 0) {
        if (bin.size >= type_buf.len) return erts.badarg(env);
        @memcpy(type_buf[0..bin.size], bin.data[0..bin.size]);
        has_string_type = true;
    }

    if (g_cls == null or g_m.start == null) return erts.atom(env, "unavailable");
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "unavailable");
    defer detachIfAttached(attached);

    const jtype: jni.JString = if (has_string_type) jni.newStringUTF(jenv, @ptrCast(&type_buf)) else null;
    const rc: jni.JInt = jenv.*.CallStaticIntMethod.?(jenv, g_cls, g_m.start, pidToJlong(pid), @as(jni.JInt, handle), @as(jni.JInt, type_code), jtype, @as(jni.JInt, period_us));
    // Kotlin catches its own exceptions; clear anyway so nothing pending can
    // reach the next JNI call on this scheduler thread (MOB-77).
    jni.exceptionClear(jenv);
    if (jtype != null) jni.deleteLocalRef(jenv, jtype);

    return switch (rc) {
        START_OK => erts.ok(env),
        START_PERMISSION => erts.atom(env, "permission"),
        else => erts.atom(env, "unavailable"),
    };
}

fn callVoid(env: ?*erts.ErlNifEnv, method: jni.JMethodID, handle: ?c_int) erts.ERL_NIF_TERM {
    if (g_cls == null or method == null) return erts.ok(env);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.ok(env);
    defer detachIfAttached(attached);
    if (handle) |h| {
        jenv.*.CallStaticVoidMethod.?(jenv, g_cls, method, @as(jni.JInt, h));
    } else {
        jenv.*.CallStaticVoidMethod.?(jenv, g_cls, method);
    }
    jni.exceptionClear(jenv);
    return erts.ok(env);
}

/// stop(Handle) -> ok. Idempotent.
fn nif_stop(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var handle: c_int = 0;
    if (erts.enif_get_int(env, argv[0], &handle) == 0) return erts.badarg(env);
    return callVoid(env, g_m.stop, handle);
}

/// stop_all() -> ok.
fn nif_stop_all(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    return callVoid(env, g_m.stop_all, null);
}

/// steps(Handle, FromMs, ToMs) -> history_unavailable. Android keeps no step
/// history outside Health Connect; read(:step_counter) gives steps since boot.
fn nif_steps(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    return erts.atom(env, "history_unavailable");
}

// ── NIF table + init entry point ─────────────────────────────────────────
fn nifLoad(env: ?*erts.ErlNifEnv, priv: *?*anyopaque, info: erts.ERL_NIF_TERM) callconv(.c) c_int {
    _ = env;
    _ = priv;
    _ = info;
    return 0;
}

const nif_funcs = [_]erts.ErlNifFunc{
    .{ .name = "list", .arity = 0, .fptr = nif_list, .flags = 0 },
    .{ .name = "start", .arity = 4, .fptr = nif_start, .flags = 0 },
    .{ .name = "stop", .arity = 1, .fptr = nif_stop, .flags = 0 },
    .{ .name = "stop_all", .arity = 0, .fptr = nif_stop_all, .flags = 0 },
    .{ .name = "steps", .arity = 3, .fptr = nif_steps, .flags = 0 },
};

var nif_entry: erts.ErlNifEntry = .{
    .major = erts.ERL_NIF_MAJOR_VERSION,
    .minor = erts.ERL_NIF_MINOR_VERSION,
    .name = "mob_sensors_nif",
    .num_of_funcs = nif_funcs.len,
    .funcs = &nif_funcs,
    .load = nifLoad,
    .reload = null,
    .upgrade = null,
    .unload = null,
    .vm_variant = erts.ERL_NIF_VM_VARIANT,
    .options = 1,
    .sizeof_ErlNifResourceTypeInit = erts.SIZEOF_ErlNifResourceTypeInit,
    .min_erts = erts.ERL_NIF_MIN_ERTS_VERSION,
};

pub export fn mob_sensors_nif_nif_init() callconv(.c) *erts.ErlNifEntry {
    return &nif_entry;
}
