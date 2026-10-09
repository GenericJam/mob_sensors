%% mob_sensors_nif — Erlang NIF module for the mob_sensors plugin.
%%
%% iOS: priv/native/ios/mob_sensors_nif.m (Objective-C: CMMotionManager,
%% CMAltimeter, CMPedometer, UIDevice proximity). Android:
%% priv/native/jni/mob_sensors_nif.zig (SensorManager via the
%% io.mob.sensors.MobSensorsBridge Kotlin bridge). Both register this module
%% via ERL_NIF_INIT and are statically linked into the host binary on device.
%% On a host build neither is linked, so on_load tolerates the failure and
%% every NIF raises nif_not_loaded (MobSensors treats that as :unavailable).
%%
%% Only MobSensors.Server calls these. Readings are sent to the process that
%% called start/4 or steps/3 (the server), tagged with the integer handle:
%%
%%   {mob_sensors_native, Handle, reading, [float()], UnixMs, Accuracy | nil}
%%   {mob_sensors_native, Handle, error, permission | unavailable | binary()}
%%   {mob_sensors_native, Handle, steps, Steps, DistanceM | nil, Floors | nil}
-module(mob_sensors_nif).
-export([list/0, start/4, stop/1, stop_all/0, steps/3]).
-on_load(init/0).

init() ->
    case erlang:load_nif("mob_sensors_nif", 0) of
        ok -> ok;
        {error, _} -> ok
    end.

%% JSON array (binary) describing every sensor the platform exposes.
%% Android answers {error, Reason} when it can't ask SensorManager:
%% bridge_not_registered (MobSensorsBridge.register() never ran or the
%% sensors_list lookup failed), no_activity (no Activity handed to the
%% bridge), no_jni_env, bridge_exception or string_unavailable. The server
%% maps that to []; MobSensors.SelfTest fails on it.
list() ->
    erlang:nif_error(nif_not_loaded).

%% start(Handle, TypeCode, StringType, PeriodUs) -> ok | unavailable | permission
%% TypeCode is the Android Sensor.TYPE_* integer, or -1 with StringType a
%% binary naming a vendor sensor (StringType is nil otherwise).
start(_Handle, _TypeCode, _StringType, _PeriodUs) ->
    erlang:nif_error(nif_not_loaded).

stop(_Handle) ->
    erlang:nif_error(nif_not_loaded).

stop_all() ->
    erlang:nif_error(nif_not_loaded).

%% steps(Handle, FromUnixMs, ToUnixMs) -> ok | unavailable | history_unavailable
steps(_Handle, _FromMs, _ToMs) ->
    erlang:nif_error(nif_not_loaded).
