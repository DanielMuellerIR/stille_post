#include "app_controller.h"
#include <QtTest>
#include <cmath>
#include <stdexcept>
namespace {
void check(bool value, const char *reason) {
  if (!value)
    throw std::runtime_error(reason);
}
void wait(std::function<bool()> condition) {
  QElapsedTimer timer;
  timer.start();
  while (!condition()) {
    check(timer.elapsed() < 5000, "Zeitlimit bei Fensteraktion");
    QCoreApplication::processEvents();
    QTest::qWait(10);
  }
}
QPushButton *control(QDialog *dialog, QString text) {
  for (auto button : dialog->findChildren<QPushButton *>())
    if (button->text() == text)
      return button;
  throw std::runtime_error("Schaltfläche fehlt");
}
QJsonDocument read(QString path) {
  QFile file(path);
  check(file.open(QIODevice::ReadOnly), "Gespeicherte Datei fehlt");
  return QJsonDocument::fromJson(file.readAll());
}
void run() {
  QTemporaryDir directory;
  const auto configPath = directory.path() + "/config.json";
  const auto historyPath = directory.path() + "/data/history.json";
  qputenv("STILLEPOST_CONFIG", configPath.toUtf8());
  qputenv("STILLEPOST_APP_SUPPORT", (directory.path() + "/data").toUtf8());
  QDir().mkpath(directory.path() + "/data");
  QFile config(configPath);
  check(config.open(QIODevice::WriteOnly), "Konfigurationsfixture fehlt");
  const QByteArray initial(
      R"({"whisper":{"autostart":false},"cleanup":{"enabled":false,"ollamaURL":"http://127.0.0.1:1","fallbacks":[{"ollamaURL":"http://127.0.0.1:1","model":"fixture-first"},{"ollamaURL":"http://127.0.0.1:1","model":"fixture-second"}]},"bridge":{"enabled":false},"linux":{"startAtLogin":false}})");
  auto configObject = QJsonDocument::fromJson(initial).object();
  auto whisper = configObject["whisper"].toObject();
  if (qEnvironmentVariableIsSet("STILLEPOST_TEST_WHISPER_URL"))
    whisper["serverURL"] = qEnvironmentVariable("STILLEPOST_TEST_WHISPER_URL");
  configObject["whisper"] = whisper;
  const QString missingUID = "pulse:c3RpbGxlcG9zdC1taXNzaW5nLWZpeHR1cmU=";
  configObject["audio"] =
      QJsonObject{{"inputDeviceUID", missingUID},
                  {"inputDeviceName", "Künstliches Testmikrofon"}};
  config.write(QJsonDocument(configObject).toJson());
  config.close();
  QFile entries(historyPath);
  check(entries.open(QIODevice::WriteOnly), "Verlaufsfixture fehlt");
  QJsonObject entry{
      {"id", "72222222-2222-4222-8222-222222222222"},
      {"date", QDateTime::currentDateTimeUtc().toString(Qt::ISODate)},
      {"rawText", "dies ist ein künstlicher test"},
      {"cleanText", "Dies ist ein künstlicher Test."},
      {"status", "ok"},
      {"durationSec", 2.0},
      {"storesText", true}};
  entries.write(QJsonDocument(QJsonArray{entry}).toJson());
  entries.close();
  AppController controller(true);
  SettingsWindow *settings = nullptr;
  HistoryWindow *history = nullptr;
  wait([&] {
    for (auto widget : QApplication::topLevelWidgets()) {
      if (auto value = qobject_cast<SettingsWindow *>(widget))
        settings = value;
      if (auto value = qobject_cast<HistoryWindow *>(widget))
        history = value;
    }
    return settings && history && settings->isVisible();
  });
  const auto keyStatus = trText("Globale Tastenkürzel aktiv: Ctrl+Meta+Space");
  check(keyStatus == (qEnvironmentVariable("STILLEPOST_LANGUAGE") == "en"
                          ? "Global shortcuts active: Ctrl+Meta+Space"
                          : "Globale Tastenkürzel aktiv: Ctrl+Meta+Space"),
        "Hotkeystatus ist nicht lokalisiert");
  auto device = settings->findChild<QComboBox *>("audio.inputDeviceUID");
  check(device && device->currentData().toString() == missingUID &&
            device->currentText().contains(trText("Nicht verfügbar: ")),
        "Fehlendes Mikrofon wird als Systemstandard angezeigt");
  qInfo() << "PASS unavailable-microphone-not-replaced";
  auto preview = settings->findChild<QCheckBox *>("ui.previewBeforePaste");
  check(preview, "Vorschauoption fehlt");
  preview->setChecked(true);
  QTest::mouseClick(control(settings, trKey("common.save", "Save")),
                    Qt::LeftButton);
  wait([&] {
    return read(configPath)
               .object()["ui"]
               .toObject()["previewBeforePaste"]
               .toBool() &&
           !settings->isVisible();
  });
  check(!settings->isVisible(), "Speichern schließt das Fenster nicht");
  qInfo() << "PASS settings-save";
  controller.showSettings();
  preview = settings->findChild<QCheckBox *>("ui.previewBeforePaste");
  check(preview && preview->isChecked(),
        "Gespeicherte Auswahl fehlt beim Wiederöffnen");
  preview->setChecked(false);
  QTest::mouseClick(control(settings, trKey("common.cancel", "Cancel")),
                    Qt::LeftButton);
  check(!settings->isVisible(), "Abbrechen schließt das Fenster nicht");
  check(
      read(configPath).object()["ui"].toObject()["previewBeforePaste"].toBool(),
      "Abbrechen verändert gespeicherte Auswahl");
  qInfo() << "PASS settings-cancel";
  controller.showSettings("profiles");
  auto create = settings->findChild<QPushButton *>("profiles.create");
  check(create, "Profilanlage fehlt");
  QTest::mouseClick(create, Qt::LeftButton);
  auto name = settings->findChild<QLineEdit *>("profiles.0.name");
  check(name, "Profilname fehlt");
  name->setText("Künstliches Fensterprofil");
  QTest::mouseClick(control(settings, trKey("common.save", "Save")),
                    Qt::LeftButton);
  wait([&] { return !settings->isVisible(); });
  auto profiles = read(configPath).object()["profiles"].toArray();
  check(profiles.size() == 1 &&
            profiles[0].toObject()["name"] == "Künstliches Fensterprofil",
        "Profil wurde nicht gespeichert");
  check(profiles[0].toObject()["cleanup"].isNull() ||
            !profiles[0].toObject().contains("cleanup"),
        "Neues Profil erbt Bereinigung nicht");
  controller.showSettings("apps");
  auto add = settings->findChild<QPushButton *>("apps.add");
  check(add && add->isEnabled(), "App-Zuordnung fehlt");
  QTest::mouseClick(add, Qt::LeftButton);
  auto rules = settings->findChild<QTableWidget *>("apps.rules");
  check(rules && rules->rowCount() == 1, "App-Regel fehlt");
  rules->item(0, 0)->setText("linux.windowfixture");
  QTest::mouseClick(control(settings, trKey("common.save", "Save")),
                    Qt::LeftButton);
  wait([&] { return !settings->isVisible(); });
  check(read(configPath)
                .object()["appProfiles"]
                .toObject()["linux.windowfixture"] ==
            profiles[0].toObject()["id"],
        "App-Regel wählt nicht das angelegte Profil");
  controller.showSettings("profiles");
  auto remove = settings->findChild<QPushButton *>("profiles.delete");
  check(remove, "Profillöschung fehlt");
  QTest::mouseClick(remove, Qt::LeftButton);
  QTest::mouseClick(control(settings, trKey("common.save", "Save")),
                    Qt::LeftButton);
  wait([&] { return !settings->isVisible(); });
  check(read(configPath).object()["profiles"].toArray().isEmpty() &&
            read(configPath).object()["appProfiles"].toObject().isEmpty(),
        "Profillöschung hinterlässt fremde App-Regel");
  qInfo() << "PASS profile-create-rule-delete";
  controller.showSettings("cleanup");
  auto up = settings->findChild<QPushButton *>("cleanup.fallbacks.1.up");
  check(up, "Fallback-Reihenfolge fehlt");
  QTest::mouseClick(up, Qt::LeftButton);
  QTest::mouseClick(control(settings, trKey("common.save", "Save")),
                    Qt::LeftButton);
  wait([&] { return !settings->isVisible(); });
  auto fallbacks =
      read(configPath).object()["cleanup"].toObject()["fallbacks"].toArray();
  check(fallbacks.size() == 2 &&
            fallbacks[0].toObject()["model"] == "fixture-second" &&
            fallbacks[1].toObject()["model"] == "fixture-first",
        "Fallbacks wurden beim Umordnen verändert");
  qInfo() << "PASS fallback-order";
  controller.showHistory();
  auto edit = history->findChild<QPushButton *>("historyEdit");
  check(edit, "Verlaufskorrektur fehlt");
  wait([&] { return edit->isEnabled(); });
  QTest::mouseClick(edit, Qt::LeftButton);
  QPlainTextEdit *draft = nullptr;
  wait([&] {
    return (draft = history->findChild<QPlainTextEdit *>("historyCorrection"));
  });
  const QString corrected = "Dies ist ein korrigierter künstlicher Test.";
  draft->setPlainText(corrected);
  auto dialog = qobject_cast<QDialog *>(draft->window());
  check(dialog, "Korrekturfenster fehlt");
  auto difference = dialog->findChild<QTextBrowser *>();
  check(difference, "Änderungsvergleich fehlt");
  wait([&] { return difference->toPlainText().contains("korrigierter"); });
  auto buttons = dialog->findChild<QDialogButtonBox *>();
  check(buttons && buttons->button(QDialogButtonBox::Save),
        "Korrektur lässt sich nicht speichern");
  QTest::mouseClick(buttons->button(QDialogButtonBox::Save), Qt::LeftButton);
  wait([&] {
    auto values = read(historyPath).array();
    return values.size() == 1 &&
           values[0].toObject()["cleanText"].toString() == corrected &&
           values[0].toObject()["rawText"] == "dies ist ein künstlicher test";
  });
  qInfo() << "PASS history-correction-and-difference";
  QAction *test = nullptr;
  wait([&] {
    for (auto widget : QApplication::topLevelWidgets())
      if (auto menu = qobject_cast<QMenu *>(widget))
        for (auto action : menu->actions())
          if (action->objectName() == "testDictation")
            test = action;
    return test && test->isEnabled();
  });
  test->trigger();
  TestDictationWindow *testWindow = nullptr;
  wait([&] {
    for (auto widget : QApplication::topLevelWidgets())
      if (auto candidate = qobject_cast<TestDictationWindow *>(widget))
        testWindow = candidate;
    return testWindow && testWindow->isVisible();
  });
  auto testStart = testWindow->findChild<QPushButton *>("startTestDictation");
  wait([&] { return testStart && testStart->isEnabled(); });
  check(!testWindow->findChild<QLabel *>("testProfile")->text().isEmpty(),
        "Testprofil ist vor der Aufnahme nicht sichtbar");
  QTest::mouseClick(testStart, Qt::LeftButton);
  auto testStatus = testWindow->findChild<QLabel *>("testDictationStatus");
  wait([&] { return testStatus->text() == trKey("test_dictation.failed"); });
  bool explainsMissingInput = false;
  for (auto label : testWindow->findChildren<QLabel *>())
    explainsMissingInput |= label->text() == trKey("test_dictation.no_input");
  check(explainsMissingInput && read(historyPath).array().size() == 1,
        "Fehlendes Mikrofon wird nicht ohne Seiteneffekt erklärt");
  auto report = control(testWindow, trKey("test_dictation.copy_report"));
  QTest::mouseClick(report, Qt::LeftButton);
  wait([&] {
    return QApplication::clipboard()->text().contains("test.state=failed");
  });
  check(!QApplication::clipboard()->text().contains(directory.path()) &&
            !QApplication::clipboard()->text().contains("künstlicher"),
        "Phasenbericht enthält Testtext oder privaten Pfad");
  testWindow->reject();
  qInfo() << "PASS reviewed-test-missing-microphone-and-redacted-report";
  if (qEnvironmentVariableIsSet("STILLEPOST_TEST_WHISPER_URL")) {
    QByteArray wav;
    QDataStream stream(&wav, QIODevice::WriteOnly);
    stream.setByteOrder(QDataStream::LittleEndian);
    stream.writeRawData("RIFF", 4);
    stream << quint32(36 + 64000);
    stream.writeRawData("WAVEfmt ", 8);
    stream << quint32(16) << quint16(1) << quint16(1) << quint32(16000)
           << quint32(32000) << quint16(2) << quint16(16);
    stream.writeRawData("data", 4);
    stream << quint32(64000);
    for (int i = 0; i < 32000; ++i)
      stream << qint16(10000 *
                       std::sin(i * 2 * 3.141592653589793 * 220 / 16000));
    const auto audioPath = directory.path() + "/fixture.wav";
    QFile audio(audioPath);
    check(audio.open(QIODevice::WriteOnly), "Audiodatei fehlt");
    audio.write(wav);
    audio.close();
    QAction *import = nullptr;
    for (auto widget : QApplication::topLevelWidgets())
      if (auto menu = qobject_cast<QMenu *>(widget))
        for (auto action : menu->actions())
          if (action->objectName() == "importAudio")
            import = action;
    check(import && import->isEnabled(), "Dateiimport fehlt");
    import->trigger();
    AudioImportWindow *window = nullptr;
    wait([&] {
      for (auto widget : QApplication::topLevelWidgets())
        if (auto candidate = qobject_cast<AudioImportWindow *>(widget))
          window = candidate;
      return window && window->isVisible();
    });
    auto choose = window->findChild<QPushButton *>("chooseImportFile");
    auto startImport = window->findChild<QPushButton *>("startAudioImport");
    check(choose && startImport, "Importansicht fehlt");
    bool chosen = false;
    QTimer::singleShot(100, [&] {
      for (auto widget : QApplication::topLevelWidgets())
        if (auto picker = qobject_cast<QFileDialog *>(widget)) {
          QObject::connect(picker, &QDialog::accepted,
                           [&chosen] { chosen = true; });
          picker->setDirectory(directory.path());
          QTimer::singleShot(200, picker, [picker, audioPath] {
            auto name = picker->findChild<QLineEdit *>("fileNameEdit");
            if (name)
              name->setText(audioPath);
            QMetaObject::invokeMethod(picker, "accept", Qt::DirectConnection);
          });
        }
    });
    QTimer deadline;
    deadline.setSingleShot(true);
    QObject::connect(&deadline, &QTimer::timeout, [] {
      for (auto widget : QApplication::topLevelWidgets())
        if (auto picker = qobject_cast<QFileDialog *>(widget))
          picker->reject();
    });
    deadline.start(4000);
    QTest::mouseClick(choose, Qt::LeftButton);
    deadline.stop();
    check(chosen, "Dateiauswahl wurde nicht übernommen");
    wait([&] { return startImport->isEnabled(); });
    check(read(historyPath).array().size() == 1,
          "Dateiauswahl startet ohne Bestätigung einen Import");
    QTest::mouseClick(startImport, Qt::LeftButton);
    auto result = window->findChild<QPlainTextEdit *>("audioImportResult");
    wait([&] {
      return result && result->toPlainText().contains("künstlicher");
    });
    check(result->isReadOnly(), "Importvorschau ist veränderbar");
    QFile original(audioPath);
    check(original.open(QIODevice::ReadOnly) && original.readAll() == wav,
          "Import verändert das Original");
    check(read(historyPath).array().size() == 2, "Importverlauf fehlt");
    qInfo() << "PASS audio-file-picker-reviewed-import-preview";
    auto refresh = window->findChild<QPushButton *>("refreshAudioImport");
    check(refresh, "Neuer Import fehlt");
    QTest::mouseClick(refresh, Qt::LeftButton);
    QMimeData invalid;
    invalid.setUrls(
        {QUrl::fromLocalFile(audioPath), QUrl::fromLocalFile(audioPath)});
    QDragEnterEvent rejected(QPoint(30, 30), Qt::CopyAction, &invalid,
                             Qt::LeftButton, Qt::NoModifier);
    QApplication::sendEvent(window, &rejected);
    check(!rejected.isAccepted() && read(historyPath).array().size() == 2,
          "Mehrere abgelegte Dateien werden angenommen");
    QMimeData valid;
    valid.setUrls({QUrl::fromLocalFile(audioPath)});
    QDragEnterEvent enter(QPoint(30, 30), Qt::CopyAction, &valid,
                          Qt::LeftButton, Qt::NoModifier);
    QApplication::sendEvent(window, &enter);
    check(enter.isAccepted(), "Lokaler Audiodateiabwurf wird nicht angenommen");
    QDropEvent drop(QPointF(30, 30), Qt::CopyAction, &valid, Qt::LeftButton,
                    Qt::NoModifier);
    QApplication::sendEvent(window, &drop);
    wait([&] { return startImport->isEnabled(); });
    check(result->toPlainText().isEmpty() &&
              read(historyPath).array().size() == 2,
          "Dateiabwurf startet ohne Bestätigung einen Import");
    QTest::mouseClick(startImport, Qt::LeftButton);
    wait([&] { return result->toPlainText().contains("künstlicher"); });
    check(read(historyPath).array().size() == 3,
          "Abgelegte Datei wird nicht importiert");
    qInfo() << "PASS audio-drop-validation-and-confirmation";
    window->reject();
  }
}
} // namespace
int main(int argc, char **argv) {
  QTemporaryDir desktop;
  qputenv("XDG_CONFIG_HOME", desktop.path().toUtf8());
  qputenv("XDG_CACHE_HOME", desktop.path().toUtf8());
  QCoreApplication::setAttribute(Qt::AA_DontUseNativeDialogs);
  QApplication app(argc, argv);
  loadTranslations();
  applyAppearance(app);
  try {
    run();
    return 0;
  } catch (const std::exception &error) {
    qCritical() << error.what();
    return 1;
  }
}
