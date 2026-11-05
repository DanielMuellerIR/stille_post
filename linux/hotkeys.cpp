#include "hotkeys.h"
QDBusArgument &operator<<(QDBusArgument &a, const PortalShortcut &s) {
  a.beginStructure();
  a << s.id << s.options;
  a.endStructure();
  return a;
}
const QDBusArgument &operator>>(const QDBusArgument &a, PortalShortcut &s) {
  a.beginStructure();
  a >> s.id >> s.options;
  a.endStructure();
  return a;
}
GlobalShortcuts::GlobalShortcuts(QObject *parent)
    : QObject(parent),
      bus(QDBusConnection::connectToBus(QDBusConnection::SessionBus,
                                        "stillepost.shortcuts")) {
  qDBusRegisterMetaType<PortalShortcut>();
  qDBusRegisterMetaType<PortalShortcuts>();
  sender = bus.baseService().mid(1).replace('.', '_');
  bus.connect("org.freedesktop.portal.Desktop", QString(),
              "org.freedesktop.portal.Request", "Response", this,
              SLOT(response(uint, QVariantMap, QDBusMessage)));
  bus.connect(
      "org.freedesktop.portal.Desktop", QString(),
      "org.freedesktop.portal.GlobalShortcuts", "Activated", this,
      SLOT(activated(QDBusObjectPath, QString, qulonglong, QVariantMap)));
  bus.connect(
      "org.freedesktop.portal.Desktop", QString(),
      "org.freedesktop.portal.GlobalShortcuts", "Deactivated", this,
      SLOT(deactivated(QDBusObjectPath, QString, qulonglong, QVariantMap)));
  bus.connect("org.freedesktop.portal.Desktop", QString(),
              "org.freedesktop.portal.GlobalShortcuts", "ShortcutsChanged",
              this, SLOT(shortcutsChanged(QDBusObjectPath, PortalShortcuts)));
  timeout.setSingleShot(true);
  timeout.setInterval(120000);
  connect(&timeout, &QTimer::timeout, this, [this] {
    setStatus("Hotkey-Freigabe steht noch aus. Registrierung erneut öffnen.");
  });
  auto watch =
      new QDBusServiceWatcher("org.freedesktop.portal.Desktop", bus,
                              QDBusServiceWatcher::WatchForOwnerChange, this);
  connect(watch, &QDBusServiceWatcher::serviceOwnerChanged, this,
          [this](QString, QString oldOwner, QString newOwner) {
            if (!oldOwner.isEmpty()) {
              ++generation;
              registered = false;
              registering = false;
              down.clear();
              ready = false;
              session = QDBusObjectPath();
              if (newOwner.isEmpty())
                setStatus(
                    "Hotkey-Dienst beendet. Aufnahmeschaltfläche verwenden.");
            }
            if (!newOwner.isEmpty() && !registering && !trigger.isEmpty())
              QTimer::singleShot(250, this,
                                 [this] { bind(trigger, recallTrigger); });
          });
}
GlobalShortcuts::~GlobalShortcuts() {
  closeSession();
  QDBusConnection::disconnectFromBus(bus.name());
}
void GlobalShortcuts::setStatus(QString text, bool value) {
  label = text;
  ready = value;
  emit status(text, value);
}
void GlobalShortcuts::closeSession() {
  timeout.stop();
  pendingMethod.clear();
  pendingPath.clear();
  if (!session.path().isEmpty())
    QDBusInterface("org.freedesktop.portal.Desktop", session.path(),
                   "org.freedesktop.portal.Session", bus)
        .asyncCall("Close");
  session = QDBusObjectPath();
  ready = false;
  down.clear();
  assigned.clear();
}
void GlobalShortcuts::bind(QString dictate, QString recall) {
  trigger = dictate;
  recallTrigger = recall;
  if (registering)
    return;
  closeSession();
  const auto epoch = ++generation;
  if (!registered) {
    registering = true;
    // DesktopFileName am Fenster identifiziert nicht automatisch diese eigene
    // D-Bus-Verbindung. Besonders Launcher-/Terminalstarts brauchen Registry.
    auto call = QDBusMessage::createMethodCall(
        "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
        "org.freedesktop.host.portal.Registry", "Register");
    call.setArguments(
        {QString("io.github.danielmuellerir.stillepost"), QVariantMap{}});
    auto watcher = new QDBusPendingCallWatcher(bus.asyncCall(call), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this,
            [this, watcher, epoch] {
              if (epoch != generation) {
                watcher->deleteLater();
                return;
              }
              QDBusPendingReply<> reply = *watcher;
              registering = false;
              if (reply.isError() &&
                  reply.error().type() != QDBusError::UnknownInterface &&
                  reply.error().type() != QDBusError::UnknownMethod) {
                setStatus("App-Registrierung fehlgeschlagen: " +
                          reply.error().message());
                watcher->deleteLater();
                return;
              }
              registered = true;
              watcher->deleteLater();
              bind(trigger, recallTrigger);
            });
    return;
  }
  const auto token = "stillepost" + QUuid::createUuid().toString(QUuid::Id128);
  setStatus("Globale Tastenkürzel werden registriert …");
  request("CreateSession",
          {QVariantMap{{"session_handle_token", token},
                       {"handle_token", token + "request"}}},
          token + "request");
}
void GlobalShortcuts::request(QString method, QList<QVariant> arguments,
                              QString token) {
  pendingMethod = method;
  const auto epoch = generation;
  pendingPath =
      "/org/freedesktop/portal/desktop/request/" + sender + "/" + token;
  auto call = QDBusMessage::createMethodCall(
      "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
      "org.freedesktop.portal.GlobalShortcuts", method);
  call.setArguments(arguments);
  auto watcher = new QDBusPendingCallWatcher(bus.asyncCall(call), this);
  connect(watcher, &QDBusPendingCallWatcher::finished, this,
          [this, watcher, method, epoch] {
            if (epoch != generation) {
              watcher->deleteLater();
              return;
            }
            QDBusPendingReply<QDBusObjectPath> reply = *watcher;
            if (reply.isError()) {
              timeout.stop();
              setStatus("Hotkey-Registrierung fehlgeschlagen: " +
                        reply.error().name() + QString(" — ") +
                        reply.error().message());
            } else if (method == pendingMethod)
              pendingPath = reply.value().path();
            watcher->deleteLater();
          });
  timeout.start();
}
void GlobalShortcuts::response(uint code, QVariantMap result,
                               const QDBusMessage &message) {
  if (message.path() != pendingPath)
    return;
  timeout.stop();
  if (code != 0) {
    setStatus(code == 1 ? "Hotkey-Freigabe abgebrochen. Erneut registrieren "
                          "oder Schaltfläche verwenden."
                        : "Hotkey-Portal hat die Registrierung abgewiesen.");
    return;
  }
  if (pendingMethod == "CreateSession") {
    // Die Spezifikation liefert session_handle ausdrücklich als String, nicht
    // als o.
    const QString value = result.value("session_handle").toString();
    if (!value.startsWith("/org/freedesktop/portal/desktop/session/")) {
      setStatus("Ungültige Hotkey-Sitzung.");
      return;
    }
    session = QDBusObjectPath(value);
    bus.connect("org.freedesktop.portal.Desktop", value,
                "org.freedesktop.portal.Session", "Closed", this,
                SLOT(closed(QVariantMap, QDBusMessage)));
    const auto token = "bind" + QUuid::createUuid().toString(QUuid::Id128);
    PortalShortcuts shortcuts{
        {"dictate",
         {{"description", QString("Diktat starten / stoppen")},
          {"preferred_trigger", trigger}}}};
    if (!recallTrigger.isEmpty())
      shortcuts.append(
          {"recall",
           {{"description", QString("Letzten Diktattext anzeigen")},
            {"preferred_trigger", recallTrigger}}});
    request("BindShortcuts",
            {QVariant::fromValue(session), QVariant::fromValue(shortcuts),
             QString(), QVariantMap{{"handle_token", token}}},
            token);
  } else if (pendingMethod == "BindShortcuts" ||
             pendingMethod == "ListShortcuts") {
    const auto shortcuts =
        qdbus_cast<PortalShortcuts>(result.value("shortcuts"));
    updateAssignments(shortcuts);
    pendingMethod.clear();
    pendingPath.clear();
  }
}
void GlobalShortcuts::updateAssignments(PortalShortcuts shortcuts) {
  assigned.clear();
  QStringList descriptions;
  for (const auto &shortcut : shortcuts) {
    auto label = shortcut.options.value("trigger_description").toString();
    assigned[shortcut.id] = label;
    if (!label.isEmpty())
      descriptions << label;
  }
  if (assigned.value("dictate").isEmpty()) {
    setStatus("Kein Diktierkürzel freigegeben. Bitte ein Kürzel auswählen.");
    return;
  }
  setStatus("Globale Tastenkürzel aktiv: " + descriptions.join(" · "), true);
}
void GlobalShortcuts::shortcutsChanged(QDBusObjectPath path,
                                       PortalShortcuts shortcuts) {
  if (path.path() == session.path())
    updateAssignments(shortcuts);
}
void GlobalShortcuts::activated(QDBusObjectPath path, QString id, qulonglong,
                                QVariantMap) {
  if (ready && path.path() == session.path() && !down.contains(id)) {
    down.insert(id);
    emit pressed(id);
  }
}
void GlobalShortcuts::deactivated(QDBusObjectPath path, QString id, qulonglong,
                                  QVariantMap) {
  if (ready && path.path() == session.path() && down.remove(id))
    emit released(id);
}
void GlobalShortcuts::closed(QVariantMap, const QDBusMessage &message) {
  if (message.path() != session.path())
    return;
  ++generation;
  timeout.stop();
  pendingMethod.clear();
  pendingPath.clear();
  ready = false;
  session = QDBusObjectPath();
  down.clear();
  assigned.clear();
  setStatus("Hotkey-Sitzung geschlossen. Erneut registrieren.");
}
void GlobalShortcuts::configure() {
  if (session.path().isEmpty()) {
    bind(trigger, recallTrigger);
    return;
  }
  auto call = QDBusMessage::createMethodCall(
      "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
      "org.freedesktop.portal.GlobalShortcuts", "ConfigureShortcuts");
  call.setArguments({QVariant::fromValue(session), QString(), QVariantMap{}});
  bus.asyncCall(call);
}
