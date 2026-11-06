#include "accessibility.h"
#include "ui_common.h"
#include <QtDBus>
#include <QtTest>
#include <QtWidgets>
#include <unistd.h>
#include <X11/Xlib.h>
namespace {
int runTarget(QApplication &app) {
  QAccessible::setActive(true);
  QWidget window;
  window.setWindowTitle("StillePostTargetFixture");
  auto layout = new QVBoxLayout(&window);
  auto text = new QLineEdit("eins 🐧 zwei");
  auto other = new QLineEdit("Anderes Testfeld");
  auto password = new QLineEdit("synthetisch");
  auto rich = new QTextEdit;
  bool race = false;
  QObject::connect(rich, &QTextEdit::textChanged, &window, [&] {
    if (race) {
      race = false;
      QTextCursor cursor(rich->document());
      cursor.movePosition(QTextCursor::End);
      cursor.insertText("!");
    }
  });
  password->setEchoMode(QLineEdit::Password);
  // Tiefe Web-Formulare auch mit den nativen Schutzprüfungen abdecken.
  auto nested = new QWidget;
  layout->addWidget(nested);
  for (int depth = 0; depth < 20; depth++) {
    auto row = new QVBoxLayout(nested);
    row->setContentsMargins(0, 0, 0, 0);
    auto child = new QWidget;
    row->addWidget(child);
    nested = child;
  }
  auto deepLayout = new QVBoxLayout(nested);
  deepLayout->setContentsMargins(0, 0, 0, 0);
  deepLayout->addWidget(text);
  layout->addWidget(other);
  layout->addWidget(password);
  layout->addWidget(rich);
  QByteArray pending;
  std::unique_ptr<QMimeData> savedClipboard;
  QSocketNotifier input(STDIN_FILENO, QSocketNotifier::Read);
  auto reply = [](QJsonObject value) {
    auto data = QJsonDocument(value).toJson(QJsonDocument::Compact) + '\n';
    ::write(STDOUT_FILENO, data.constData(), data.size());
  };
  QObject::connect(&input, &QSocketNotifier::activated, &app, [&] {
    char bytes[4096];
    auto count = ::read(STDIN_FILENO, bytes, sizeof(bytes));
    if (count <= 0) {
      app.quit();
      return;
    }
    pending.append(bytes, count);
    while (pending.contains('\n')) {
      auto index = pending.indexOf('\n');
      auto value = QJsonDocument::fromJson(pending.left(index)).object();
      pending.remove(0, index + 1);
      const auto action = value["action"].toString();
      if (action == "clipboard-save") {
        auto copy = std::make_unique<QMimeData>();
        const auto source = app.clipboard()->mimeData();
        qsizetype total = 0;
        bool bounded = window.isActiveWindow();
        if (source) {
          bounded &= source->formats().size() <= 32;
          for (const auto &format : source->formats()) {
            const auto data = source->data(format);
            total += data.size();
            if (total > 8 * 1024 * 1024) {
              bounded = false;
              break;
            }
            copy->setData(format, data);
          }
        }
        if (bounded)
          savedClipboard = std::move(copy);
        reply({{"saved", bounded}});
        continue;
      }
      if (action == "clipboard-equals") {
        reply({{"matches",
                app.clipboard()->text() == value["expected"].toString()}});
        continue;
      }
      if (action == "clipboard-restore") {
        const bool canRestore = savedClipboard && window.isActiveWindow();
        if (canRestore) {
          app.clipboard()->setMimeData(savedClipboard.release());
          QGuiApplication::sync();
          QTest::qWait(250);
        }
        reply({{"restored", canRestore}});
        continue;
      }
      if (action == "text") {
        text->setReadOnly(false);
        text->setText(value["text"].toString());
        text->setFocus();
        if (value.contains("start"))
          text->setSelection(value["start"].toInt(), value["length"].toInt());
        else
          text->setCursorPosition(text->text().size());
      } else if (action == "other")
        other->setFocus();
      else if (action == "password")
        password->setFocus();
      else if (action == "readonly") {
        text->setFocus();
        text->setReadOnly(true);
      } else if (action == "rich" || action == "race") {
        race = false;
        rich->setHtml("<p><b>fett</b> normal 🐧 zwei</p>");
        rich->setFocus();
        auto cursor = rich->textCursor();
        cursor.setPosition(rich->toPlainText().indexOf("zwei"));
        cursor.movePosition(QTextCursor::Right, QTextCursor::KeepAnchor, 4);
        rich->setTextCursor(cursor);
        race = action == "race";
      }
      QTextCursor probe(rich->document());
      probe.setPosition(1);
      reply({{"text", text->text()},
             {"other", other->text()},
             {"rich", rich->toPlainText()},
             {"bold", probe.charFormat().fontWeight() >= QFont::Bold},
             {"active", window.isActiveWindow()}});
    }
  });
  window.show();
  window.activateWindow();
  text->setFocus();
  QTimer::singleShot(500, &window, [&] { reply({{"ready", true}}); });
  return app.exec();
}
class InsertionTests : public QObject {
  Q_OBJECT
private:
  QProcess fixture;
  AccessibleTarget target;
  QByteArray pending;
  QTemporaryDir directory;
  bool modified = false;
  QJsonObject waitReply() {
    QElapsedTimer clock;
    clock.start();
    while (clock.elapsed() < 4000) {
      pending += fixture.readAllStandardOutput();
      auto index = pending.indexOf('\n');
      if (index >= 0) {
        auto data = pending.left(index);
        pending.remove(0, index + 1);
        return QJsonDocument::fromJson(data).object();
      }
      QTest::qWait(20);
    }
    return {};
  }
  QJsonObject command(QJsonObject value) {
    fixture.write(QJsonDocument(value).toJson(QJsonDocument::Compact) + '\n');
    return waitReply();
  }
  QJsonObject capture(bool selection = false) {
    QSignalSpy spy(&target, &AccessibleTarget::captured);
    target.capture("test", selection);
    if (!spy.wait(4000))
      return {};
    return spy.takeFirst()[0].toJsonObject();
  }
  bool insert(QString token, QString text) {
    QSignalSpy spy(&target, &AccessibleTarget::inserted);
    target.insert(token, text);
    if (!spy.wait(4000))
      return false;
    auto result = spy.takeFirst();
    modified = result[3].toBool();
    if (!result[1].toBool())
      qInfo() << "Insertion refused:" << result[2].toString()
              << command({{"action", "get"}});
    return result[1].toBool();
  }
private slots:
  void initTestCase() {
    fixture.setProcessChannelMode(QProcess::ForwardedErrorChannel);
    if (qEnvironmentVariableIsSet("STILLEPOST_TEST_A11Y_DISCOVERY")) {
      auto environment = QProcessEnvironment::systemEnvironment();
      environment.remove("AT_SPI_BUS_ADDRESS");
      fixture.setProcessEnvironment(environment);
    }
    fixture.start(QCoreApplication::applicationFilePath(), {"--target"});
    QVERIFY(fixture.waitForStarted());
    QVERIFY(waitReply()["ready"].toBool());
    if (QGuiApplication::platformName() == "wayland") {
      QTemporaryFile script(directory.path() + "/focus-XXXXXX.js");
      QVERIFY(script.open());
      script.write(QString("workspace.windowList().filter(w=>w.pid===%1)."
                           "forEach(w=>workspace.activeWindow=w);\n")
                       .arg(fixture.processId())
                       .toUtf8());
      script.flush();
      auto bus = QDBusConnection::connectToBus(
          qEnvironmentVariable("STILLEPOST_TEST_KWIN_BUS"),
          "stillepost.test-focus");
      QDBusInterface service("org.kde.KWin", "/Scripting",
                             "org.kde.kwin.Scripting", bus);
      const auto name =
          "stillepost-test-" + QUuid::createUuid().toString(QUuid::Id128);
      QDBusReply<int> loaded =
          service.call("loadScript", script.fileName(), name);
      QVERIFY(loaded.isValid());
      QDBusInterface runner(
          "org.kde.KWin", "/Scripting/Script" + QString::number(loaded.value()),
          "org.kde.kwin.Script", bus);
      const auto result = runner.call("run");
      QTest::qWait(250);
      service.call("unloadScript", name);
      QVERIFY(result.type() != QDBusMessage::ErrorMessage);
    } else {
      QCOMPARE(QProcess::execute("xdotool",
                                 {"search", "--name", "StillePostTargetFixture",
                                  "windowfocus", "--sync"}),
               0);
    }
    QTest::qWait(500);
    QVERIFY2(command({{"action", "get"}})["active"].toBool(),
             "Testfenster hat keinen Fokus erhalten");
  }
  void cleanupTestCase() {
    fixture.closeWriteChannel();
    if (!fixture.waitForFinished(2000)) {
      fixture.kill();
      fixture.waitForFinished();
    }
  }
  void plainInsertion() {
    command({{"action", "text"}, {"text", "Test "}});
    QTest::qWait(100);
    auto value = capture();
    QVERIFY2(!value["token"].toString().isEmpty(),
             qPrintable(value["reason"].toString()));
    QVERIFY(insert(value["token"].toString(), "gelungen"));
    QCOMPARE(command({{"action", "get"}})["text"].toString(),
             QString("Test gelungen"));
  }
  void unicodeIntoAsciiField() {
    command({{"action", "text"}, {"text", "Test "}});
    QTest::qWait(100);
    auto value = capture();
    QVERIFY(!value["token"].toString().isEmpty());
    QVERIFY(insert(value["token"].toString(), "Grüße 🦊"));
    QCOMPARE(command({{"action", "get"}})["text"].toString(),
             QString("Test Grüße 🦊"));
  }
  void emojiSelection() {
    command({{"action", "text"},
             {"text", "eins 🐧 zwei"},
             {"start", 8},
             {"length", 4}});
    QTest::qWait(100);
    auto value = capture(true);
    QVERIFY2(!value["token"].toString().isEmpty(),
             qPrintable(value["reason"].toString()));
    QCOMPARE(value["selection"].toString(), QString("zwei"));
    QVERIFY(insert(value["token"].toString(), "drei 🦊"));
    QCOMPARE(command({{"action", "get"}})["text"].toString(),
             QString("eins 🐧 drei 🦊"));
  }
  void changedFieldIsProtected() {
    command({{"action", "text"}, {"text", "Ursprung"}});
    QTest::qWait(100);
    auto value = capture();
    QVERIFY(!value["token"].toString().isEmpty());
    command({{"action", "text"}, {"text", "Manuelle Änderung"}});
    QVERIFY(!insert(value["token"].toString(), "Falsches Ergebnis"));
    QCOMPARE(command({{"action", "get"}})["text"].toString(),
             QString("Manuelle Änderung"));
  }
  void changedFocusIsProtected() {
    command({{"action", "text"}, {"text", "Ursprung"}});
    QTest::qWait(100);
    auto value = capture();
    QVERIFY(!value["token"].toString().isEmpty());
    command({{"action", "other"}});
    QTest::qWait(100);
    QVERIFY(!insert(value["token"].toString(), "Falsches Ergebnis"));
    QCOMPARE(command({{"action", "get"}})["text"].toString(),
             QString("Ursprung"));
  }
  void passwordIsNeverRead() {
    command({{"action", "password"}});
    QTest::qWait(100);
    auto value = capture(true);
    QVERIFY(value["token"].toString().isEmpty());
    QVERIFY(!value.contains("selection"));
  }
  void readonlyIsNeverWritten() {
    command({{"action", "readonly"}});
    QTest::qWait(100);
    auto value = capture();
    QVERIFY(!value["editable"].toBool());
    if (!value["token"].toString().isEmpty())
      QVERIFY(!insert(value["token"].toString(), "Falsches Ergebnis"));
  }
  void readonlyChangeAfterCaptureIsProtected() {
    command({{"action", "text"}, {"text", "Ursprung"}});
    QTest::qWait(100);
    auto value = capture();
    QVERIFY(!value["token"].toString().isEmpty());
    command({{"action", "readonly"}});
    QTest::qWait(100);
    QVERIFY(!insert(value["token"].toString(), "Falsches Ergebnis"));
    QCOMPARE(command({{"action", "get"}})["text"].toString(),
             QString("Ursprung"));
  }
  void richTextKeepsUnchangedFormatting() {
    command({{"action", "rich"}});
    QTest::qWait(100);
    auto value = capture(true);
    QVERIFY2(!value["token"].toString().isEmpty(),
             qPrintable(value["reason"].toString()));
    QCOMPARE(value["selection"].toString(), QString("zwei"));
    QVERIFY(insert(value["token"].toString(), "drei 🦊"));
    auto result = command({{"action", "get"}});
    QCOMPARE(result["rich"].toString(), QString("fett normal 🐧 drei 🦊"));
    QVERIFY(result["bold"].toBool());
  }
  void concurrentEditNeverDeletesOriginalSelection() {
    command({{"action", "race"}});
    QTest::qWait(100);
    auto value = capture(true);
    QVERIFY(!value["token"].toString().isEmpty());
    QVERIFY(!insert(value["token"].toString(), "drei 🦊"));
    QVERIFY(modified);
    auto result = command({{"action", "get"}});
    QVERIFY(result["rich"].toString().contains("zwei"));
    QVERIFY(result["rich"].toString().contains("!"));
    QVERIFY(result["bold"].toBool());
  }
};
} // namespace
int main(int argc, char **argv) {
  XInitThreads();
  QApplication app(argc, argv);
  if (app.arguments().contains("--clipboard-only")) {
    if (QApplication::focusWindow())
      return 2;
    return copyText("Stille-Post-Einfügetest 🐧.") ? 0 : 3;
  }
  if (app.arguments().contains("--target"))
    return runTarget(app);
  if (app.arguments().contains("--external-target")) {
    AccessibleTarget target;
    auto saved = std::make_unique<QMimeData>();
    const auto source = app.clipboard()->mimeData();
    qsizetype bytes = 0;
    if (source) {
      if (source->formats().size() > 32)
        return 3;
      for (const auto &format : source->formats()) {
        const auto data = source->data(format);
        bytes += data.size();
        if (bytes > 8 * 1024 * 1024)
          return 3;
        saved->setData(format, data);
      }
    }
    QObject::connect(&target, &AccessibleTarget::captured, &app,
                     [&](QJsonObject value) {
                       if (app.arguments().contains("--capture-only")) {
                         qInfo().noquote() << QJsonDocument(QJsonObject{
                             {"hasToken", !value["token"].toString().isEmpty()},
                             {"editable", value["editable"]},
                             {"application", value["application"]},
                             {"reason", value["reason"]}}).toJson(QJsonDocument::Compact);
                         app.exit(0);
                         return;
                       }
                       if (value["token"].toString().isEmpty()) {
                         qInfo() << value["reason"].toString();
                         app.exit(4);
                         return;
                       }
                       target.insert(value["token"].toString(),
                                     "Stille-Post-Einfügetest 🐧.");
                     });
    QObject::connect(&target, &AccessibleTarget::clipboardRequested, &app,
                     [&](QString token, QString text, bool restore) {
                       if (!copyText(text)) {
                         app.exit(3);
                         return;
                       }
                       QTimer::singleShot(100, &app, [&, token, text, restore] {
                         target.insert(token, text, restore, true);
                       });
                     });
    QObject::connect(&target, &AccessibleTarget::inserted, &app,
                     [&](QString, bool ok, QString reason, bool modified) {
                       qInfo().noquote()
                           << QJsonDocument(QJsonObject{{"ok", ok},
                                                        {"reason", reason},
                                                        {"modified", modified}})
                                  .toJson(QJsonDocument::Compact);
                       app.clipboard()->setMimeData(saved.release());
                       QTimer::singleShot(100, &app, [&, ok] { app.exit(ok ? 0 : 5); });
                     });
    QTimer::singleShot(300, &app, [&] { target.capture("external"); });
    QTimer::singleShot(8000, &app, [&] { app.exit(6); });
    return app.exec();
  }
  InsertionTests tests;
  return QTest::qExec(&tests, argc, argv);
}
#include "accessibility_test.moc"
