"""Isolated D-Bus desktop services for the GUI integration test (no real notifications)."""

import json

from gi.repository import Gio, GLib

XML = """<node><interface name="org.freedesktop.Notifications">
<method name="GetCapabilities"><arg type="as" direction="out"/></method>
<method name="GetServerInformation"><arg type="s" direction="out"/><arg type="s" direction="out"/><arg type="s" direction="out"/><arg type="s" direction="out"/></method>
<method name="Notify"><arg type="s" direction="in"/><arg type="u" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="as" direction="in"/><arg type="a{sv}" direction="in"/><arg type="i" direction="in"/><arg type="u" direction="out"/></method>
<method name="CloseNotification"><arg type="u" direction="in"/></method>
<signal name="ActionInvoked"><arg type="u"/><arg type="s"/></signal>
<signal name="NotificationClosed"><arg type="u"/><arg type="u"/></signal>
</interface></node>"""
WATCHER = """<node><interface name="org.kde.StatusNotifierWatcher">
<method name="RegisterStatusNotifierItem"><arg type="s" direction="in"/></method>
<method name="RegisterStatusNotifierHost"><arg type="s" direction="in"/></method>
<property name="RegisteredStatusNotifierItems" type="as" access="read"/>
<property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
<property name="ProtocolVersion" type="i" access="read"/>
</interface></node>"""
connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)
# Prevent the real portal daemon from starting its keyring/mount services in this test bus.
connection.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
                     GLib.Variant("(su)", ("org.freedesktop.portal.Desktop", 0)), None, Gio.DBusCallFlags.NONE, 2000, None)


def invoked(_conn, sender, path, interface, method, params, invocation):
    if method == "GetCapabilities":
        invocation.return_value(GLib.Variant("(as)", (["actions", "body", "body-markup", "sound"],)))
    elif method == "GetServerInformation":
        invocation.return_value(GLib.Variant("(ssss)", ("Pipelight test", "Test", "1", "1.2")))
    elif method == "Notify":
        values = params.unpack()
        print(json.dumps({"notification": values}, ensure_ascii=False), flush=True)
        invocation.return_value(GLib.Variant("(u)", (1,)))

        def activate():
            connection.emit_signal(sender, path, interface, "ActionInvoked", GLib.Variant("(us)", (1, "default")))
            return GLib.SOURCE_REMOVE
        GLib.timeout_add(100, activate)
    else:
        if method == "RegisterStatusNotifierItem":
            print(json.dumps({"indicator": params.unpack()[0]}), flush=True)
        invocation.return_value(None)


def property_value(_conn, _sender, _path, _interface, name):
    return {"RegisteredStatusNotifierItems": GLib.Variant("as", []),
            "IsStatusNotifierHostRegistered": GLib.Variant("b", True),
            "ProtocolVersion": GLib.Variant("i", 0)}[name]


for name, path, xml in [("org.freedesktop.Notifications", "/org/freedesktop/Notifications", XML),
                        ("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", WATCHER)]:
    connection.register_object(path, Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0], invoked, property_value, None)
    connection.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
                         GLib.Variant("(su)", (name, 0)), None, Gio.DBusCallFlags.NONE, 2000, None)
print("ready", flush=True)
GLib.MainLoop().run()
