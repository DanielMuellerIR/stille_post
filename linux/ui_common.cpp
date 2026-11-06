#include "ui_common.h"
#include <QWindow>
#include <QtDBus>
#include <QtGui/private/qguiapplication_p.h>
#include <QtWaylandClient/private/qwaylanddisplay_p.h>
#include <QtWaylandClient/private/qwaylandintegration_p.h>
namespace {
bool hasDataControl() {
  const auto integration = dynamic_cast<QtWaylandClient::QWaylandIntegration *>(
      QGuiApplicationPrivate::platformIntegration());
  if (!integration)
    return false;
  // Die Shell wird erst beim Anzeigen eines Fensters geladen. Diktate aus dem
  // Hintergrund brauchen die schon beim App-Start erfasste Wayland-Registry.
  const auto display = integration->display();
  return display->hasRegistryGlobal(u"zwlr_data_control_manager_v1") ||
         display->hasRegistryGlobal(u"ext_data_control_manager_v1");
}
} // namespace
static QJsonObject strings;
static QJsonObject literalStrings;
void loadTranslations() {
  auto requested = qEnvironmentVariable("STILLEPOST_LANGUAGE");
  if (requested.isEmpty()) {
    const auto path = qEnvironmentVariable(
        "STILLEPOST_CONFIG",
        QStandardPaths::writableLocation(QStandardPaths::ConfigLocation) +
            "/stillepost/config.json");
    QFile file(path);
    if (QFileInfo(file).isFile() && file.open(QIODevice::ReadOnly))
      requested = QJsonDocument::fromJson(file.read(1048576))
                      .object()["linux"]
                      .toObject()["language"]
                      .toString();
  }
  if (requested != "de" && requested != "en")
    requested = QLocale::system().name().left(2);
  const auto language = requested == "en" ? "en" : "de";
  QFile file(QCoreApplication::applicationDirPath() + "/../translations/" +
             language + ".json");
  if (file.open(QIODevice::ReadOnly))
    strings = QJsonDocument::fromJson(file.readAll()).object();
  if (requested == "en") {
    QFile literals(QCoreApplication::applicationDirPath() +
                   "/../translations/literal-en.json");
    if (literals.open(QIODevice::ReadOnly))
      literalStrings = QJsonDocument::fromJson(literals.readAll()).object();
  }
  qputenv("STILLEPOST_LANGUAGE", QByteArray(language));
  QLocale::setDefault(QLocale(language));
  auto qt = new QTranslator(qApp);
  if (qt->load(QString("qtbase_") + language,
               QCoreApplication::applicationDirPath() + "/../translations"))
    qApp->installTranslator(qt);
}
bool copyText(const QString &text) {
  if (qEnvironmentVariableIsSet("STILLEPOST_CLIPBOARD_TRACE"))
    qInfo() << "Clipboard attempt" << QGuiApplication::platformName()
            << hasDataControl() << text.size();
  if (QGuiApplication::platformName() == "wayland" &&
      hasDataControl()) {
    QProcess provider;
    provider.setProgram(QCoreApplication::applicationDirPath() + "/wl-copy");
    provider.setArguments({"--type", "text/plain;charset=utf-8"});
    provider.setStandardOutputFile(QProcess::nullDevice());
    provider.setStandardErrorFile(QProcess::nullDevice());
    provider.start();
    if (!provider.waitForStarted(1000))
      return false;
    provider.write(text.toUtf8());
    provider.closeWriteChannel();
    if (!provider.waitForFinished(2000)) {
      provider.kill();
      provider.waitForFinished(500);
      return false;
    }
    if (qEnvironmentVariableIsSet("STILLEPOST_CLIPBOARD_TRACE"))
      qInfo() << "Clipboard provider" << provider.exitStatus()
              << provider.exitCode();
    return provider.exitStatus() == QProcess::NormalExit &&
           provider.exitCode() == 0;
  }
  if (QGuiApplication::platformName() == "wayland" &&
      (!QGuiApplication::focusWindow() ||
       !QGuiApplication::focusWindow()->isActive()))
    return false;
  QApplication::clipboard()->setText(text);
  return QGuiApplication::platformName() == "offscreen" ||
         QApplication::clipboard()->ownsClipboard();
}
QString trText(QString text) {
  const auto exact = literalStrings.constFind(text);
  if (exact != literalStrings.constEnd())
    return exact->toString(text);
  for (const auto prefix :
       {"Globale Tastenkürzel aktiv: ", "App-Registrierung fehlgeschlagen: ",
        "Hotkey-Registrierung fehlgeschlagen: "}) {
    const auto value = QString::fromUtf8(prefix);
    if (text.startsWith(value))
      return literalStrings.value(value).toString(value) +
             text.mid(value.size());
  }
  return text;
}
QString trKey(const char *key, QString fallback) {
  return strings.value(QString::fromUtf8(key))
      .toString(fallback.isEmpty() ? QString::fromUtf8(key) : trText(fallback));
}
QString trFormat(const char *key, QStringList values) {
  auto text = trKey(key);
  for (auto value : values) {
    const auto index = text.indexOf(QRegularExpression("%[@d]"));
    if (index >= 0)
      text.replace(index, 2, value);
  }
  return text;
}
QString requestPolicyDescription(const QJsonObject &review) {
  const auto history = review.value("history").toObject();
  const bool stores = history.value("storeText").toBool(true);
  auto period = [](int days, const char *zero) {
    return days == 0 ? trKey(zero)
           : days == 1
               ? trKey("settings.history.day")
               : trFormat("settings.history.days", {QString::number(days)});
  };
  return trKey(stores ? "audio_import.history" : "audio_import.private") +
         "\n" +
         trFormat("audio_import.retention",
                  {stores ? period(history.value("textRetentionDays").toInt(),
                                   "settings.history.unlimited")
                          : trKey("audio_import.memory_only"),
                   period(history.value("audioRetentionDays").toInt(),
                          "settings.history.manual")}) +
         "\n" +
         (!review.value("cleanupEnabled").toBool()
              ? trKey("test_dictation.cleanup_local_off")
          : review.value("localOnly").toBool()
              ? trText("Audio und Bereinigung bleiben auf diesem Rechner.")
              : trText("Audio bleibt auf diesem Rechner. Nur der fertige Text "
                       "kann an konfigurierte Bereinigungsdienste übertragen "
                       "werden."));
}
QWidget *scrollPage(QWidget *content) {
  auto scroll = new QScrollArea;
  scroll->setWidgetResizable(true);
  scroll->setFrameShape(QFrame::NoFrame);
  scroll->setWidget(content);
  return scroll;
}
QGroupBox *section(QString title, QWidget *parent) {
  auto box = new QGroupBox(trText(title), parent);
  box->setObjectName("groupedSection");
  auto form = new QFormLayout(box);
  form->setContentsMargins(18, 22, 18, 18);
  form->setSpacing(12);
  form->setFieldGrowthPolicy(QFormLayout::ExpandingFieldsGrow);
  return box;
}
QString nativeDate(double seconds) {
  return QLocale().toString(
      QDateTime::fromSecsSinceEpoch(qint64(seconds) + 978307200),
      QLocale::ShortFormat);
}
QJsonValue jsonValue(const QJsonObject &object, QString path) {
  QJsonValue value(object);
  for (auto part : path.split('.'))
    value = value.isArray() ? value.toArray().at(part.toInt())
                            : value.toObject().value(part);
  return value;
}
static QJsonValue changed(QJsonValue node, const QStringList &parts, int index,
                          QJsonValue value) {
  if (index == parts.size())
    return value;
  if (node.isArray()) {
    auto array = node.toArray();
    const int selected = parts[index].toInt();
    if (selected < 0 || selected >= array.size())
      return node;
    array[selected] = changed(array[selected], parts, index + 1, value);
    return array;
  }
  auto object = node.toObject();
  object[parts[index]] =
      changed(object.value(parts[index]), parts, index + 1, value);
  return object;
}
void setJsonValue(QJsonObject &object, QString path, QJsonValue value) {
  object = changed(object, path.split('.'), 0, value).toObject();
}
class AppearanceWatcher final : public QObject {
  Q_OBJECT
public:
  explicit AppearanceWatcher(QApplication &app)
      : QObject(&app), application(app), light(app.style()->standardPalette()) {
    const auto fixed = qEnvironmentVariable("STILLEPOST_APPEARANCE");
    if (!fixed.isEmpty()) {
      apply(fixed == "dark");
      return;
    }
    auto bus = QDBusConnection::sessionBus();
    bus.connect("org.freedesktop.portal.Desktop",
                "/org/freedesktop/portal/desktop",
                "org.freedesktop.portal.Settings", "SettingChanged", this,
                SLOT(changed(QString, QString, QDBusVariant)));
    auto message = QDBusMessage::createMethodCall(
        "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.Settings", "Read");
    message.setArguments(
        {QString("org.freedesktop.appearance"), QString("color-scheme")});
    auto watcher = new QDBusPendingCallWatcher(bus.asyncCall(message), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, watcher] {
      QDBusPendingReply<QDBusVariant> reply = *watcher;
      if (!reply.isError())
        apply(reply.value().variant().toUInt() == 1);
      watcher->deleteLater();
    });
  }
private slots:
  void changed(QString group, QString key, QDBusVariant value) {
    if (group == "org.freedesktop.appearance" && key == "color-scheme")
      apply(value.variant().toUInt() == 1);
  }

private:
  void apply(bool dark) {
    auto palette = light;
    if (dark) {
      palette.setColor(QPalette::Window, QColor("#24272e"));
      palette.setColor(QPalette::WindowText, QColor("#f2f3f5"));
      palette.setColor(QPalette::Base, QColor("#191c22"));
      palette.setColor(QPalette::AlternateBase, QColor("#2b3038"));
      palette.setColor(QPalette::Text, QColor("#f2f3f5"));
      palette.setColor(QPalette::Button, QColor("#333842"));
      palette.setColor(QPalette::ButtonText, QColor("#f2f3f5"));
      palette.setColor(QPalette::Mid, QColor("#626a78"));
      palette.setColor(QPalette::Dark, QColor("#111318"));
      palette.setColor(QPalette::Light, QColor("#454c58"));
      palette.setColor(QPalette::Highlight, QColor("#2979de"));
      palette.setColor(QPalette::HighlightedText, Qt::white);
      palette.setColor(QPalette::PlaceholderText, QColor("#a4acba"));
      for (auto role :
           {QPalette::WindowText, QPalette::Text, QPalette::ButtonText})
        palette.setColor(QPalette::Disabled, role, QColor("#8e96a4"));
    }
    application.setPalette(palette);
  }
  QApplication &application;
  QPalette light;
};
void applyAppearance(QApplication &app) {
  app.setStyle("Fusion");
  new AppearanceWatcher(app);
  app.setStyleSheet(
      "QGroupBox#groupedSection {border:1px solid "
      "palette(mid);border-radius:10px;margin-top:22px;font-weight:600;} "
      "QGroupBox#groupedSection::title "
      "{subcontrol-origin:margin;left:8px;padding:0 5px;} QPushButton "
      "{padding:6px 14px;} QLineEdit,QComboBox,QSpinBox,QDoubleSpinBox "
      "{min-height:26px;} QTabWidget::pane {border:0;} QToolButton "
      "{padding:5px 10px;} QPlainTextEdit "
      "{selection-background-color:#1677e8;} "
      "QLabel[secondary=\"true\"]{color:palette(mid);}");
}

#include "ui_common.moc"
