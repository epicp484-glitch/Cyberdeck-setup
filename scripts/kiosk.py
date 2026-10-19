#!/usr/bin/env python3
"""Tiny fullscreen kiosk browser for AI mode (GTK 3 + WebKitGTK).

Much lighter than a full browser: one window, no tabs, no toolbars.

Keys:
  Ctrl+Q / Ctrl+W      leave (AI mode then returns to the normal desktop)
  F5 / Ctrl+R          reload
  Ctrl+Plus / Minus/0  zoom in / out / reset
  Alt+Left / Right     back / forward
  F11                  toggle fullscreen

Usage: kiosk.py [--zoom 1.0] [--data-dir DIR] [--windowed] URL
"""

import argparse
import os
import sys

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("WebKit2", "4.1")
from gi.repository import Gdk, GLib, Gtk, WebKit2  # noqa: E402

WAITING_PAGE = """<!doctype html><html><head><meta charset="utf-8">
<style>body{{background:#0d1117;color:#c9d1d9;font:20px sans-serif;display:flex;
align-items:center;justify-content:center;height:100vh;margin:0;text-align:center}}
small{{color:#8b949e}}</style></head><body><div><p>⏳ Starting the AI…</p>
<small>Waiting for {url}<br>Press Ctrl+Q to leave.</small></div></body></html>"""


class Kiosk:
    def __init__(self, url: str, zoom: float, data_dir: str, windowed: bool):
        self.url = url
        self.fullscreen = not windowed

        os.makedirs(data_dir, exist_ok=True)
        manager = WebKit2.WebsiteDataManager(
            base_data_directory=os.path.join(data_dir, "data"),
            base_cache_directory=os.path.join(data_dir, "cache"),
        )
        context = WebKit2.WebContext.new_with_website_data_manager(manager)
        # Smallest memory cache: we only ever show one page.
        context.set_cache_model(WebKit2.CacheModel.DOCUMENT_VIEWER)

        self.view = WebKit2.WebView.new_with_context(context)
        settings = self.view.get_settings()
        settings.set_enable_developer_extras(False)
        settings.set_enable_write_console_messages_to_stdout(False)
        settings.set_javascript_can_open_windows_automatically(False)
        settings.set_enable_back_forward_navigation_gestures(True)
        settings.set_media_playback_requires_user_gesture(True)
        self.view.set_zoom_level(zoom)
        self.view.connect("load-failed", self.on_load_failed)
        self.view.connect("decide-policy", self.on_decide_policy)
        self.view.connect("web-process-terminated", lambda *_: self.load())

        self.window = Gtk.Window(title="Cyberdeck AI")
        self.window.set_wmclass("cyberdeck-kiosk", "Cyberdeck-kiosk")
        self.window.set_default_size(1024, 600)
        self.window.add(self.view)
        self.window.connect("destroy", Gtk.main_quit)
        self.window.connect("key-press-event", self.on_key)
        if self.fullscreen:
            self.window.fullscreen()
        self.window.show_all()
        self.load()

    def load(self):
        self.view.load_uri(self.url)
        return False

    def on_load_failed(self, _view, _event, failing_uri, _error):
        # Open WebUI not up yet: show a friendly page and retry.
        if failing_uri.startswith(self.url.rstrip("/")):
            self.view.load_alternate_html(WAITING_PAGE.format(url=self.url), failing_uri, None)
            GLib.timeout_add_seconds(3, self.load)
            return True
        return False

    def on_decide_policy(self, _view, decision, decision_type):
        # Links that want a new window (e.g. citation links) open in this window instead.
        if decision_type == WebKit2.PolicyDecisionType.NEW_WINDOW_ACTION:
            request = decision.get_navigation_action().get_request()
            self.view.load_request(request)
            decision.ignore()
            return True
        return False

    def on_key(self, _widget, event):
        ctrl = event.state & Gdk.ModifierType.CONTROL_MASK
        alt = event.state & Gdk.ModifierType.MOD1_MASK
        key = Gdk.keyval_name(event.keyval) or ""
        if ctrl and key.lower() in ("q", "w"):
            Gtk.main_quit()
        elif key == "F5" or (ctrl and key.lower() == "r"):
            self.view.reload()
        elif ctrl and key in ("plus", "equal", "KP_Add"):
            self.view.set_zoom_level(min(3.0, self.view.get_zoom_level() + 0.1))
        elif ctrl and key in ("minus", "KP_Subtract"):
            self.view.set_zoom_level(max(0.5, self.view.get_zoom_level() - 0.1))
        elif ctrl and key in ("0", "KP_0"):
            self.view.set_zoom_level(1.0)
        elif alt and key == "Left":
            self.view.go_back()
        elif alt and key == "Right":
            self.view.go_forward()
        elif key == "F11":
            self.fullscreen = not self.fullscreen
            (self.window.fullscreen if self.fullscreen else self.window.unfullscreen)()
        else:
            return False
        return True


def main():
    p = argparse.ArgumentParser(description="Cyberdeck kiosk window")
    p.add_argument("url")
    p.add_argument("--zoom", type=float, default=1.0)
    p.add_argument("--data-dir", default=os.path.expanduser("~/.local/state/cyberdeck/kiosk-webkit"))
    p.add_argument("--windowed", action="store_true", help="normal window instead of fullscreen (testing)")
    args = p.parse_args()
    Kiosk(args.url, args.zoom, args.data_dir, args.windowed)
    try:
        Gtk.main()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
