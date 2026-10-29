"""GTK/AppIndicator tray application. All GTK work stays on the main thread."""

from concurrent.futures import ThreadPoolExecutor
import html
import logging
import signal
import time

from .core import parse_repo, parse_pr, parse_branches, pr_summary, run_summary
from .desktop import APP_ID, SPIN_FRAMES, Icons, autostart_path, load_gtk, set_autostart

Gtk, GLib, Gio, Notify, Indicator = load_gtk()
from gi.repository import GdkPixbuf
LOG = logging.getLogger(__name__)


def clip(value, limit=88):
    line = " ".join(str(value).split())
    return line if len(line) <= limit else line[:limit - 1].rstrip() + "…"


class PipelightApp(Gtk.Application):
    def __init__(self, monitor, demo=False):
        super().__init__(application_id=APP_ID + (".demo" if demo else ""), flags=Gio.ApplicationFlags.FLAGS_NONE)
        self.monitor = monitor
        self.demo = demo
        self.snapshot = monitor.snapshot()
        self.executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="pipelight")
        self.refreshing = False
        self.refresh_again = False
        self.loading_candidates = False
        self.timer = None
        self.frame = 0
        self.indicator = None
        self.dialogs = set()
        self.notifications = []
        self.stopping = False
        self.notice_error = None
        self.job_error = None
        self.icons = Icons(monitor.store.directory / "icons" if demo else None)
        self.connect("activate", self.activate_app)
        self.connect("shutdown", self.shutdown_app)

    def activate_app(self, *_):
        if self.indicator:
            return
        self.hold()
        Notify.init("Pipelight")
        self.indicator = Indicator.Indicator.new(APP_ID + (".demo" if self.demo else ""),
                                                self.icons.get("empty"), Indicator.IndicatorCategory.APPLICATION_STATUS)
        self.indicator.set_title("Pipelight")
        self.indicator.set_status(Indicator.IndicatorStatus.ACTIVE)
        self.rebuild()
        self.refresh()
        self.refresh_candidates()
        GLib.timeout_add(100, self.animate)
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, self.stop)
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, self.stop)
        # Refresh after suspend; GLib's timer alone can wait a full polling interval.
        try:
            self.system_bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
            self.system_bus.signal_subscribe("org.freedesktop.login1", "org.freedesktop.login1.Manager",
                                             "PrepareForSleep", "/org/freedesktop/login1", None,
                                             Gio.DBusSignalFlags.NONE, self.sleep_changed)
        except GLib.Error:
            LOG.debug("Sleep events unavailable")

    def sleep_changed(self, _bus, _sender, _path, _interface, _signal, params):
        if not params.unpack()[0]:
            GLib.timeout_add_seconds(5, self.refresh)

    def submit(self, operation, callback=None):
        def work():
            try:
                value = operation()
                return value, self.monitor.snapshot(), None
            except Exception as exc:
                LOG.warning("Operation failed: %s", exc)
                return None, self.monitor.snapshot(), exc

        future = self.executor.submit(work)

        def completed():
            if self.stopping:
                return GLib.SOURCE_REMOVE
            value, self.snapshot, error = future.result()
            if callback:
                callback(value, error)
            elif error:
                self.show_error(str(error))
            self.rebuild()
            return GLib.SOURCE_REMOVE

        future.add_done_callback(lambda _: GLib.idle_add(completed))

    def refresh(self, *_):
        if self.stopping:
            return GLib.SOURCE_REMOVE
        if self.refreshing:
            self.refresh_again = True
            return GLib.SOURCE_REMOVE
        if self.timer:
            GLib.source_remove(self.timer)
            self.timer = None
        self.refreshing = True
        self.rebuild()

        def finished(notices, error):
            self.refreshing = False
            self.job_error = str(error) if error else None
            for notice in notices or []:
                self.notify(notice)
            if self.refresh_again:
                self.refresh_again = False
                GLib.idle_add(self.refresh)
            else:
                self.timer = GLib.timeout_add_seconds(max(1, int(self.snapshot["interval"])), self.scheduled_refresh)

        self.submit(self.monitor.refresh, finished)
        return GLib.SOURCE_REMOVE

    def scheduled_refresh(self):
        self.timer = None
        return self.refresh()

    def refresh_candidates(self, *_):
        if self.loading_candidates:
            return
        self.loading_candidates = True

        def finished(_value, _error):
            self.loading_candidates = False

        self.submit(self.monitor.refresh_candidates, finished)

    def animate(self):
        if self.stopping:
            return GLib.SOURCE_REMOVE
        if self.snapshot["icon_state"].startswith("running"):
            self.frame = (self.frame + 1) % SPIN_FRAMES
            self.update_icon()
        return GLib.SOURCE_CONTINUE

    def update_icon(self):
        state = self.snapshot["icon_state"]
        frame = self.frame if state.startswith("running") else 0
        icon = self.icons.get(state, frame=frame)
        self.indicator.set_icon_full(icon, "Pipelight — " + state)

    def item(self, menu, label, callback=None, sensitive=True, icon=None, tooltip=None):
        if icon:
            # AppIndicator exports ImageMenuItem's pixbuf as D-Bus icon-data. Custom
            # widget layouts aren't exported, and emoji vary with the desktop font.
            item = Gtk.ImageMenuItem.new_with_label(label)
            pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_scale(icon, 20, 20, True)
            item.set_image(Gtk.Image.new_from_pixbuf(pixbuf))
            item.set_always_show_image(True)
        else:
            item = Gtk.MenuItem.new_with_label(label)
        item.set_sensitive(sensitive)
        if tooltip:
            item.set_tooltip_text(tooltip)
        if callback:
            item.connect("activate", lambda _: callback())
        menu.append(item)
        return item

    def separator(self, menu):
        menu.append(Gtk.SeparatorMenuItem())

    def submenu(self, menu, title):
        item = self.item(menu, title)
        child = Gtk.Menu()
        item.set_submenu(child)
        return child

    def rebuild(self):
        if not self.indicator or self.stopping:
            return
        snap, now = self.snapshot, time.time()
        menu = Gtk.Menu()
        if snap["queue"]:
            self.item(menu, "Fila de PRs", sensitive=False)
            for pr in snap["queue"]:
                error = snap["queue_errors"].get(pr.key)
                icon_state = "error" if error and pr.checks is None else pr.checks
                if not error and pr.signal == "ready":
                    icon_state = "ready"
                icon = self.icons.get(icon_state)
                label = f"{pr.short_name} — {pr_summary(pr, now)}"
                subtitle = ("Rascunho · " if pr.draft else "") + clip(pr.title, 72)
                self.item(menu, label + "\n" + ("⚠ " + clip(error) if error else subtitle),
                          lambda url=pr.url: self.open_url(url), icon=icon)
            self.separator(menu)
        for repo in snap["config"]["repos"]:
            self.item(menu, repo["repo"], sensitive=False)
            for target in (t for t in snap["targets"] if t.repo == repo["repo"]):
                status = snap["states"].get(target.key)
                error = snap["errors"].get(target.key)
                run = status.headline if status else None
                icon = self.icons.get("error" if error and not status else status.state if status else None)
                label = f"{target.branch} — {run_summary(status, now)}"
                if error:
                    label += "\n⚠ " + clip(error)
                elif run:
                    label += "\n" + clip((run.workflow + " · " if not target.workflow else "") + run.title)
                self.item(menu, label, lambda url=run.url if run and run.url else target.url: self.open_url(url), icon=icon)
            self.separator(menu)
        if not snap["targets"]:
            self.item(menu, "Adicionar um repositório para começar", self.add_repo_dialog,
                      tooltip="Clique para escolher o repositório, os branches e o workflow")
            self.separator(menu)
        add = self.submenu(menu, "Adicionar PR à fila")
        self.item(add, "Colar link do PR…", self.add_pr_dialog)
        self.item(add, "Atualizar sugestões", self.refresh_candidates)
        for key, title in (("mine", "Seus PRs abertos"), ("review", "Pedindo revisão a você ou seu time")):
            self.separator(add)
            self.item(add, title, sensitive=False)
            candidates = snap["candidates"][key]
            if not candidates:
                self.item(add, "Nenhum PR carregado — atualizar sugestões", sensitive=False)
            queued = {p.key for p in snap["queue"]}
            for candidate in candidates:
                repo, number = candidate["repository"]["nameWithOwner"], candidate["number"]
                exists = (repo.lower(), number) in queued
                label = ("✓ " if exists else "") + f"{repo.split('/')[-1]} #{number} · {clip(candidate['title'], 55)}"
                self.item(add, label, lambda r=repo, n=number, e=exists: self.toggle_pr(r, n, e))
        if snap["candidates"]["error"]:
            self.item(add, "⚠ " + clip(snap["candidates"]["error"]), sensitive=False)
        if snap["queue"]:
            remove = self.submenu(menu, "Tirar PR da fila")
            for pr in snap["queue"]:
                self.item(remove, pr.short_name, lambda key=pr.key: self.remove_prs({key}))
            self.separator(remove)
            self.item(remove, "Tirar os que já passaram", lambda: self.remove_prs({p.key for p in self.snapshot["queue"] if p.checks == "passed"}))
            self.item(remove, "Esvaziar a fila", lambda: self.remove_prs({p.key for p in self.snapshot["queue"]}))
        self.separator(menu)
        self.item(menu, "Atualizando…" if self.refreshing else "Atualizar agora", self.refresh, not self.refreshing)
        if snap["config"]["repos"]:
            self.item(menu, "Adicionar repositório…", self.add_repo_dialog)
            remove = self.submenu(menu, "Remover repositório")
            for repo in snap["config"]["repos"]:
                self.item(remove, repo["repo"], lambda r=repo["repo"]: self.change(lambda: self.monitor.remove_repo(r)))
        self.item(menu, "Editar config.json…", lambda: self.open_url((self.monitor.store.directory / "config.json").as_uri()))
        self.separator(menu)
        passed = Gtk.CheckMenuItem.new_with_label("Avisar também quando passar")
        passed.set_active(snap["settings"]["notifyPassed"])
        passed.connect("toggled", self.toggle_success)
        menu.append(passed)
        startup = Gtk.CheckMenuItem.new_with_label("Abrir ao iniciar o Linux")
        startup.set_active(autostart_path().exists() and not self.demo)
        startup.set_sensitive(not self.demo)
        startup.connect("toggled", self.toggle_autostart)
        menu.append(startup)
        self.separator(menu)
        for error in (snap["config_error"], snap["queue_error"], snap["settings_error"], self.notice_error, self.job_error):
            if error:
                self.item(menu, "⚠ " + clip(error, 110), sensitive=False)
        if snap["last_update"]:
            self.item(menu, "Atualizado às " + time.strftime("%H:%M:%S", time.localtime(snap["last_update"])), sensitive=False)
        if self.demo:
            self.item(menu, "Demonstração · dados fictícios", sensitive=False)
        self.item(menu, "Sobre o Pipelight", self.about)
        self.item(menu, "Sair do Pipelight", self.stop)
        menu.show_all()
        self.menu = menu
        self.indicator.set_menu(menu)
        self.update_icon()

    def toggle_autostart(self, item):
        try:
            set_autostart(item.get_active(), self.icons.get("passed"))
        except (OSError, ValueError) as exc:
            self.show_error(str(exc))
        self.rebuild()

    def toggle_success(self, item):
        enabled = item.get_active()
        self.submit(lambda: self.monitor.store.save_settings({**self.monitor.store.settings, "notifyPassed": enabled}))

    def open_url(self, url):
        # Only our config file and GitHub links are opened, never shell commands.
        from urllib.parse import urlparse
        parsed = urlparse(url)
        config_uri = (self.monitor.store.directory / "config.json").as_uri()
        if not (parsed.scheme == "https" and parsed.hostname == "github.com") and url != config_uri:
            self.show_error("Endereço inválido; use um link do GitHub.")
            return
        try:
            Gio.AppInfo.launch_default_for_uri(url, None)
        except GLib.Error as exc:
            self.show_error("Não foi possível abrir o endereço: " + str(exc))

    def notify(self, notice):
        if self.demo:
            return
        try:
            notification = Notify.Notification.new(notice.title, html.escape(notice.body), self.icons.get("failed" if notice.kind == "failed" else "passed"))
            notification.set_hint("desktop-entry", GLib.Variant("s", APP_ID))
            notification.set_hint("suppress-sound", GLib.Variant("b", not notice.sound))
            if notice.sound:
                notification.set_hint("sound-name", GLib.Variant("s", "dialog-warning" if notice.kind == "failed" else "message-new-instant"))
            notification.add_action("default", "Abrir no GitHub", lambda *_: self.open_url(notice.url), None)
            notification.connect("closed", lambda n: self.notifications.remove(n) if n in self.notifications else None)
            self.notifications.append(notification)
            notification.show()
            self.notice_error = None
        except GLib.Error:
            self.notice_error = "Não foi possível enviar a notificação; confira as configurações do sistema"
            LOG.warning("Notification service unavailable")

    def change(self, operation):
        def finished(_value, error):
            if error:
                self.show_error(str(error))
            else:
                self.refresh()
        self.submit(operation, finished)

    def remove_prs(self, keys):
        self.change(lambda: self.monitor.remove_prs(keys))

    def toggle_pr(self, repo, number, exists):
        if exists:
            self.remove_prs({(repo.lower(), number)})
        else:
            self.change(lambda: self.monitor.add_pr(repo, number))

    def form(self, title, fields, hint, submit):
        dialog = Gtk.Dialog(title=title)
        dialog.set_application(self)
        dialog.set_default_size(490, -1)
        dialog.set_resizable(False)
        dialog.set_position(Gtk.WindowPosition.CENTER)
        dialog.add_button("Cancelar", Gtk.ResponseType.CANCEL)
        dialog.add_button("Adicionar", Gtk.ResponseType.OK)
        dialog.set_default_response(Gtk.ResponseType.OK)
        box = dialog.get_content_area()
        box.set_border_width(20)
        box.set_spacing(12)
        description = Gtk.Label(label=hint, xalign=0)
        description.set_line_wrap(True)
        description.set_max_width_chars(62)
        box.add(description)
        entries = []
        for label, placeholder in fields:
            box.add(Gtk.Label(label=label, xalign=0))
            entry = Gtk.Entry()
            entry.set_placeholder_text(placeholder)
            entry.set_activates_default(True)
            box.add(entry)
            entries.append(entry)
        error_label = Gtk.Label(xalign=0)
        error_label.set_line_wrap(True)
        error_label.set_max_width_chars(62)
        box.add(error_label)

        def response(_dialog, response_id):
            if response_id != Gtk.ResponseType.OK:
                dialog.destroy()
                return
            try:
                operation = submit([entry.get_text() for entry in entries])
            except ValueError as exc:
                error_label.set_text(str(exc))
                return
            dialog.set_response_sensitive(Gtk.ResponseType.OK, False)
            for entry in entries:
                entry.set_sensitive(False)
            error_label.set_text("Verificando no GitHub…")

            def finished(_value, error):
                if dialog not in self.dialogs:
                    if not error:
                        self.refresh()
                    return
                if error:
                    dialog.set_response_sensitive(Gtk.ResponseType.OK, True)
                    for entry in entries:
                        entry.set_sensitive(True)
                    error_label.set_text(str(error))
                else:
                    dialog.destroy()
                    self.refresh()

            self.submit(operation, finished)

        self.dialogs.add(dialog)
        dialog.connect("destroy", lambda d: self.dialogs.discard(d))
        dialog.connect("response", response)
        dialog.show_all()
        dialog.present()
        entries[0].grab_focus()
        # Expose normal widgets for the local GTK smoke test, without a separate UI path.
        dialog.pipelight_entries = entries
        return dialog

    def add_repo_dialog(self):
        def prepare(values):
            repo = parse_repo(values[0])
            branches, workflow = parse_branches(values[1]), values[2].strip() or None
            return lambda: self.monitor.add_repo(repo, branches, workflow)
        return self.form("Adicionar repositório", [("Repositório", "dono/nome ou link do GitHub"),
                         ("Branches", "master, homolog — vazio usa o branch padrão"),
                         ("Workflow (opcional)", "CI, deploy.yml ou ID do workflow")],
                         "Acompanhe as execuções usando o login do seu GitHub CLI.", prepare)

    def add_pr_dialog(self):
        def prepare(values):
            repo, number = parse_pr(values[0])
            return lambda: self.monitor.add_pr(repo, number)
        return self.form("Adicionar PR à fila", [("Link do PR", "https://github.com/dono/nome/pull/123")],
                         "Receba um aviso quando o deploy do branch de destino terminar. Cole o link com Ctrl+V.", prepare)

    def show_error(self, message):
        dialog = Gtk.MessageDialog(message_type=Gtk.MessageType.ERROR, buttons=Gtk.ButtonsType.CLOSE,
                                   text="Pipelight")
        dialog.set_application(self)
        dialog.format_secondary_text(message)
        dialog.connect("response", lambda d, _: d.destroy())
        dialog.show_all()

    def about(self):
        from . import __version__
        dialog = Gtk.AboutDialog(program_name="Pipelight", version=__version__,
                                comments="GitHub Actions e fila de PRs na bandeja do Linux.",
                                website="https://github.com/victorreinor/pipelight",
                                authors=["Victor Reinor (projeto original)", "Port para Linux"],
                                license_type=Gtk.License.MIT_X11)
        dialog.set_application(self)
        dialog.connect("response", lambda d, _: d.destroy())
        dialog.show_all()

    def stop(self, *_):
        self.quit()
        return GLib.SOURCE_REMOVE

    def shutdown_app(self, *_):
        self.stopping = True
        if self.indicator:
            self.indicator.set_status(Indicator.IndicatorStatus.PASSIVE)
        self.executor.shutdown(wait=False, cancel_futures=True)
        Notify.uninit()
