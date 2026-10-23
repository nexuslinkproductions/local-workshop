#!/usr/bin/env python3
# mpris_stub.py LOG - a stub MPRIS player on the CURRENT session bus (run it under
# dbus-run-session, never on Marcel's bus). Owns org.mpris.MediaPlayer2.stub, starts
# Playing, title "Stub Song", artist "Stub Artist". Every method call and every status
# change is appended to LOG. org.mpris.MediaPlayer2.Quit ends it.
import sys

import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

LOG = sys.argv[1]
NAME = "org.mpris.MediaPlayer2.stub"
PATH = "/org/mpris/MediaPlayer2"
PLAYER = "org.mpris.MediaPlayer2.Player"
ROOT_IF = "org.mpris.MediaPlayer2"
XML = """
<node>
  <interface name="org.mpris.MediaPlayer2">
    <method name="Raise"/>
    <method name="Quit"/>
    <property name="CanQuit" type="b" access="read"/>
    <property name="CanRaise" type="b" access="read"/>
    <property name="HasTrackList" type="b" access="read"/>
    <property name="Identity" type="s" access="read"/>
    <property name="SupportedUriSchemes" type="as" access="read"/>
    <property name="SupportedMimeTypes" type="as" access="read"/>
  </interface>
  <interface name="org.mpris.MediaPlayer2.Player">
    <method name="PlayPause"/>
    <method name="Play"/>
    <method name="Pause"/>
    <method name="Stop"/>
    <property name="PlaybackStatus" type="s" access="read"/>
    <property name="Metadata" type="a{sv}" access="read"/>
    <property name="CanPlay" type="b" access="read"/>
    <property name="CanPause" type="b" access="read"/>
    <property name="CanControl" type="b" access="read"/>
    <property name="CanGoNext" type="b" access="read"/>
    <property name="CanGoPrevious" type="b" access="read"/>
    <property name="CanSeek" type="b" access="read"/>
    <property name="LoopStatus" type="s" access="read"/>
    <property name="Rate" type="d" access="read"/>
    <property name="MinimumRate" type="d" access="read"/>
    <property name="MaximumRate" type="d" access="read"/>
    <property name="Shuffle" type="b" access="read"/>
    <property name="Volume" type="d" access="read"/>
    <property name="Position" type="x" access="read"/>
  </interface>
</node>
"""

state = {"PlaybackStatus": "Playing"}
conn_holder = {}
loop = GLib.MainLoop()


def log(line):
    with open(LOG, "a") as fh:
        fh.write(line + "\n")


def metadata():
    return GLib.Variant("a{sv}", {
        "xesam:title": GLib.Variant("s", "Stub Song"),
        "xesam:artist": GLib.Variant("as", ["Stub Artist"]),
        "mpris:trackid": GLib.Variant("o", "/org/mpris/MediaPlayer2/track/1"),
    })


PLAYER_PROPS = {
    "PlaybackStatus": lambda: GLib.Variant("s", state["PlaybackStatus"]),
    "Metadata": metadata,
    "CanPlay": lambda: GLib.Variant("b", True),
    "CanPause": lambda: GLib.Variant("b", True),
    "CanControl": lambda: GLib.Variant("b", True),
    "CanGoNext": lambda: GLib.Variant("b", False),
    "CanGoPrevious": lambda: GLib.Variant("b", False),
    "CanSeek": lambda: GLib.Variant("b", False),
    "LoopStatus": lambda: GLib.Variant("s", "None"),
    "Rate": lambda: GLib.Variant("d", 1.0),
    "MinimumRate": lambda: GLib.Variant("d", 1.0),
    "MaximumRate": lambda: GLib.Variant("d", 1.0),
    "Shuffle": lambda: GLib.Variant("b", False),
    "Volume": lambda: GLib.Variant("d", 1.0),
    "Position": lambda: GLib.Variant("x", 0),
}
ROOT_PROPS = {
    "CanQuit": lambda: GLib.Variant("b", True),
    "CanRaise": lambda: GLib.Variant("b", False),
    "HasTrackList": lambda: GLib.Variant("b", False),
    "Identity": lambda: GLib.Variant("s", "Stub"),
    "SupportedUriSchemes": lambda: GLib.Variant("as", []),
    "SupportedMimeTypes": lambda: GLib.Variant("as", []),
}


def emit_status(conn):
    changed = {"PlaybackStatus": GLib.Variant("s", state["PlaybackStatus"])}
    conn.emit_signal(None, PATH, "org.freedesktop.DBus.Properties", "PropertiesChanged",
                     GLib.Variant("(sa{sv}as)", (PLAYER, changed, [])))
    log("STATUS " + state["PlaybackStatus"])


def on_method(conn, sender, obj_path, iface, method, params, invocation):
    log("CALL " + method)
    if method == "PlayPause":
        state["PlaybackStatus"] = "Paused" if state["PlaybackStatus"] == "Playing" else "Playing"
        emit_status(conn)
    elif method == "Play":
        state["PlaybackStatus"] = "Playing"
        emit_status(conn)
    elif method == "Pause":
        state["PlaybackStatus"] = "Paused"
        emit_status(conn)
    invocation.return_value(None)
    if method == "Quit":
        loop.quit()


def on_get(conn, sender, obj_path, iface, prop):
    table = PLAYER_PROPS if iface == PLAYER else ROOT_PROPS
    return table[prop]()


def on_bus(conn, name):
    conn_holder["conn"] = conn
    node = Gio.DBusNodeInfo.new_for_xml(XML)
    for info in node.interfaces:
        conn.register_object(PATH, info, on_method, on_get, None)
    log("READY " + NAME)


def on_lost(conn, name):
    log("NAME_LOST " + name)
    loop.quit()


Gio.bus_own_name(Gio.BusType.SESSION, NAME, Gio.BusNameOwnerFlags.NONE, on_bus, None, on_lost)
loop.run()
log("EXIT")
