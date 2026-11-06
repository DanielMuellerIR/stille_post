#include "app_controller.h"
#include <QLocalServer>
#include <QLocalSocket>
#include <csignal>
#include <fcntl.h>
#include <unistd.h>
#include <X11/Xlib.h>
namespace {
int shutdownSignal = -1;
void requestShutdown(int) {
  if (shutdownSignal >= 0) {
    const char byte = 1;
    const auto written = ::write(shutdownSignal, &byte, 1);
    (void)written;
  }
}
} // namespace
class KeyEventProbe final : public QWidget {
public:
  QLabel *label;
  KeyEventProbe() {
    setWindowTitle("Stille Post — Tastaturprüfung");
    auto layout = new QVBoxLayout(this);
    label = new QLabel("Bitte dieses Fenster anklicken und einmal "
                       "STRG+ALT+Leertaste drücken.");
    label->setWordWrap(true);
    layout->addWidget(label);
    resize(540, 140);
    setFocusPolicy(Qt::StrongFocus);
    auto keys = new GlobalShortcuts(this);
    QObject::connect(
        keys, &GlobalShortcuts::status, this, [this](QString text, bool) {
          label->setText(text + "\nBitte einmal STRG+ALT+Leertaste drücken.");
        });
    QObject::connect(keys, &GlobalShortcuts::pressed, this, [this](QString id) {
      label->setText("Globaler Tastendruck empfangen: " + id +
                     " — keine Aufnahme.");
      qInfo() << "GLOBAL PHYSICAL PROBE" << id;
    });
    QTimer::singleShot(300, keys, [keys] { keys->bind("CTRL+ALT+space", ""); });
  }

protected:
  void keyPressEvent(QKeyEvent *event) override {
    // Ausschließlich die angefragte Kombination prüfen, keine Texteingabe
    // mitschneiden.
    if (event->key() == Qt::Key_Space) {
      auto combination = QKeySequence(event->keyCombination())
                             .toString(QKeySequence::NativeText);
      label->setText("Lokales Ereignis empfangen: " + combination);
      qInfo().noquote()
          << QJsonDocument(
                 QJsonObject{
                     {"event", "keyCombination"},
                     {"combination", combination},
                     {"scan", int(event->nativeScanCode())},
                     {"virtualKey", int(event->nativeVirtualKey())},
                     {"nativeModifiers", int(event->nativeModifiers())}})
                 .toJson(QJsonDocument::Compact);
    }
    event->accept();
  }
};
int main(int argc, char **argv) {
  XInitThreads();
  if (qEnvironmentVariable("QT_QPA_PLATFORM").startsWith("wayland") ||
      (qEnvironmentVariable("QT_QPA_PLATFORM").isEmpty() &&
       qEnvironmentVariable("XDG_SESSION_TYPE") == "wayland"))
    qputenv("QT_WAYLAND_SHELL_INTEGRATION", "stillepost-shell");
  QApplication app(argc, argv);
  int signalPipe[2];
  if (::pipe2(signalPipe, O_CLOEXEC | O_NONBLOCK) == 0) {
    shutdownSignal = signalPipe[1];
    auto notifier =
        new QSocketNotifier(signalPipe[0], QSocketNotifier::Read, &app);
    QObject::connect(notifier, &QSocketNotifier::activated, &app,
                     [&app, notifier] {
                       notifier->setEnabled(false);
                       app.quit();
                     });
    struct sigaction action{};
    action.sa_handler = requestShutdown;
    sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, nullptr);
    sigaction(SIGINT, &action, nullptr);
    QObject::connect(&app, &QCoreApplication::aboutToQuit, &app,
                     [readFD = signalPipe[0], writeFD = signalPipe[1]] {
                       shutdownSignal = -1;
                       ::close(readFD);
                       ::close(writeFD);
                     });
  }
  app.setApplicationName("stillepost");
  app.setDesktopFileName("io.github.danielmuellerir.stillepost");
  app.setApplicationVersion(STILLEPOST_VERSION);
  if (app.arguments().contains("--key-event-probe")) {
    KeyEventProbe probe;
    probe.show();
    probe.activateWindow();
    probe.setFocus();
    QTimer::singleShot(180000, &app, &QCoreApplication::quit);
    return app.exec();
  }
  if (app.arguments().contains("--audio-devices")) {
    AudioInput input;
    QEventLoop wait;
    QObject::connect(&input, &AudioInput::devicesChanged, &wait, [&] {
      if (input.hasDeviceCatalog())
        wait.quit();
    });
    QTimer::singleShot(3500, &wait, &QEventLoop::quit);
    wait.exec();
    if (!input.hasDeviceCatalog())
      return 3;
    puts(QJsonDocument(input.devices())
             .toJson(QJsonDocument::Compact)
             .constData());
    return 0;
  }
  if (app.arguments().contains("--hotkey-probe")) {
    QWidget probeWindow;
    probeWindow.setWindowTitle("Stille Post – Hotkeyprüfung");
    probeWindow.setAttribute(Qt::WA_ShowWithoutActivating);
    probeWindow.setWindowFlag(Qt::WindowDoesNotAcceptFocus);
    auto probeLayout = new QVBoxLayout(&probeWindow);
    auto probeLabel = new QLabel("Tastenkürzel wird registriert …");
    probeLabel->setWordWrap(true);
    probeLayout->addWidget(probeLabel);
    probeWindow.resize(440, 110);
    probeWindow.show();
    GlobalShortcuts portal;
    X11Shortcuts x11;
    auto status = [probeLabel](QString text, bool ready) {
      probeLabel->setText(text);
      qInfo().noquote() << QJsonDocument(QJsonObject{{"event", "hotkeyStatus"},
                                                     {"ready", ready},
                                                     {"text", text}})
                               .toJson(QJsonDocument::Compact);
    };
    auto pressed = [&](QString id) {
      probeLabel->setText("Tastendruck empfangen: " + id +
                          " — keine Aufnahme.");
      qInfo().noquote() << QJsonDocument(
                               QJsonObject{{"event", "pressed"}, {"id", id}})
                               .toJson(QJsonDocument::Compact);
      QTimer::singleShot(1200, &app, &QCoreApplication::quit);
    };
    QObject::connect(&portal, &GlobalShortcuts::status, &app, status);
    QObject::connect(&x11, &X11Shortcuts::status, &app, status);
    QObject::connect(&portal, &GlobalShortcuts::pressed, &app, pressed);
    QObject::connect(&x11, &X11Shortcuts::pressed, &app, pressed);
    QTimer::singleShot(300, &app, [&] {
      if (QGuiApplication::platformName() == "xcb")
        x11.bind("CTRL+ALT+space", "");
      else
        portal.bind("CTRL+ALT+space", "");
    });
    QTimer::singleShot(180000, &app, [] { QCoreApplication::exit(8); });
    return app.exec();
  }
  const bool smoke = app.arguments().contains("--smoke-test") ||
                     app.arguments().contains("--pipeline-test") ||
                     qEnvironmentVariableIsSet("STILLEPOST_OVERLAY_PREVIEW");
  const bool multiple =
      smoke || qEnvironmentVariable("STILLEPOST_ALLOW_MULTIPLE") == "1";
  QString socket =
      QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation) +
      "/stillepost-" + QString::number(getuid()) +
      (multiple ? "-test-" + QString::number(getpid()) : QString());
  QLocalSocket client;
  client.connectToServer(socket);
  if (client.waitForConnected(200)) {
    client.write(app.arguments().contains("--toggle") ? "toggle" : "show");
    client.flush();
    client.waitForBytesWritten(500);
    return 0;
  }
  QLocalServer server;
  server.setSocketOptions(QLocalServer::UserAccessOption);
  QLocalServer::removeServer(socket);
  if (!server.listen(socket))
    return 1;
  loadTranslations();
  applyAppearance(app);
  AppController controller(smoke);
  QObject::connect(&server, &QLocalServer::newConnection, &app, [&] {
    auto connection = server.nextPendingConnection();
    QObject::connect(connection, &QLocalSocket::readyRead, &app,
                     [&, connection] {
                       auto command = connection->read(16);
                       if (command == "toggle")
                         controller.toggle();
                       else if (command == "show") {
                         controller.showSettings();
                       }
                       connection->disconnectFromServer();
                       connection->deleteLater();
                     });
  });
  return app.exec();
}
