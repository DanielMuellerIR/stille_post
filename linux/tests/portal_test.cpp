#include "hotkeys.h"
#include <QtTest>
#include <cstdio>
#include <stdexcept>
namespace {
const QString root = "/org/freedesktop/portal/desktop";
const QString service = "org.freedesktop.portal.Desktop";
void check(bool value, const char *reason) {
  if (!value)
    throw std::runtime_error(reason);
}
void wait(std::function<bool()> condition) {
  QElapsedTimer clock;
  clock.start();
  while (!condition()) {
    check(clock.elapsed() < 3000, "Zeitlimit beim Test-Portal");
    QTest::qWait(10);
  }
}
class Portal final : public QDBusVirtualObject {
public:
  QString introspect(const QString &) const override {
    return "<interface name=\"org.freedesktop.portal.Session\">"
           "<method name=\"Close\"/></interface>";
  }
  bool handleMessage(const QDBusMessage &message,
                     const QDBusConnection &bus) override {
    const auto method = message.member();
    const auto args = message.arguments();
    auto reply = [&](QList<QVariant> values = {}) {
      bus.send(message.createReply(values));
    };
    if (message.interface() == "org.stillepost.Test") {
      if (method == "Mode")
        mode = args[0].toInt();
      else if (method == "Activate" || method == "Deactivate") {
        auto signal = QDBusMessage::createSignal(
            root, "org.freedesktop.portal.GlobalShortcuts",
            method == "Activate" ? "Activated" : "Deactivated");
        signal.setArguments(
            {QVariant::fromValue(QDBusObjectPath(session)), QString("dictate"),
             QVariant::fromValue(qulonglong(1)), QVariantMap{}});
        bus.send(signal);
      } else if (method == "Close")
        close(bus, session);
      reply();
      return true;
    }
    if (method == "Register") {
      registered.insert(message.service());
      reply();
      return true;
    }
    if (method == "Close") {
      reply();
      return true;
    }
    if (method != "CreateSession" && method != "BindShortcuts")
      return false;
    if (!registered.contains(message.service())) {
      bus.send(message.createErrorReply(
          QDBusError::AccessDenied, "Registry muss zuerst aufgerufen werden"));
      return true;
    }
    const auto options = qdbus_cast<QVariantMap>(args.last());
    auto sender = message.service().mid(1).replace('.', '_');
    const auto path = root + "/request/" + sender + "/" +
                      options.value("handle_token").toString();
    reply({QVariant::fromValue(QDBusObjectPath(path))});
    QVariantMap result;
    uint code = 0;
    if (method == "CreateSession") {
      session = root + "/session/" + sender + "/" +
                options.value("session_handle_token").toString();
      result["session_handle"] = mode == 4 ? "/invalid" : session;
      if (mode == 1 || mode == 2)
        code = uint(mode);
    } else {
      PortalShortcuts keys{
          {"dictate", {{"trigger_description", "Ctrl+Meta+Space"}}},
          {"recall", {{"trigger_description", "Ctrl+Meta+Shift+Space"}}}};
      result["shortcuts"] = QVariant::fromValue(keys);
      if (mode == 3) {
        const auto closedSession = session;
        QTimer::singleShot(10, this, [this, bus, closedSession] {
          close(bus, closedSession);
        });
      }
    }
    QTimer::singleShot(mode == 3 && method == "BindShortcuts" ? 50 : 10, this,
                       [bus, path, result, code] {
                         auto signal = QDBusMessage::createSignal(
                             path, "org.freedesktop.portal.Request",
                             "Response");
                         signal.setArguments({code, result});
                         bus.send(signal);
                       });
    return true;
  }

private:
  void close(const QDBusConnection &bus, QString path) {
    auto signal = QDBusMessage::createSignal(
        path, "org.freedesktop.portal.Session", "Closed");
    signal.setArguments({QVariantMap{}});
    bus.send(signal);
  }
  int mode = 0;
  QString session;
  QSet<QString> registered;
};
void run() {
  QProcess server;
  auto start = [&] {
    server.start(QCoreApplication::applicationFilePath(), {"--server"});
    check(server.waitForStarted(2000) && server.waitForReadyRead(2000) &&
              server.readLine().trimmed() == "ready",
          "Getrenntes Test-Portal startet nicht");
  };
  auto control = [&](QString method, QList<QVariant> arguments = {}) {
    auto call = QDBusMessage::createMethodCall(service, root,
                                               "org.stillepost.Test", method);
    call.setArguments(arguments);
    check(QDBusConnection::sessionBus().call(call).type() !=
              QDBusMessage::ErrorMessage,
          "Test-Portal-Steuerung fehlgeschlagen");
  };
  try {
    start();
    {
      GlobalShortcuts portal;
      QSignalSpy pressed(&portal, &GlobalShortcuts::pressed);
      QSignalSpy released(&portal, &GlobalShortcuts::released);
      portal.bind();
      wait([&] { return portal.isReady(); });
      check(portal.shortcutLabels().value("dictate") == "Ctrl+Meta+Space",
            "Angezeigtes Kürzel entspricht nicht der Portalzuweisung");
      control("Activate");
      control("Activate");
      control("Deactivate");
      control("Deactivate");
      wait([&] { return !released.isEmpty(); });
      check(pressed.size() == 1 && released.size() == 1,
            "Portal liefert mehrfache Druck-/Loslassaktionen");
      qInfo() << "PASS registry-assignment-and-key-debounce";
      control("Close");
      wait([&] { return !portal.isReady(); });
      check(portal.shortcutLabels().isEmpty(),
            "Geschlossene Sitzung behält Zuweisungen");
      for (int mode : {1, 2, 4}) {
        control("Mode", {mode});
        portal.bind();
        wait([&] {
          return portal.description().contains(mode == 1   ? "abgebrochen"
                                               : mode == 2 ? "abgewiesen"
                                                           : "Ungültige");
        });
        check(!portal.isReady(), "Abgelehnte Sitzung ist aktiv");
      }
      qInfo() << "PASS cancelled-denied-and-invalid-session";
      control("Mode", {3});
      portal.bind();
      wait([&] { return portal.description().contains("geschlossen"); });
      QTest::qWait(150);
      check(!portal.isReady() && portal.shortcutLabels().isEmpty(),
            "Verspätete Antwort aktiviert geschlossene Sitzung");
      qInfo() << "PASS closed-session-rejects-late-bind-response";
      control("Mode", {0});
      portal.bind();
      wait([&] { return portal.isReady(); });
      server.terminate();
      check(server.waitForFinished(2000), "Test-Portal beendet sich nicht");
      wait([&] { return !portal.isReady(); });
      start();
      wait([&] { return portal.isReady(); });
      qInfo() << "PASS portal-owner-restart-registers-again";
    }
    QTest::qWait(20);
    server.terminate();
    server.waitForFinished(2000);
  } catch (...) {
    server.kill();
    server.waitForFinished(2000);
    throw;
  }
}
} // namespace
int main(int argc, char **argv) {
  QCoreApplication app(argc, argv);
  if (qEnvironmentVariable("STILLEPOST_TEST_ISOLATED_PORTAL") != "1") {
    qCritical() << "Nur mit einem eigenen dbus-run-session ausführen.";
    return 2;
  }
  qDBusRegisterMetaType<PortalShortcut>();
  qDBusRegisterMetaType<PortalShortcuts>();
  if (app.arguments().contains("--server")) {
    Portal portal;
    auto bus = QDBusConnection::sessionBus();
    if (!bus.registerService(service) ||
        !bus.registerVirtualObject(root, &portal, QDBusConnection::SubPath))
      return 2;
    puts("ready");
    fflush(stdout);
    return app.exec();
  }
  try {
    run();
    return 0;
  } catch (const std::exception &error) {
    qCritical() << error.what();
    return 1;
  }
}
