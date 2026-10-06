/* mob_sensors_nif — iOS NIF for the mob_sensors plugin (Objective-C).
 *
 * One shared CMMotionManager (raw accelerometer; device motion for the
 * bias-corrected gyroscope and the calibrated magnetic field), CMAltimeter
 * (pressure), CMPedometer (step counter + step history) and UIDevice
 * proximity monitoring. Registered as the Erlang module mob_sensors_nif via
 * ERL_NIF_INIT; compiled as ObjC (-fobjc-arc) because the manifest entry is
 * lang: :objc.
 *
 * The iOS side answers to the Android Sensor.TYPE_* codes MobSensors.Types
 * sends, and converts values to Android's SensorEvent units and axes:
 * acceleration g -> m/s^2 with Android's sign (+9.81 on z lying face-up),
 * pressure kPa -> hPa, proximity near -> [0.0] / far -> [5.0] cm. The
 * magnetic field's calibration accuracy maps to SENSOR_STATUS_* (0..3).
 *
 * Messages go to the pid that called start/4 or steps/3 (MobSensors.Server):
 *   {mob_sensors_native, Handle, reading, [float()], UnixMs, Accuracy | nil}
 *   {mob_sensors_native, Handle, error, permission | unavailable | binary()}
 *   {mob_sensors_native, Handle, steps, Steps, DistanceM | nil, Floors | nil}
 *
 * The load callback registers the :activity_recognition permission handler
 * (Motion & Fitness authorization) with core's registry
 * (mob_register_permission_handler, a core symbol linked into the same static
 * binary).
 */
#import <CoreMotion/CoreMotion.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <erl_nif.h>
#include <limits.h>
#include <math.h>
#include <string.h>
#include <sys/utsname.h>

/* Defined in core mob's ios/mob_nif.m, linked into the same static binary. */
extern void mob_register_permission_handler(const char *cap, void (*fn)(ErlNifPid));

/* Android Sensor.TYPE_* codes this platform can serve. */
enum {
  T_ACCELEROMETER = 1,
  T_MAGNETIC_FIELD = 2,
  T_GYROSCOPE = 4,
  T_PRESSURE = 6,
  T_PROXIMITY = 8,
  T_STEP_COUNTER = 19
};

static const double kStandardGravity = 9.80665;
static const double kProximityFarCm = 5.0;
/* proximityState reads "far" until the sensor has reported once after
 * monitoring is switched on, so the first sample waits this long (or for the
 * first change notification, whichever comes first). */
static const double kProximitySettleS = 0.3;
static const int kNoAccuracy = INT_MIN;

// ── Registry ──────────────────────────────────────────────────────────────
// One registration per handle. g_regs, g_motion's update state and the
// motion fan-out are only touched on g_queue (serial; g_ops runs its
// handlers there). The proximity observer and g_proximity_* only on the
// main queue.
@interface MobSensorsReg : NSObject
@property(nonatomic) int type;
@property(nonatomic) int handle;
@property(nonatomic) ErlNifPid pid;
@property(nonatomic) double period;  // seconds between delivered samples
@property(nonatomic) double lastTs;  // CMLogItem timestamp of the last delivered sample
@property(nonatomic, strong) id source;   // CMAltimeter / CMPedometer
@property(nonatomic, strong) id observer; // proximity notification token
@property(nonatomic) BOOL proximityActive;
@property(nonatomic) BOOL proximitySent;
@end

@implementation MobSensorsReg
@end

static dispatch_queue_t g_queue;
static NSMutableDictionary<NSNumber *, MobSensorsReg *> *g_regs;
static NSOperationQueue *g_ops;
/* Apple: one CMMotionManager per app, since several affect each other's
 * delivery rates. Every motion handle shares this one; each stream runs at
 * the fastest interval asked for and fan_out throttles slower handles. (Core
 * mob keeps its own manager for Mob.Motion.) */
static CMMotionManager *g_motion;
static BOOL g_acc_on, g_dm_on; // the two streams' running state
static CMAttitudeReferenceFrame g_dm_frame;
static int g_proximity_users;
static BOOL g_proximity_app_enabled; // monitoring was on before our first user
static CFAbsoluteTime g_proximity_on_at; // when we switched it on; 0 if the app had

// ── Term helpers ──────────────────────────────────────────────────────────
static double now_unix_ms(void) { return [[NSDate date] timeIntervalSince1970] * 1000.0; }

/* CMLogItem.timestamp is seconds since boot. */
static double boot_ts_to_unix_ms(NSTimeInterval ts) {
  return now_unix_ms() - ([[NSProcessInfo processInfo] systemUptime] - ts) * 1000.0;
}

static ERL_NIF_TERM make_utf8_binary(ErlNifEnv *e, NSString *s) {
  const char *utf8 = s ? s.UTF8String : "";
  size_t len = strlen(utf8);
  ERL_NIF_TERM term;
  unsigned char *buf = enif_make_new_binary(e, len, &term);
  memcpy(buf, utf8, len);
  return term;
}

static void send_reading(ErlNifPid pid, int handle, const double *values, unsigned n, double ts_ms,
                         int accuracy) {
  for (unsigned i = 0; i < n; i++) {
    if (!isfinite(values[i]))
      return; // enif_make_double rejects NaN / inf; drop the sample.
  }
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM items[8];
  for (unsigned i = 0; i < n && i < 8; i++)
    items[i] = enif_make_double(e, values[i]);
  ERL_NIF_TERM msg = enif_make_tuple6(
      e, enif_make_atom(e, "mob_sensors_native"), enif_make_int(e, handle),
      enif_make_atom(e, "reading"), enif_make_list_from_array(e, items, n),
      enif_make_int64(e, (ErlNifSInt64)ts_ms),
      accuracy == kNoAccuracy ? enif_make_atom(e, "nil") : enif_make_int(e, accuracy));
  enif_send(NULL, &pid, e, msg);
  enif_free_env(e);
}

static void send_error_term(ErlNifPid pid, int handle, ErlNifEnv *e, ERL_NIF_TERM reason) {
  ERL_NIF_TERM msg = enif_make_tuple4(e, enif_make_atom(e, "mob_sensors_native"),
                                      enif_make_int(e, handle), enif_make_atom(e, "error"), reason);
  enif_send(NULL, &pid, e, msg);
}

static void send_error_atom(ErlNifPid pid, int handle, const char *reason) {
  ErlNifEnv *e = enif_alloc_env();
  send_error_term(pid, handle, e, enif_make_atom(e, reason));
  enif_free_env(e);
}

static void send_error(ErlNifPid pid, int handle, NSError *err) {
  if ([err.domain isEqualToString:CMErrorDomain]) {
    if (err.code == CMErrorMotionActivityNotAuthorized || err.code == CMErrorMotionActivityNotEntitled) {
      send_error_atom(pid, handle, "permission");
      return;
    }
    if (err.code == CMErrorMotionActivityNotAvailable) {
      send_error_atom(pid, handle, "unavailable");
      return;
    }
  }
  ErlNifEnv *e = enif_alloc_env();
  send_error_term(pid, handle, e, make_utf8_binary(e, err.localizedDescription));
  enif_free_env(e);
}

static ERL_NIF_TERM number_or_nil(ErlNifEnv *e, NSNumber *n, BOOL as_double) {
  if (!n)
    return enif_make_atom(e, "nil");
  return as_double ? enif_make_double(e, n.doubleValue) : enif_make_int64(e, n.longLongValue);
}

static void send_steps(ErlNifPid pid, int handle, CMPedometerData *d) {
  ErlNifEnv *e = enif_alloc_env();
  NSNumber *distance = d.distance;
  if (distance && !isfinite(distance.doubleValue))
    distance = nil;
  ERL_NIF_TERM msg = enif_make_tuple6(
      e, enif_make_atom(e, "mob_sensors_native"), enif_make_int(e, handle),
      enif_make_atom(e, "steps"), enif_make_int64(e, d.numberOfSteps.longLongValue),
      number_or_nil(e, distance, YES), number_or_nil(e, d.floorsAscended, NO));
  enif_send(NULL, &pid, e, msg);
  enif_free_env(e);
}

// ── Availability ──────────────────────────────────────────────────────────
/* Every iPhone has a proximity sensor; iPads, iPods and the simulator (whose
 * hw.machine is the host arch) don't. uname avoids touching UIKit off the
 * main thread. */
static BOOL has_proximity(void) {
  struct utsname u;
  if (uname(&u) != 0)
    return NO;
  return strncmp(u.machine, "iPhone", 6) == 0;
}

static BOOL available(int type) {
  switch (type) {
  case T_ACCELEROMETER: return g_motion.accelerometerAvailable;
  case T_GYROSCOPE: return g_motion.deviceMotionAvailable && g_motion.gyroAvailable;
  case T_MAGNETIC_FIELD:
    return g_motion.deviceMotionAvailable && g_motion.magnetometerAvailable &&
           ([CMMotionManager availableAttitudeReferenceFrames] &
            CMAttitudeReferenceFrameXArbitraryCorrectedZVertical) != 0;
  case T_PRESSURE: return [CMAltimeter isRelativeAltitudeAvailable];
  case T_PROXIMITY: return has_proximity();
  case T_STEP_COUNTER: return [CMPedometer isStepCountingAvailable];
  default: return NO;
  }
}

static BOOL motion_denied(CMAuthorizationStatus s) {
  return s == CMAuthorizationStatusDenied || s == CMAuthorizationStatusRestricted;
}

// ── list() ────────────────────────────────────────────────────────────────
static NSDictionary *sensor_entry(int type, NSString *string_type, NSString *name, id max_range) {
  return @{
    @"type" : @(type),
    @"string_type" : string_type,
    @"name" : name,
    @"vendor" : @"Apple",
    @"max_range" : max_range,
    @"resolution" : [NSNull null],
    @"wake_up" : [NSNull null]
  };
}

static ERL_NIF_TERM nif_list(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
  NSMutableArray *out = [NSMutableArray array];
  NSNull *none = [NSNull null];
  if (available(T_ACCELEROMETER))
    [out addObject:sensor_entry(T_ACCELEROMETER, @"ios.accelerometer", @"CMMotionManager accelerometer", none)];
  if (available(T_GYROSCOPE))
    [out addObject:sensor_entry(T_GYROSCOPE, @"ios.device_motion.rotation_rate", @"CMDeviceMotion rotation rate", none)];
  if (available(T_MAGNETIC_FIELD))
    [out addObject:sensor_entry(T_MAGNETIC_FIELD, @"ios.device_motion.magnetic_field", @"CMDeviceMotion calibrated magnetic field", none)];
  if (available(T_PRESSURE))
    [out addObject:sensor_entry(T_PRESSURE, @"ios.altimeter.pressure", @"CMAltimeter pressure", none)];
  if (available(T_PROXIMITY))
    [out addObject:sensor_entry(T_PROXIMITY, @"ios.proximity", @"UIDevice proximity", @(kProximityFarCm))];
  if (available(T_STEP_COUNTER))
    [out addObject:sensor_entry(T_STEP_COUNTER, @"ios.pedometer.steps", @"CMPedometer step counter", none)];
  NSData *json = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
  ERL_NIF_TERM term;
  unsigned char *buf = enif_make_new_binary(env, json.length, &term);
  memcpy(buf, json.bytes, json.length);
  return term;
}

// ── Motion (shared CMMotionManager) ───────────────────────────────────────
/* g_queue. Delivers one sample to every handle of `type` whose period has
 * elapsed. `tolerance` (half the stream's interval) absorbs jitter, so a
 * 200 ms handle on a 20 ms stream gets every tenth sample, not every
 * eleventh; the schedule advances by the period, so jitter doesn't add up. */
static void fan_out(int type, NSTimeInterval ts, const double *v, unsigned n, int accuracy,
                    double tolerance) {
  double ts_ms = boot_ts_to_unix_ms(ts);
  for (MobSensorsReg *reg in g_regs.allValues) {
    if (reg.type != type)
      continue;
    if (reg.lastTs > 0 && ts - reg.lastTs < reg.period - tolerance)
      continue;
    reg.lastTs = reg.lastTs > 0 ? MAX(reg.lastTs + reg.period, ts - tolerance) : ts;
    send_reading(reg.pid, reg.handle, v, n, ts_ms, accuracy);
  }
}

/* g_queue. A CoreMotion error ends every handle on that stream; the server
 * stops each one, which refreshes the stream. */
static void fan_out_error(int type_a, int type_b, NSError *err) {
  for (MobSensorsReg *reg in g_regs.allValues) {
    if (reg.type == type_a || reg.type == type_b)
      send_error(reg.pid, reg.handle, err);
  }
}

/* CMMagneticFieldCalibrationAccuracy (0 low .. 2 high) as Android's
 * SENSOR_STATUS_* (1 low .. 3 high). Uncalibrated samples never get here. */
static int magnetic_accuracy(CMMagneticFieldCalibrationAccuracy a) {
  switch (a) {
  case CMMagneticFieldCalibrationAccuracyMedium: return 2;
  case CMMagneticFieldCalibrationAccuracyHigh: return 3;
  default: return 1;
  }
}

/* g_queue. Fastest period among the handles of the given types; 0 if none. */
static double min_period(int type_a, int type_b, BOOL *has_b) {
  double best = 0;
  if (has_b)
    *has_b = NO;
  for (MobSensorsReg *reg in g_regs.allValues) {
    if (reg.type != type_a && reg.type != type_b)
      continue;
    if (has_b && reg.type == type_b)
      *has_b = YES;
    if (best == 0 || reg.period < best)
      best = reg.period;
  }
  return best;
}

/* g_queue. Brings g_motion's two streams in line with the registry: the raw
 * accelerometer, and device motion for the gyroscope (bias-corrected
 * rotationRate) and magnetic field (calibrated, which needs a
 * magnetometer-corrected reference frame, so that frame is used only while a
 * magnetic handle exists). Called after every motion add or remove. The
 * running state is tracked here rather than read back from *Active. */
static void refresh_motion(void) {
  double acc = min_period(T_ACCELEROMETER, T_ACCELEROMETER, NULL);
  if (acc > 0) {
    g_motion.accelerometerUpdateInterval = acc;
    if (!g_acc_on) {
      g_acc_on = YES;
      [g_motion startAccelerometerUpdatesToQueue:g_ops
                                     withHandler:^(CMAccelerometerData *d, NSError *err) {
                                       if (err) {
                                         fan_out_error(T_ACCELEROMETER, T_ACCELEROMETER, err);
                                         return;
                                       }
                                       if (!d)
                                         return;
                                       double v[3] = {-d.acceleration.x * kStandardGravity,
                                                      -d.acceleration.y * kStandardGravity,
                                                      -d.acceleration.z * kStandardGravity};
                                       fan_out(T_ACCELEROMETER, d.timestamp, v, 3, kNoAccuracy,
                                               g_motion.accelerometerUpdateInterval / 2);
                                     }];
    }
  } else if (g_acc_on) {
    g_acc_on = NO;
    [g_motion stopAccelerometerUpdates];
  }

  BOOL magnetic = NO;
  double dm = min_period(T_GYROSCOPE, T_MAGNETIC_FIELD, &magnetic);
  if (dm > 0) {
    CMAttitudeReferenceFrame frame = magnetic ? CMAttitudeReferenceFrameXArbitraryCorrectedZVertical
                                              : CMAttitudeReferenceFrameXArbitraryZVertical;
    if (g_dm_on && g_dm_frame != frame) {
      g_dm_on = NO;
      [g_motion stopDeviceMotionUpdates];
    }
    g_motion.deviceMotionUpdateInterval = dm;
    if (!g_dm_on) {
      g_dm_on = YES;
      g_dm_frame = frame;
      [g_motion startDeviceMotionUpdatesUsingReferenceFrame:frame
                                                    toQueue:g_ops
                                                withHandler:^(CMDeviceMotion *d, NSError *err) {
                                                  if (err) {
                                                    fan_out_error(T_GYROSCOPE, T_MAGNETIC_FIELD, err);
                                                    return;
                                                  }
                                                  if (!d)
                                                    return;
                                                  double tol = g_motion.deviceMotionUpdateInterval / 2;
                                                  double g[3] = {d.rotationRate.x, d.rotationRate.y,
                                                                 d.rotationRate.z};
                                                  fan_out(T_GYROSCOPE, d.timestamp, g, 3, kNoAccuracy, tol);
                                                  // Uncalibrated (including samples of a
                                                  // previous non-magnetic frame still queued)
                                                  // carries no valid field: wait for calibration.
                                                  CMCalibratedMagneticField f = d.magneticField;
                                                  if (f.accuracy == CMMagneticFieldCalibrationAccuracyUncalibrated)
                                                    return;
                                                  double m[3] = {f.field.x, f.field.y, f.field.z};
                                                  fan_out(T_MAGNETIC_FIELD, d.timestamp, m, 3,
                                                          magnetic_accuracy(f.accuracy), tol);
                                                }];
    }
  } else if (g_dm_on) {
    g_dm_on = NO;
    [g_motion stopDeviceMotionUpdates];
  }
}

// ── Proximity ─────────────────────────────────────────────────────────────
static void send_proximity(ErlNifPid pid, int handle) {
  double v = [UIDevice currentDevice].proximityState ? 0.0 : kProximityFarCm;
  send_reading(pid, handle, &v, 1, now_unix_ms(), kNoAccuracy);
}

/* Main queue. Monitoring is reference counted across handles. If the app had
 * already switched it on, it stays on after our last handle. */
static void start_proximity(MobSensorsReg *reg) {
  UIDevice *dev = [UIDevice currentDevice];
  ErlNifPid pid = reg.pid;
  int handle = reg.handle;
  if (g_proximity_users == 0) {
    g_proximity_app_enabled = dev.proximityMonitoringEnabled;
    if (!g_proximity_app_enabled) {
      dev.proximityMonitoringEnabled = YES;
      if (!dev.proximityMonitoringEnabled) {
        send_error_atom(pid, handle, "unavailable");
        return;
      }
      g_proximity_on_at = CFAbsoluteTimeGetCurrent();
    } else {
      g_proximity_on_at = 0;
    }
  }
  reg.proximityActive = YES;
  g_proximity_users++;
  __weak MobSensorsReg *weak = reg;
  reg.observer = [[NSNotificationCenter defaultCenter]
      addObserverForName:UIDeviceProximityStateDidChangeNotification
                  object:nil
                   queue:[NSOperationQueue mainQueue]
              usingBlock:^(NSNotification *note) {
                (void)note;
                MobSensorsReg *r = weak;
                if (!r || !r.proximityActive)
                  return;
                r.proximitySent = YES;
                send_proximity(pid, handle);
              }];
  // The first sample: now if the sensor has settled, else once it has
  // (unless a change notification got there first).
  double wait = g_proximity_on_at > 0 ? g_proximity_on_at + kProximitySettleS - CFAbsoluteTimeGetCurrent() : 0;
  if (wait <= 0) {
    reg.proximitySent = YES;
    send_proximity(pid, handle);
    return;
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    MobSensorsReg *r = weak;
    if (!r || !r.proximityActive || r.proximitySent)
      return;
    r.proximitySent = YES;
    send_proximity(pid, handle);
  });
}

/* Main queue. */
static void stop_proximity(MobSensorsReg *reg) {
  if (reg.observer)
    [[NSNotificationCenter defaultCenter] removeObserver:reg.observer];
  reg.observer = nil;
  if (reg.proximityActive) {
    reg.proximityActive = NO;
    if (--g_proximity_users == 0 && !g_proximity_app_enabled)
      [UIDevice currentDevice].proximityMonitoringEnabled = NO;
  }
}

// ── start / stop ──────────────────────────────────────────────────────────
/* g_queue. */
static void start_reg(MobSensorsReg *reg) {
  ErlNifPid pid = reg.pid;
  int handle = reg.handle;
  switch (reg.type) {
  case T_ACCELEROMETER:
  case T_GYROSCOPE:
  case T_MAGNETIC_FIELD:
    refresh_motion();
    break;
  case T_PRESSURE: {
    CMAltimeter *a = [CMAltimeter new];
    reg.source = a;
    [a startRelativeAltitudeUpdatesToQueue:g_ops
                               withHandler:^(CMAltitudeData *d, NSError *err) {
                                 if (err) {
                                   send_error(pid, handle, err);
                                   return;
                                 }
                                 double v = d.pressure.doubleValue * 10.0; // kPa -> hPa
                                 send_reading(pid, handle, &v, 1, boot_ts_to_unix_ms(d.timestamp),
                                              kNoAccuracy);
                               }];
    break;
  }
  case T_STEP_COUNTER: {
    // Steps since local midnight: the current total now, then every update.
    CMPedometer *p = [CMPedometer new];
    reg.source = p;
    NSDate *midnight = [[NSCalendar currentCalendar] startOfDayForDate:[NSDate date]];
    void (^deliver)(CMPedometerData *, NSError *) = ^(CMPedometerData *d, NSError *err) {
      if (err) {
        send_error(pid, handle, err);
        return;
      }
      double v = d.numberOfSteps.doubleValue;
      send_reading(pid, handle, &v, 1, d.endDate.timeIntervalSince1970 * 1000.0, kNoAccuracy);
    };
    [p queryPedometerDataFromDate:midnight toDate:[NSDate date] withHandler:deliver];
    [p startPedometerUpdatesFromDate:midnight withHandler:deliver];
    break;
  }
  case T_PROXIMITY: {
    dispatch_async(dispatch_get_main_queue(), ^{
      start_proximity(reg);
    });
    break;
  }
  default:
    break;
  }
}

/* g_queue. The registration has already left g_regs. */
static void stop_reg(MobSensorsReg *reg) {
  switch (reg.type) {
  case T_ACCELEROMETER:
  case T_GYROSCOPE:
  case T_MAGNETIC_FIELD: refresh_motion(); break;
  case T_PRESSURE: [(CMAltimeter *)reg.source stopRelativeAltitudeUpdates]; break;
  case T_STEP_COUNTER: [(CMPedometer *)reg.source stopPedometerUpdates]; break;
  case T_PROXIMITY: {
    dispatch_async(dispatch_get_main_queue(), ^{
      stop_proximity(reg);
    });
    break;
  }
  default: break; // a steps/3 query: nothing to stop, the pedometer is released
  }
  reg.source = nil;
}

/* start(Handle, TypeCode, StringType | nil, PeriodUs) -> ok | unavailable | permission */
static ERL_NIF_TERM nif_start(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  int handle, type, period_us;
  if (!enif_get_int(env, argv[0], &handle) || !enif_get_int(env, argv[1], &type) ||
      !enif_get_int(env, argv[3], &period_us))
    return enif_make_badarg(env);
  // A denied grant is reported before availability, as on Android.
  if (type == T_PRESSURE && motion_denied([CMAltimeter authorizationStatus]))
    return enif_make_atom(env, "permission");
  if (type == T_STEP_COUNTER && motion_denied([CMPedometer authorizationStatus]))
    return enif_make_atom(env, "permission");
  // Vendor string types (type -1) are an Android concept.
  if (!available(type))
    return enif_make_atom(env, "unavailable");

  ErlNifPid pid;
  enif_self(env, &pid);
  MobSensorsReg *reg = [MobSensorsReg new];
  reg.type = type;
  reg.handle = handle;
  reg.pid = pid;
  reg.period = period_us / 1e6;
  dispatch_async(g_queue, ^{
    MobSensorsReg *old = g_regs[@(handle)];
    if (old) {
      [g_regs removeObjectForKey:@(handle)];
      stop_reg(old);
    }
    g_regs[@(handle)] = reg;
    start_reg(reg);
  });
  return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_stop(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  int handle;
  if (!enif_get_int(env, argv[0], &handle))
    return enif_make_badarg(env);
  dispatch_async(g_queue, ^{
    MobSensorsReg *reg = g_regs[@(handle)];
    if (!reg)
      return;
    [g_regs removeObjectForKey:@(handle)];
    stop_reg(reg);
  });
  return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_stop_all(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
  dispatch_async(g_queue, ^{
    NSArray<MobSensorsReg *> *regs = g_regs.allValues;
    [g_regs removeAllObjects];
    for (MobSensorsReg *reg in regs)
      stop_reg(reg);
  });
  return enif_make_atom(env, "ok");
}

/* steps(Handle, FromMs, ToMs) -> ok | unavailable. The result arrives as a
 * steps or error message. */
static ERL_NIF_TERM nif_steps(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  int handle;
  ErlNifSInt64 from_ms, to_ms;
  if (!enif_get_int(env, argv[0], &handle) || !enif_get_int64(env, argv[1], &from_ms) ||
      !enif_get_int64(env, argv[2], &to_ms))
    return enif_make_badarg(env);
  if (![CMPedometer isStepCountingAvailable])
    return enif_make_atom(env, "unavailable");

  ErlNifPid pid;
  enif_self(env, &pid);
  NSDate *from = [NSDate dateWithTimeIntervalSince1970:from_ms / 1000.0];
  NSDate *to = [NSDate dateWithTimeIntervalSince1970:to_ms / 1000.0];
  dispatch_async(g_queue, ^{
    // Held in the registry (type 0) so the pedometer outlives this block
    // until its handler has run.
    MobSensorsReg *reg = [MobSensorsReg new];
    CMPedometer *p = [CMPedometer new];
    reg.source = p;
    g_regs[@(handle)] = reg;
    [p queryPedometerDataFromDate:from
                           toDate:to
                      withHandler:^(CMPedometerData *d, NSError *err) {
                        if (err)
                          send_error(pid, handle, err);
                        else
                          send_steps(pid, handle, d);
                        dispatch_async(g_queue, ^{
                          [g_regs removeObjectForKey:@(handle)];
                        });
                      }];
  });
  return enif_make_atom(env, "ok");
}

// ── :activity_recognition permission (Motion & Fitness) ───────────────────
/* The CoreMotion objects of requests still waiting for the user's answer,
 * one per request so concurrent requests each get a reply. Main queue. */
static NSMutableSet *g_permission_requests;

static void send_permission(ErlNifPid pid, const char *status) {
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM msg =
      enif_make_tuple3(e, enif_make_atom(e, "permission"),
                       enif_make_atom(e, "activity_recognition"), enif_make_atom(e, status));
  enif_send(NULL, &pid, e, msg);
  enif_free_env(e);
}

/* Any queue. Replies once per request, however often its handler fires. */
static void finish_permission(id source, ErlNifPid pid) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (![g_permission_requests containsObject:source])
      return;
    [g_permission_requests removeObject:source];
    if ([source isKindOfClass:[CMAltimeter class]])
      [(CMAltimeter *)source stopRelativeAltitudeUpdates];
    BOOL ok = [CMAltimeter authorizationStatus] == CMAuthorizationStatusAuthorized;
    send_permission(pid, ok ? "granted" : "denied");
  });
}

/* iOS has no explicit "request motion permission" call: the first CoreMotion
 * query raises the prompt, and its completion runs after the user answers.
 * That query is a pedometer one where step counting exists, else (iPad) an
 * altimeter update, since the same grant gates the barometer. A device with
 * neither (the simulator) can't be authorized, so it reports :denied. */
static void mob_sensors_request_permission(ErlNifPid pid) {
  CMAuthorizationStatus status = [CMAltimeter authorizationStatus];
  if (status == CMAuthorizationStatusAuthorized) {
    send_permission(pid, "granted");
    return;
  }
  BOOL pedometer = [CMPedometer isStepCountingAvailable];
  if (motion_denied(status) || (!pedometer && ![CMAltimeter isRelativeAltitudeAvailable])) {
    send_permission(pid, "denied");
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    if (pedometer) {
      CMPedometer *p = [CMPedometer new];
      [g_permission_requests addObject:p];
      NSDate *now = [NSDate date];
      [p queryPedometerDataFromDate:[now dateByAddingTimeInterval:-60]
                             toDate:now
                        withHandler:^(CMPedometerData *d, NSError *err) {
                          (void)d;
                          (void)err;
                          finish_permission(p, pid);
                        }];
    } else {
      CMAltimeter *a = [CMAltimeter new];
      [g_permission_requests addObject:a];
      [a startRelativeAltitudeUpdatesToQueue:[NSOperationQueue mainQueue]
                                 withHandler:^(CMAltitudeData *d, NSError *err) {
                                   (void)d;
                                   (void)err;
                                   finish_permission(a, pid);
                                 }];
    }
  });
}

// ── NIF table ─────────────────────────────────────────────────────────────
static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info) {
  (void)env;
  (void)priv_data;
  (void)load_info;
  g_queue = dispatch_queue_create("io.mob.sensors", DISPATCH_QUEUE_SERIAL);
  g_regs = [NSMutableDictionary dictionary];
  g_ops = [NSOperationQueue new];
  g_ops.name = @"io.mob.sensors.updates";
  g_ops.maxConcurrentOperationCount = 1; // keep each stream's samples in order
  g_ops.underlyingQueue = g_queue;       // handlers share g_regs with start/stop
  g_motion = [CMMotionManager new];
  g_permission_requests = [NSMutableSet set];
  mob_register_permission_handler("activity_recognition", mob_sensors_request_permission);
  return 0;
}

static ErlNifFunc nif_funcs[] = {
    {"list", 0, nif_list, 0},
    {"start", 4, nif_start, 0},
    {"stop", 1, nif_stop, 0},
    {"stop_all", 0, nif_stop_all, 0},
    {"steps", 3, nif_steps, 0},
};

ERL_NIF_INIT(mob_sensors_nif, nif_funcs, load, NULL, NULL, NULL)
