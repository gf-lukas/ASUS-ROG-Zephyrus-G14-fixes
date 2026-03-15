#!/usr/bin/env /usr/bin/python3
import argparse
import math
import sys

from gi.repository import Gio, GLib


def select_output(monitors, requested_output):
    if requested_output and requested_output != "auto":
        return requested_output

    for monitor_spec, _modes, monitor_props in monitors:
        if bool(monitor_props.get("is-builtin", False)):
            return monitor_spec[0]

    if monitors:
        return monitors[0][0][0]

    return None


def best_mode_id_for_target(modes, current_mode_id, target_hz):
    current_mode = None
    for mode in modes:
        if mode[0] == current_mode_id:
            current_mode = mode
            break

    if current_mode is None:
        for mode in modes:
            if mode[6].get("is-current", False):
                current_mode = mode
                break

    if current_mode is None:
        return current_mode_id

    cur_width = int(current_mode[1])
    cur_height = int(current_mode[2])

    same_res_modes = [m for m in modes if int(m[1]) == cur_width and int(m[2]) == cur_height]
    candidates = same_res_modes if same_res_modes else modes

    best_mode = min(candidates, key=lambda m: (abs(float(m[3]) - target_hz), abs(float(m[3]) - float(current_mode[3]))))
    return best_mode[0]


def apply_refresh(target_hz, output):
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    proxy = Gio.DBusProxy.new_sync(
        bus,
        Gio.DBusProxyFlags.NONE,
        None,
        "org.gnome.Mutter.DisplayConfig",
        "/org/gnome/Mutter/DisplayConfig",
        "org.gnome.Mutter.DisplayConfig",
        None,
    )

    state = proxy.call_sync("GetCurrentState", None, Gio.DBusCallFlags.NONE, -1, None)
    serial, monitors, logical_monitors, _props = state.unpack()

    connector_to_monitor = {tuple(monitor_spec): (monitor_spec, modes, monitor_props) for monitor_spec, modes, monitor_props in monitors}
    target_output = select_output(monitors, output)
    if not target_output:
        raise RuntimeError("No monitor outputs found")

    new_logical_monitors = []
    changed = False

    for logical in logical_monitors:
        x, y, scale, transform, primary, monitor_specs, logical_props = logical
        new_monitor_cfgs = []

        for monitor_spec in monitor_specs:
            monitor_data = connector_to_monitor.get(tuple(monitor_spec))
            if monitor_data is None:
                continue

            connector, _vendor, _product, _serial = monitor_data[0]
            modes = monitor_data[1]

            current_mode_id = None
            for mode in modes:
                if mode[6].get("is-current", False):
                    current_mode_id = mode[0]
                    break

            if current_mode_id is None:
                current_mode_id = modes[0][0]

            selected_mode_id = current_mode_id
            if connector == target_output:
                selected_mode_id = best_mode_id_for_target(modes, current_mode_id, target_hz)
                if selected_mode_id != current_mode_id:
                    changed = True

            new_monitor_cfgs.append((connector, selected_mode_id, {}))

        new_logical_monitors.append((x, y, scale, transform, primary, new_monitor_cfgs))

    if not changed:
        return target_output, False

    params = GLib.Variant("(uua(iiduba(ssa{sv}))a{sv})", (int(serial), 1, new_logical_monitors, {}))
    proxy.call_sync("ApplyMonitorsConfig", params, Gio.DBusCallFlags.NONE, -1, None)
    return target_output, True


def main():
    parser = argparse.ArgumentParser(prog="g14-set-refresh.py")
    parser.add_argument("--hz", required=True, type=float)
    parser.add_argument("--output", default="auto")
    args = parser.parse_args()

    if args.hz <= 0 or not math.isfinite(args.hz):
        print("Invalid --hz value", file=sys.stderr)
        return 2

    try:
        output, changed = apply_refresh(args.hz, args.output)
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        return 1

    if changed:
        print(f"applied output={output} hz={args.hz:g}")
    else:
        print(f"unchanged output={output} hz={args.hz:g}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
