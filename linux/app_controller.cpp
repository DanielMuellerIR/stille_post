#include "app_controller.h"
#include <LayerShellQt/Window>
#include <QSoundEffect>
#include <cmath>
#include <qrencode.h>
namespace {
QPushButton *button(QHBoxLayout *layout, QString title, QObject *owner,
                    std::function<void()> action) {
  auto value = new QPushButton(trText(title));
  layout->addWidget(value);
  QObject::connect(value, &QPushButton::clicked, owner, std::move(action));
  return value;
}
QString executable(QString name) {
  return QCoreApplication::applicationDirPath() + "/" + name;
}
bool busy(QString state) { return state != "idle" && state != "error"; }
} // namespace
AppController::AppController(bool testMode, QObject *parent)
    : QObject(parent), isolated(testMode) {
  qApp->setQuitOnLastWindowClosed(false);
  qApp->installEventFilter(this);
  auto sessionBus = QDBusConnection::sessionBus();
  sessionBus.connect("org.freedesktop.ScreenSaver", QString(),
                     "org.freedesktop.ScreenSaver", "ActiveChanged", this,
                     SLOT(screenStateChanged(bool)));
  sessionBus.connect("org.cinnamon.ScreenSaver", QString(),
                     "org.cinnamon.ScreenSaver", "ActiveChanged", this,
                     SLOT(screenStateChanged(bool)));
  QDBusConnection::systemBus().connect(
      "org.freedesktop.login1", "/org/freedesktop/login1",
      "org.freedesktop.login1.Manager", "PrepareForSleep", this,
      SLOT(screenStateChanged(bool)));

  overlay.setWindowTitle(trText("Stille Post"));
  overlay.setWindowFlags(Qt::Tool | Qt::FramelessWindowHint |
                         Qt::WindowStaysOnTopHint |
                         Qt::WindowDoesNotAcceptFocus);
  overlay.setAttribute(Qt::WA_ShowWithoutActivating);
  overlay.setObjectName("dictationOverlay");
  overlay.setStyleSheet("#dictationOverlay{background:palette(window);border:"
                        "1px solid palette(mid);border-radius:14px;} "
                        "QLabel{border:0;} QPushButton{padding:5px 12px;}");
  auto outer = new QVBoxLayout(&overlay);
  outer->setContentsMargins(20, 16, 20, 16);
  auto header = new QHBoxLayout;
  stateLabel = new QLabel(trText("Vorbereitung …"));
  auto font = stateLabel->font();
  font.setBold(true);
  stateLabel->setFont(font);
  durationLabel = new QLabel(trText("0:00"));
  header->addWidget(stateLabel, 1);
  header->addWidget(durationLabel);
  outer->addLayout(header);
  profileLabel = new QLabel;
  outer->addWidget(profileLabel);
  contextLabel = new QLabel;
  contextLabel->setWordWrap(true);
  contextLabel->hide();
  outer->addWidget(contextLabel);
  detailLabel = new QLabel;
  detailLabel->setWordWrap(true);
  detailLabel->setMaximumWidth(390);
  detailLabel->hide();
  outer->addWidget(detailLabel);
  meter = new QProgressBar;
  meter->setRange(0, 100);
  meter->setTextVisible(false);
  meter->setFixedHeight(6);
  outer->addWidget(meter);
  liveText = new QLabel;
  liveText->setWordWrap(true);
  liveText->setMaximumHeight(140);
  outer->addWidget(liveText);
  auto controls = new QHBoxLayout;
  outer->addLayout(controls);
  pauseButton = button(controls, "Pause", this, [this] {
    audio.stop();
    send({{"command", state == "paused" ? "resume" : "pause"}});
  });
  stopButton = button(controls, "Fertig", this, [this] { stop(); });
  button(controls, "Abbrechen", this, [this] {
    held = false;
    capturingTarget = false;
    audio.stop(false);
    send({{"command", "cancel"}});
  });
  for (auto label : {stateLabel, profileLabel, durationLabel, liveText,
                     contextLabel, detailLabel})
    label->setTextFormat(Qt::PlainText);
  overlay.resize(390, 150);
  tray.setIcon(QIcon(executable("../icon.png")));
  tray.setToolTip("Stille Post");
  tray.setContextMenu(&menu);
  connect(&tray, &QSystemTrayIcon::activated, this, [this](auto reason) {
    if (reason == QSystemTrayIcon::Trigger)
      showSettings();
  });
  if (!isolated)
    tray.show();
  connect(&settings, &SettingsWindow::saveRequested, this,
          [this](QJsonObject value, QJsonObject expected) {
            send({{"command", "saveConfig"},
                  {"config", value},
                  {"expected", expected}});
          });
  auto command = [this](QJsonObject value) {
    const auto name = value["command"].toString();
    if (name == "showDiagnostics") {
      diagnostics();
      return;
    }
    send(value);
  };
  connect(&settings, &SettingsWindow::command, this, command);
  connect(&history, &HistoryWindow::command, this, command);
  connect(&settings, &SettingsWindow::configureHotkeys, this, [this] {
    if (QGuiApplication::platformName() == "xcb")
      bindHotkeys();
    else
      portal.configure();
  });
  connect(&settings, &SettingsWindow::hotkeyCapture, this,
          [this](bool capture) {
            if (QGuiApplication::platformName() == "xcb") {
              if (capture) {
                interruptHold();
                held = false;
                x11.suspend();
              } else if (initialized && !isolated)
                bindHotkeys();
            }
          });
  auto status = [this](QString text, bool ready) {
    text = trText(text);
    if (qEnvironmentVariableIsSet("STILLEPOST_HOTKEY_TRACE"))
      qInfo().noquote() << QJsonDocument(QJsonObject{{"event", "hotkeyStatus"},
                                                     {"ready", ready}})
                               .toJson(QJsonDocument::Compact);
    hotkeyText = text;
    hotkeyReady = ready;
    if (!ready && held && pendingHold)
      interruptHold();
    settings.setHotkeyStatus(text, ready);
    if (QGuiApplication::platformName() == "wayland")
      settings.setShortcutDescriptions(portal.shortcutLabels());
    tray.setToolTip("Stille Post\n" + text);
    rebuildMenu();
    if (!ready && !isolated)
      notice(text, true);
  };
  connect(&portal, &GlobalShortcuts::status, this, status);
  connect(&x11, &X11Shortcuts::status, this, status);
  connect(&portal, &GlobalShortcuts::pressed, this, &AppController::keyPressed);
  connect(&x11, &X11Shortcuts::pressed, this, &AppController::keyPressed);
  connect(&portal, &GlobalShortcuts::released, this,
          &AppController::keyReleased);
  connect(&x11, &X11Shortcuts::released, this, &AppController::keyReleased);
  connect(&audio, &AudioInput::samples, this, [this](QByteArray data) {
    testBytes += data.size();
    if (worker.bytesToWrite() > 1024 * 1024) {
      audio.stop(false);
      send({{"command", "captureError"}});
      notice("Die Verarbeitung kommt mit der Aufnahme nicht nach.", true);
      return;
    }
    send({{"command", "samples"},
          {"data", QString::fromLatin1(data.toBase64())}});
  });
  connect(&audio, &AudioInput::level, this, [this](double value) {
    testPeak = qMax(testPeak, value);
    meter->setValue(qBound(0, int((value + 60) * 100 / 60), 100));
  });
  connect(&audio, &AudioInput::devicesChanged, &settings,
          &SettingsWindow::setAudioDevices);
  connect(&audio, &AudioInput::failed, this, [this](QString reason) {
    send({{"command", "captureError"}});
    notice(reason, true);
  });
  connect(&target, &AccessibleTarget::availability, this,
          [this](bool ready) { accessible = ready; });
  connect(&target, &AccessibleTarget::applicationChanged, this,
          [this](QString application) {
            settings.setInputTarget(application);
            send({{"command", "application"}, {"id", application}});
          });
  connect(&target, &AccessibleTarget::captured, this,
          [this](QJsonObject snapshot) {
            if (qEnvironmentVariableIsSet("STILLEPOST_INSERTION_TRACE"))
              qInfo() << "Insertion target"
                      << !snapshot["token"].toString().isEmpty()
                      << snapshot["editable"].toBool()
                      << snapshot["application"].toString()
                      << snapshot["reason"].toString();
            if (snapshot["request"] == "recall") {
              recallToken = snapshot["token"].toString();
              send({{"command", "recall"}});
              return;
            }
            if (snapshot["request"] == "selection") {
              selectionToken = snapshot["token"].toString();
              if (selectionToken.isEmpty()) {
                notice(snapshot["reason"].toString(), true);
                return;
              }
              send({{"command", "cleanupSelection"},
                    {"text", snapshot["selection"]},
                    {"application", snapshot["application"]}});
              return;
            }
            if (snapshot["request"].toString() != captureRequest ||
                !capturingTarget)
              return;
            capturingTarget = false;
            targetToken = snapshot["token"].toString();
            if (pendingHold && !held) {
              target.clear(targetToken);
              return;
            }
            send({{"command", pendingHold ? "holdStart" : "start"},
                  {"application", snapshot["application"]}});
          });
  connect(&target, &AccessibleTarget::clipboardRequested, this,
          [this](QString token, QString text, bool restore) {
            if (copyText(text)) {
              target.insert(token, text, restore, true);
            } else {
              pendingInsertions.remove(token);
              pendingNotes.remove(token);
              target.clear(token);
              copyOrPreview(text, trKey("linux.clipboard.failed"),
                            trKey("linux.clipboard.failed"));
            }
          });
  connect(&target, &AccessibleTarget::inserted, this,
          [this](QString token, bool ok, QString reason, bool modified) {
            if (qEnvironmentVariableIsSet("STILLEPOST_INSERTION_TRACE"))
              qInfo() << "Insertion result" << ok << modified << reason;
            const auto text = pendingInsertions.take(token);
            const auto note = pendingNotes.take(token);
            target.clear(token);
            if (ok)
              notice(trText("Text eingefügt.") +
                         (note.isEmpty() ? QString() : "\n" + note),
                     !note.isEmpty());
            else {
              copyOrPreview(text,
                            trText(reason) +
                                (modified ? QString()
                                          : trText(" Bitte selbst einfügen.")),
                            reason);
            }
          });
  connect(&placement, &DesktopPlacement::ready, this,
          [this](QPoint cursor, QRect area) {
            placementCursor = cursor;
            placementArea = area;
            if (overlay.isVisible())
              positionOverlay();
          });
  connect(&placement, &DesktopPlacement::failed, this, [this] {
    if (!isolated && sessionKind == "dictation" &&
        (busy(state) || state == "error")) {
      positionOverlay();
      overlay.show();
    }
    if (jsonValue(configuration, "ui.overlayPosition").toString() == "mouse")
      notice(trText("Mausposition nicht verfügbar. Die Anzeige erscheint unten "
                    "mittig."),
             true);
  });
  auto screenChanged = [this] {
    if (!overlay.isVisible())
      return;
    placementArea = {};
    if (QGuiApplication::platformName() == "wayland")
      placement.request();
    positionOverlay();
  };
  auto observeScreen = [this, screenChanged](QScreen *screen) {
    connect(screen, &QScreen::geometryChanged, this, screenChanged);
    connect(screen, &QScreen::availableGeometryChanged, this, screenChanged);
  };
  for (auto screen : QGuiApplication::screens())
    observeScreen(screen);
  connect(qApp, &QGuiApplication::screenAdded, this,
          [observeScreen, screenChanged](QScreen *screen) {
            observeScreen(screen);
            screenChanged();
          });
  connect(qApp, &QGuiApplication::screenRemoved, this, screenChanged);
  worker.setProgram(executable("stillepost-linux"));
  worker.setProcessChannelMode(QProcess::SeparateChannels);
  connect(&worker, &QProcess::readyReadStandardOutput, this,
          &AppController::readWorker);
  // Der Kern schreibt nur begrenzte Diagnosemeldungen; keine unbegrenzte
  // stderr-Queue.
  connect(&worker, &QProcess::readyReadStandardError, this,
          [this] { worker.readAllStandardError(); });
  connect(&worker, &QProcess::errorOccurred, this, [this] {
    notice("Diktierkern konnte nicht gestartet werden. Installation prüfen.",
           true);
  });
  connect(&worker, qOverload<int, QProcess::ExitStatus>(&QProcess::finished),
          this, [this](int, auto) {
            audio.stop(false);
            if (!shutdown) {
              changeState("error");
              notice("Diktierkern beendet. App bitte neu starten.", true);
            }
          });
  worker.start();
  connect(qApp, &QCoreApplication::aboutToQuit, this,
          &AppController::shutdownWorker);
  rebuildMenu();
}
void AppController::screenStateChanged(bool active) {
  if (active) {
    interruptHold();
    if (sessionKind == "import")
      send({{"command", "cancelImport"}});
    if (sessionKind == "test")
      send({{"command", "cancelTest"}});
  }
}
void AppController::interruptHold() {
  if (!pendingHold || !held)
    return;
  held = false;
  pendingHold = false;
  capturingTarget = false;
  audio.stop(false);
  send({{"command", "holdInterrupted"}});
}
bool AppController::eventFilter(QObject *object, QEvent *event) {
  if (event->type() == QEvent::MouseButtonPress && resultWindow) {
    auto widget = qobject_cast<QWidget *>(object);
    if (widget && widget->window() == resultWindow &&
        resultWindow->windowFlags().testFlag(Qt::WindowDoesNotAcceptFocus)) {
      if (QGuiApplication::platformName() == "wayland") {
        auto window = resultWindow->windowHandle();
        LayerShellQt::Window::get(window)->setKeyboardInteractivity(
            LayerShellQt::Window::KeyboardInteractivityOnDemand);
        resultWindow->repaint();
        QGuiApplication::sync();
      } else {
        resultWindow->setWindowFlag(Qt::WindowDoesNotAcceptFocus, false);
        resultWindow->setAttribute(Qt::WA_ShowWithoutActivating, false);
        resultWindow->show();
        resultWindow->activateWindow();
      }
    }
  }
  return QObject::eventFilter(object, event);
}
void AppController::shutdownWorker() {
  if (shutdown)
    return;
  shutdown = true;
  audio.stop(false);
  send({{"command", "quit"}});
  worker.closeWriteChannel();
  if (!worker.waitForFinished(5000)) {
    worker.terminate();
    if (!worker.waitForFinished(2000)) {
      worker.kill();
      worker.waitForFinished(1000);
    }
  }
}
AppController::~AppController() {
  shutdownWorker();
  // Das Overlay wird vor dem Audio-Member zerstört. Dessen Stoppsignal darf
  // dann keine bereits freigegebenen Pegelanzeigen mehr erreichen.
  audio.disconnect(this);
  target.disconnect(this);
  audio.stop(false);
}
void AppController::send(QJsonObject message) {
  const auto data =
      QJsonDocument(message).toJson(QJsonDocument::Compact) + '\n';
  if (data.size() > 4 * 1024 * 1024) {
    QTimer::singleShot(0, this, [this] {
      receive({{"event", "error"},
               {"message", trText("Der Auftrag ist zu groß. Bitte den Text "
                                  "oder die Einstellungen kürzen.")}});
    });
    return;
  }
  if (worker.state() == QProcess::Running)
    worker.write(data);
}
void AppController::readWorker() {
  messages += worker.readAllStandardOutput();
  if (messages.size() > 8 * 1024 * 1024) {
    worker.kill();
    notice("Ungültige Antwort vom Diktierkern.", true);
    return;
  }
  qsizetype index;
  while ((index = messages.indexOf('\n')) >= 0) {
    auto line = messages.left(index);
    messages.remove(0, index + 1);
    QJsonParseError error;
    auto doc = QJsonDocument::fromJson(line, &error);
    if (error.error != QJsonParseError::NoError || !doc.isObject()) {
      worker.kill();
      return;
    }
    receive(doc.object());
  }
}
void AppController::receive(QJsonObject event) {
  const auto kind = event["event"].toString();
  if (qEnvironmentVariableIsSet("STILLEPOST_AUDIO_TRACE") &&
      (kind == "state" || kind == "capture"))
    qInfo() << "Dictation capture status" << kind << event["state"].toString()
            << event["active"].toBool();
  settings.receive(event);
  history.receive(event);
  if (kind == "operation") {
    auxiliaryBusy = event["active"].toBool();
    if (auxiliaryBusy && event["kind"] == "cleanupSelection") {
      auto dialog = new QDialog;
      selectionProgress = dialog;
      dialog->setAttribute(Qt::WA_DeleteOnClose);
      dialog->setWindowTitle(trText("Auswahl wird bereinigt …"));
      auto layout = new QVBoxLayout(dialog);
      layout->addWidget(new QLabel(
          trText("Der ausgewählte Text wird verarbeitet. Das Eingabeziel wird "
                 "erst nach der Vorschau erneut geprüft.")));
      auto cancel = new QPushButton(trKey("common.cancel", "Abbrechen"));
      layout->addWidget(cancel);
      connect(cancel, &QPushButton::clicked, dialog, &QDialog::reject);
      connect(dialog, &QDialog::rejected, this, [this] {
        if (auxiliaryBusy)
          send({{"command", "cancelSelection"}});
      });
      dialog->show();
    } else if (!auxiliaryBusy && selectionProgress)
      selectionProgress->accept();
    rebuildMenu();
    return;
  }
  if (kind == "ready") {
    send({{"command", "config"}});
  } else if (kind == "config") {
    const auto previous = configuration;
    configuration = event["config"].toObject();
    if (!initialized) {
      initialized = true;
      if (!isolated)
        bindHotkeys();
      const auto tab = qEnvironmentVariable("STILLEPOST_OPEN_SETTINGS");
      if (!tab.isEmpty() ||
          !QCoreApplication::arguments().contains("--background"))
        if (tab == "audioimport")
          importAudio();
        else if (tab == "testdictation")
          testDictation();
        else
          showSettings(tab);
      if (qEnvironmentVariable("STILLEPOST_OPEN_HISTORY") == "1") {
        settings.hide();
        showHistory();
      }
      const auto previewState =
          qEnvironmentVariable("STILLEPOST_OVERLAY_PREVIEW");
      if (isolated && !previewState.isEmpty()) {
        settings.hide();
        history.hide();
        changeState(previewState.contains("paused")       ? "paused"
                    : previewState.contains("processing") ? "processing"
                    : previewState == "starting" || previewState == "resuming"
                        ? "starting"
                    : previewState.contains("error") ||
                            previewState == "hold-unavailable"
                        ? "error"
                        : "recording",
                    trText("Globale Einstellungen · Deutsch"));
        durationLabel->setText("1:23");
        meter->setValue(state == "recording" ? 65 : 0);
        if (previewState.startsWith("raw-preview")) {
          liveText->setText(trKey("overlay.live_preview.sample"));
          liveText->show();
        }
        overlay.adjustSize();
        positionOverlay();
        overlay.show();
      }
      if (isolated && (QCoreApplication::arguments().contains("--smoke-test") ||
                       !previewState.isEmpty()))
        QTimer::singleShot(800, this, [this] {
          QWidget *window = testWindow && testWindow->isVisible()
                                ? static_cast<QWidget *>(testWindow.data())
                            : importWindow && importWindow->isVisible()
                                ? static_cast<QWidget *>(importWindow.data())
                            : history.isVisible()
                                ? static_cast<QWidget *>(&history)
                            : overlay.isVisible() ? &overlay
                                                  : &settings;
          window->grab().save(qEnvironmentVariable(
              "STILLEPOST_SCREENSHOT", "/tmp/stillepost-linux.png"));
          QApplication::quit();
        });
      if (QCoreApplication::arguments().contains("--pipeline-test")) {
        auto deviceWait = new QTimer(this);
        deviceWait->setInterval(50);
        connect(deviceWait, &QTimer::timeout, this,
                [this, deviceWait, expected = event.value("config")] {
                  if (!audio.hasDeviceCatalog())
                    return;
                  deviceWait->stop();
                  deviceWait->deleteLater();
                  const auto wanted =
                      qEnvironmentVariable("STILLEPOST_TEST_INPUT");
                  QString uid;
                  for (auto value : audio.devices())
                    if (!wanted.isEmpty() &&
                        value.toObject()["name"].toString().contains(wanted))
                      uid = value.toObject()["id"].toString();
                  if (uid.isEmpty()) {
                    QCoreApplication::exit(3);
                    return;
                  }
                  setJsonValue(configuration, "audio.inputDeviceUID", uid);
                  // Tests ändern ausschließlich die isolierte Konfiguration.
                  send({{"command", "saveConfig"},
                        {"config", configuration},
                        {"expected", expected}});
                  QTimer::singleShot(1000, this, [this] {
                    send({{"command", "startTest"}, {"inputAvailable", true}});
                  });
                  QTimer::singleShot(20000, this, [this] {
                    if (state == "recording")
                      stop();
                  });
                });
        deviceWait->start();
        QTimer::singleShot(120000, qApp, [] { QCoreApplication::exit(4); });
      }
      if (!isolated)
        QTimer::singleShot(30000, this, [this] { checkUpdates(true); });
      QFile ack(qEnvironmentVariable("STILLEPOST_STARTUP_ACK"));
      if (!ack.fileName().isEmpty() && ack.open(QIODevice::WriteOnly))
        ack.write("ready");
    } else if (previous["linux"] != configuration["linux"] && !isolated)
      bindHotkeys();
    if (!previous.isEmpty() &&
        jsonValue(previous, "linux.startAtLogin").toBool() !=
            jsonValue(configuration, "linux.startAtLogin").toBool())
      setAutostart(jsonValue(configuration, "linux.startAtLogin").toBool());
    rebuildMenu();
  } else if (kind == "historyPolicy") {
    historyPolicy = event;
    rebuildMenu();
  } else if (kind == "configSaved") {
    // Der Autostart wird nur bei einer expliziten Änderung dieses Schalters
    // angepasst.
  } else if (kind == "capture") {
    if (event["active"].toBool()) {
      sound("start");
      audio.start(jsonValue(configuration, "audio.inputDeviceUID").toString());
    } else
      audio.stop();
  } else if (kind == "state") {
    sessionKind = event["sessionKind"].toString("dictation");
    QStringList context;
    if (!event["reason"].toString().isEmpty())
      context << event["reason"].toString();
    if (!event["instruction"].toString().isEmpty())
      context << event["instruction"].toString();
    if (!event["storesText"].toBool())
      context << trKey("settings.history.private");
    contextLabel->setText(context.join("\n"));
    contextLabel->setVisible(!context.isEmpty());
    changeState(event["state"].toString(),
                event["context"].toString(event["profile"].toString()));
  } else if (kind == "meter") {
    if (isolated && qEnvironmentVariableIsSet("STILLEPOST_OVERLAY_PREVIEW"))
      return;
    auto seconds = int(event["duration"].toDouble());
    durationLabel->setText(QString("%1:%2")
                               .arg(seconds / 60)
                               .arg(seconds % 60, 2, 10, QChar('0')));
  } else if (kind == "importProgress" || kind == "importStatus" ||
             kind == "importReview") {
    if (importWindow)
      importWindow->receive(event);
  } else if (kind == "transcriptPreview") {
    liveText->setText(event["text"].toString().right(700));
    liveText->setVisible(
        jsonValue(configuration, "ui.liveTranscriptPreview").toBool());
    overlay.adjustSize();
    positionOverlay();
  } else if (kind == "result" || kind == "testResult" || kind == "importResult")
    result(event);
  else if (kind == "privateRetryPreview")
    preview(event["text"].toString(), "Private Wiederholung — Ergebnis", {},
            false, event);
  else if (kind == "recall")
    preview(event["text"].toString(), "Letzter Diktattext", recallToken, true,
            event);
  else if (kind == "error" || kind == "notice") {
    notice(event["message"].toString(), kind == "error");
    if (busy(state) || state == "error") {
      detailLabel->setText(event["message"].toString());
      detailLabel->show();
      overlay.adjustSize();
      positionOverlay();
    }
    if (kind == "error" &&
        QCoreApplication::arguments().contains("--pipeline-test"))
      QCoreApplication::exit(6);
  } else if (kind == "selectionPreview")
    preview(event["text"].toString(), "Auswahl bereinigen — Vorschau",
            selectionToken, true);
  else if (kind == "bridgePairing")
    showPairing(event["pairing"].toObject());
  else if (kind == "bridgeStatus" && !event["ready"].toBool() &&
           jsonValue(configuration, "bridge.enabled").toBool())
    notice(event["message"].toString(), true);
  else if (kind == "diagnostics") {
    auto dialog = new QDialog;
    dialog->setAttribute(Qt::WA_DeleteOnClose);
    dialog->setWindowTitle(trText("Stille Post — Diagnose"));
    dialog->resize(760, 560);
    auto layout = new QVBoxLayout(dialog);
    auto page = new QWidget;
    auto findings = new QVBoxLayout(page);
    findings->setContentsMargins(16, 16, 16, 16);
    findings->setSpacing(12);
    for (const auto &value : event["findings"].toArray()) {
      const auto finding = value.toObject();
      auto group =
          section(trKey(("diagnosis.category." + finding["category"].toString())
                            .toUtf8()
                            .constData(),
                        finding["id"].toString()));
      auto content = new QWidget;
      auto row = new QHBoxLayout(content);
      row->setContentsMargins(0, 0, 0, 0);
      static_cast<QFormLayout *>(group->layout())->addRow(content);
      const auto level = finding["level"].toString();
      auto icon = new QLabel;
      icon->setPixmap(QApplication::style()
                          ->standardIcon(level == "problem"
                                             ? QStyle::SP_MessageBoxCritical
                                         : level == "warning"
                                             ? QStyle::SP_MessageBoxWarning
                                             : QStyle::SP_MessageBoxInformation)
                          .pixmap(22, 22));
      row->addWidget(icon);
      auto message = new QLabel(finding["message"].toString());
      message->setWordWrap(true);
      row->addWidget(message, 1);
      const auto action = finding["action"].toString();
      if (action != "none") {
        auto fix = new QPushButton(trText("Einstellungen …"));
        row->addWidget(fix);
        connect(fix, &QPushButton::clicked, dialog, [this, action] {
          showSettings(action == "speechSettings"    ? "speech"
                       : action == "cleanupSettings" ? "cleanup"
                       : action == "recordingSettings" ||
                               action == "microphonePrivacy"
                           ? "recording"
                           : "general");
        });
      }
      findings->addWidget(group);
    }
    findings->addStretch();
    layout->addWidget(scrollPage(page));
    const auto report = event["report"].toString();
    auto buttons = new QHBoxLayout;
    layout->addLayout(buttons);
    button(buttons, "Bericht kopieren", dialog, [this, report] {
      if (!copyText(report))
        notice(trKey("diagnosis.copy_failed"), true);
    });
    button(buttons, "Schließen", dialog, [dialog] { dialog->close(); });
    dialog->show();
  } else if (kind == "testReport" || kind == "testReview" ||
             kind == "testStatus") {
    if (testWindow)
      testWindow->receive(event);
  }
}
void AppController::bindHotkeys() {
  const auto dictate = jsonValue(configuration, "linux.dictationShortcut")
                           .toString("CTRL+ALT+space"),
             recall = jsonValue(configuration, "linux.recallShortcut")
                          .toString("CTRL+ALT+r");
  if (QGuiApplication::platformName() == "xcb")
    x11.bind(dictate, recall);
  else
    portal.bind(dictate, recall);
}
void AppController::keyPressed(QString action) {
  if (action == "recall") {
    recall();
    return;
  }
  if (action != "dictate" || held)
    return;
  held = true;
  if (jsonValue(configuration, "hotkeyMode").toString() == "hold")
    start(true);
  else
    toggle();
}
void AppController::keyReleased(QString action) {
  if (action != "dictate")
    return;
  held = false;
  if (pendingHold) {
    capturingTarget = false;
    audio.stop();
    send({{"command", "holdEnd"}});
  }
}
void AppController::toggle() {
  if (updating || auxiliaryBusy)
    return;
  if (state == "recording" || state == "paused")
    stop();
  else if (!busy(state) && !capturingTarget)
    start();
}
void AppController::start(bool hold) {
  if (busy(state) || auxiliaryBusy || capturingTarget || !initialized ||
      updating)
    return;
  if (!audio.available(
          jsonValue(configuration, "audio.inputDeviceUID").toString())) {
    notice("Kein Mikrofon verfügbar.", true);
    return;
  }
  if (QGuiApplication::platformName() == "wayland") {
    placementArea = {};
    placement.request();
  }
  pendingHold = hold;
  capturingTarget = true;
  captureRequest = QUuid::createUuid().toString();
  if (isolated) {
    capturingTarget = false;
    send({{"command", hold ? "holdStart" : "start"}});
  } else
    target.capture(captureRequest);
}
void AppController::stop() {
  audio.stop();
  sound("stop");
  send({{"command", state == "starting" ? "cancel" : "stop"}});
}
void AppController::changeState(QString value, QString profile) {
  state = value;
  profileLabel->setText(
      profileLabel->fontMetrics().elidedText(profile, Qt::ElideMiddle, 360));
  if (state == "starting") {
    detailLabel->clear();
    detailLabel->hide();
  }
  profileLabel->setVisible(!profile.isEmpty());
  const QHash<QString, QString> labels{
      {"idle", "Bereit"},
      {"starting", "Vorbereitung …"},
      {"recording", "Aufnahme"},
      {"paused", "Pausiert"},
      {"processing", "Text wird verarbeitet …"},
      {"error", "Fehler"}};
  stateLabel->setText(trText(labels.value(state, state)));
  pauseButton->setText(trText(state == "paused" ? "Fortsetzen" : "Pause"));
  pauseButton->setEnabled(state == "recording" || state == "paused");
  stopButton->setEnabled(state == "recording" || state == "paused");
  if ((busy(state) || state == "error") && !isolated &&
      sessionKind == "dictation") {
    overlay.adjustSize();
    positionOverlay();
    if (QGuiApplication::platformName() != "wayland" || !placement.isPending())
      overlay.show();
  } else
    overlay.hide();
  if (!busy(state)) {
    held = false;
    liveText->clear();
  }
  rebuildMenu();
}
void AppController::positionOverlay() {
  const bool nativePosition =
      QGuiApplication::platformName() == "wayland" && !placementArea.isEmpty();
  const auto cursor = nativePosition ? placementCursor : QCursor::pos();
  auto screen = QGuiApplication::screenAt(cursor);
  if (!screen)
    screen = QGuiApplication::primaryScreen();
  if (!screen)
    return;
  auto area = nativePosition ? placementArea : screen->availableGeometry();
  auto position = jsonValue(configuration, "ui.overlayPosition").toString();
  QPoint point =
      position == "mouse" &&
              (QGuiApplication::platformName() != "wayland" || nativePosition)
          ? cursor + QPoint(24, 24)
          : QPoint(area.center().x() - overlay.width() / 2,
                   area.bottom() - overlay.height() - 80);
  point.setX(qBound(area.left() + 8, point.x(),
                    qMax(area.left() + 8, area.right() - overlay.width() - 8)));
  point.setY(
      qBound(area.top() + 8, point.y(),
             qMax(area.top() + 8, area.bottom() - overlay.height() - 8)));
  overlay.move(point);
  if (QGuiApplication::platformName() == "wayland") {
    overlay.winId();
    auto window = overlay.windowHandle();
    auto layer = LayerShellQt::Window::get(window);
    const bool remap = overlay.isVisible() && layer->desiredOutput() != screen;
    if (remap)
      overlay.hide();
    window->setScreen(screen);
    layer->setDesiredOutput(screen);
    const auto full = screen->geometry();
    layer->setMargins(
        QMargins(point.x() - full.left(), point.y() - full.top(), 0, 0));
    if (remap)
      overlay.show();
  }
}
void AppController::notice(QString text, bool error) {
  if (isolated) {
    if (error)
      qWarning().noquote() << text;
    return;
  }
  tray.showMessage(
      "Stille Post", trText(text),
      error ? QSystemTrayIcon::Warning : QSystemTrayIcon::Information, 6000);
}
void AppController::showSettings(QString tab) {
  if (!initialized)
    return;
  settings.present(configuration, audio.devices(), tab);
  settings.setHotkeyStatus(hotkeyText, hotkeyReady);
}
void AppController::showHistory() { history.present(); }
void AppController::rebuildMenu() {
  if (testWindow)
    testWindow->setAllowed(!busy(state) && !auxiliaryBusy && !resultWindow);
  if (importWindow)
    importWindow->setAllowed(!busy(state) && !auxiliaryBusy && !resultWindow);
  menu.clear();
  auto title = menu.addAction(trText("Stille Post · ") +
                              QCoreApplication::applicationVersion());
  title->setEnabled(false);
  auto record = menu.addAction(state == "recording" || state == "paused"
                                   ? "Diktat beenden"
                                   : "Diktat starten",
                               this, &AppController::toggle);
  record->setEnabled(
      initialized && !auxiliaryBusy &&
      (!busy(state) || state == "recording" || state == "paused"));
  if (state == "recording" || state == "paused")
    menu.addAction(state == "paused" ? "Fortsetzen" : "Pause", this, [this] {
      audio.stop();
      send({{"command", state == "paused" ? "resume" : "pause"}});
    });
  menu.addAction(trText("Letzten Text anzeigen"), this, [this] { recall(); });
  menu.addAction(trText("Letzten Text aus dem Speicher entfernen"), this,
                 [this] { send({{"command", "clearLastResult"}}); });
  auto privateHistory =
      menu.addAction(trText("Ohne Textverlauf"), this, [this] {
        send({{"command", "privateHistory"},
              {"enabled", !historyPolicy["temporaryPrivate"].toBool()}});
      });
  privateHistory->setCheckable(true);
  privateHistory->setChecked(!historyPolicy["storesText"].toBool(true));
  privateHistory->setEnabled(historyPolicy["canToggle"].toBool());
  menu.addAction(trText("Auswahl bereinigen …"), this,
                 &AppController::cleanupSelection)
      ->setEnabled(!busy(state));
  auto profiles = menu.addMenu(trText("Profil"));
  auto standard = profiles->addAction(
      trText("Standard"), this, [this] { send({{"command", "profile"}}); });
  standard->setCheckable(true);
  standard->setChecked(configuration["selectedProfileID"].toString().isEmpty());
  for (auto value : configuration["profiles"].toArray()) {
    auto profile = value.toObject();
    auto id = profile["id"].toString();
    auto action =
        profiles->addAction(profile["name"].toString(), this, [this, id] {
          send({{"command", "profile"}, {"id", id}});
        });
    action->setCheckable(true);
    action->setChecked(configuration["selectedProfileID"].toString() == id);
    action->setEnabled(!busy(state));
  }
  menu.addSeparator();
  menu.addAction(trText("Verlauf …"), this, &AppController::showHistory);
  auto import = menu.addAction(trKey("audio_import.open"), this,
                               &AppController::importAudio);
  import->setObjectName("importAudio");
  import->setEnabled(!busy(state) && !auxiliaryBusy && !resultWindow);
  auto test = menu.addAction(trKey("test_dictation.open"), this,
                             &AppController::testDictation);
  test->setObjectName("testDictation");
  test->setEnabled(!busy(state) && !auxiliaryBusy && !resultWindow);
  menu.addAction(trText("Diagnose …"), this, &AppController::diagnostics);
  menu.addAction(trText("Einstellungen …"), this, [this] { showSettings(); });
  auto keyStatus = menu.addAction(
      hotkeyText.isEmpty() ? "Tastenkürzel wird vorbereitet …" : hotkeyText);
  keyStatus->setEnabled(false);
  menu.addSeparator();
  menu.addAction(trText("Nach Updates suchen …"), this,
                 [this] { checkUpdates(); });
  menu.addAction(trText("Beenden"), qApp, &QCoreApplication::quit);
}
void AppController::result(QJsonObject event) {
  const auto text = event["text"].toString(), kind = event["event"].toString();
  sound("stop");
  if (QCoreApplication::arguments().contains("--pipeline-test")) {
    const bool ok = text.contains("künstlicher", Qt::CaseInsensitive) &&
                    text.contains("Besprechung", Qt::CaseInsensitive);
    QFile report(qEnvironmentVariable("STILLEPOST_TEST_REPORT",
                                      "/tmp/stillepost-qt-result.json"));
    if (report.open(QIODevice::WriteOnly))
      report.write(
          QJsonDocument(QJsonObject{{"ok", ok},
                                    {"characters", text.size()},
                                    {"sampleBytes", testBytes},
                                    {"peakDb", testPeak},
                                    {"rawFallback", event["rawFallback"]}})
              .toJson(QJsonDocument::Compact));
    QTimer::singleShot(100, qApp, [ok] { QCoreApplication::exit(ok ? 0 : 5); });
    return;
  }
  if (kind == "importResult") {
    if (importWindow)
      importWindow->receive(event);
    return;
  }
  if (kind == "testResult") {
    if (testWindow)
      testWindow->receive(event);
    return;
  }
  if (event["failed"].toBool())
    return;
  if (text.isEmpty()) {
    notice("Keine Sprache erkannt.");
    return;
  }
  if (kind == "importResult" || event["preview"].toBool() ||
      !previewQueue.isEmpty())
    preview(text,
            kind == "importResult" ? "Import — Ergebnis" : "Diktat — Vorschau",
            kind == "result" ? targetToken : QString(), kind == "result",
            event);
  else
    deliver(text, targetToken, false,
            event["rawFallback"].toBool()
                ? event["note"].toString(trKey("app.raw_fallback_note"))
                : QString());
}
void AppController::recall() {
  if (busy(state) || auxiliaryBusy || !initialized || resultWindow)
    return;
  target.capture("recall");
}
void AppController::preview(QString text, QString title, QString token,
                            bool insert, QJsonObject outcome) {
  previewQueue.enqueue({text, title, token, insert, outcome});
  if (!resultWindow)
    presentNextPreview();
}
void AppController::presentNextPreview() {
  if (previewQueue.isEmpty() || resultWindow || shutdown)
    return;
  const auto item = previewQueue.head();
  auto dialog = new QDialog;
  resultWindow = dialog;
  dialog->setAttribute(Qt::WA_DeleteOnClose);
  dialog->setWindowTitle("Stille Post — " + trText(item.title));
  dialog->resize(760, 480);
  auto layout = new QVBoxLayout(dialog);
  auto heading = new QLabel(trText(item.title));
  auto headingFont = heading->font();
  headingFont.setPointSizeF(headingFont.pointSizeF() + 2);
  headingFont.setBold(true);
  heading->setFont(headingFont);
  layout->addWidget(heading);
  dialog->setSizeGripEnabled(true);
  auto hint = new QLabel(trKey("result.help"));
  hint->setTextFormat(Qt::PlainText);
  hint->setWordWrap(true);
  layout->addWidget(hint);
  if (item.outcome["rawFallback"].toBool() ||
      item.outcome["copyError"].toBool()) {
    auto warning = new QLabel(item.outcome["note"].toString().isEmpty()
                                  ? trKey("app.raw_fallback_note")
                                  : item.outcome["note"].toString());
    warning->setTextFormat(Qt::PlainText);
    warning->setWordWrap(true);
    layout->addWidget(warning);
  }
  const auto origin = item.outcome["origin"].toString();
  if (!item.outcome["rawFallback"].toBool() &&
      (origin == "raw" || origin == "formatting"))
    layout->addWidget(
        new QLabel(trKey(("editor.origin." + origin).toUtf8().constData())));
  auto text = new QPlainTextEdit(item.text);
  text->setReadOnly(true);
  layout->addWidget(text, 1);
  auto controls = new QHBoxLayout;
  layout->addLayout(controls);
  auto confirm = [this, item] {
    if (item.outcome.contains("candidate"))
      send({{"command", "completePreview"},
            {"candidate", item.outcome["candidate"]},
            {"accepted", true}});
  };
  button(controls, "Verwerfen", dialog, [dialog] { dialog->reject(); });
  controls->addStretch();
  auto copy =
      button(controls, "Kopieren", dialog, [this, dialog, item, confirm] {
        if (!copyText(item.text)) {
          notice(trKey("diagnosis.copy_failed"), true);
          return;
        }
        confirm();
        dialog->accept();
      });
  copy->setShortcut(QKeySequence("Ctrl+Shift+C"));
  if (item.insert) {
    auto insert =
        button(controls, "Einfügen", dialog, [this, dialog, item, confirm] {
          confirm();
          deliver(item.text, item.token, true,
                  item.outcome["rawFallback"].toBool()
                      ? item.outcome["note"].toString(
                            trKey("app.raw_fallback_note"))
                      : QString());
          dialog->accept();
        });
    insert->setShortcut(QKeySequence("Ctrl+Return"));
  }
  connect(dialog, &QDialog::finished, this, [this, item](int result) {
    if (result != QDialog::Accepted && item.outcome.contains("candidate"))
      send({{"command", "completePreview"},
            {"candidate", item.outcome["candidate"]},
            {"accepted", false}});
    if (!pendingInsertions.contains(item.token))
      target.clear(item.token);
    previewQueue.dequeue();
    resultWindow = nullptr;
    QTimer::singleShot(0, this, &AppController::presentNextPreview);
  });
  const bool automatic = item.outcome["event"] == "result";
  if (automatic) {
    dialog->setWindowFlag(Qt::WindowDoesNotAcceptFocus);
    dialog->setAttribute(Qt::WA_ShowWithoutActivating);
  }
  dialog->show();
  if (!automatic) {
    dialog->raise();
    dialog->activateWindow();
  }
}
void AppController::copyOrPreview(QString text, QString message,
                                  QString failureNote) {
  if (copyText(text)) {
    notice(message, !failureNote.isEmpty());
    return;
  }
  notice(trText("Text steht in der Vorschau zum Kopieren bereit."), true);
  preview(
      text, "Ergebnis — Kopieren", {}, false,
      {{"event", "result"},
       {"copyError", true},
       {"note", trKey("linux.clipboard.failed") +
                    (failureNote.isEmpty() ? QString() : "\n" + failureNote)}});
}
void AppController::deliver(QString text, QString token, bool restore,
                            QString note) {
  if (text.isEmpty())
    return;
  if (jsonValue(configuration, "linux.automaticPaste").toBool(true) &&
      !token.isEmpty()) {
    pendingInsertions[token] = text;
    pendingNotes[token] = note;
    target.insert(token, text, restore);
  } else {
    target.clear(token);
    copyOrPreview(text,
                  trText("Text kopiert. Bitte im Eingabeziel einfügen.") +
                      (note.isEmpty() ? QString() : "\n" + note),
                  note);
  }
}
void AppController::diagnostics() {
  send({{"command", "diagnostics"},
        {"microphone",
         audio.available(
             jsonValue(configuration, "audio.inputDeviceUID").toString())},
        {"accessibility", accessible},
        {"keyboard", hotkeyReady},
        {"version", QCoreApplication::applicationVersion()}});
}
void AppController::testDictation() {
  if (busy(state) || auxiliaryBusy || resultWindow)
    return;
  if (!testWindow) {
    testWindow = new TestDictationWindow;
    testWindow->setAttribute(Qt::WA_DeleteOnClose);
    connect(
        testWindow, &TestDictationWindow::command, this,
        [this](QJsonObject message) {
          if (message.value("command").toString() == "microphoneSettings") {
            showSettings("recording");
            return;
          }
          if (message.value("command").toString() == "startTest")
            message["inputAvailable"] = audio.available(
                jsonValue(configuration, "audio.inputDeviceUID").toString());
          send(message);
        });
  }
  testWindow->setAllowed(!busy(state) && !auxiliaryBusy && !resultWindow);
  testWindow->present();
}
void AppController::importAudio() {
  if (busy(state) || auxiliaryBusy || resultWindow)
    return;
  if (!importWindow) {
    importWindow = new AudioImportWindow;
    importWindow->setAttribute(Qt::WA_DeleteOnClose);
    connect(importWindow, &AudioImportWindow::command, this,
            &AppController::send);
  }
  importWindow->setAllowed(!busy(state) && !auxiliaryBusy && !resultWindow);
  importWindow->present();
}
void AppController::cleanupSelection() {
  if (!busy(state) && !auxiliaryBusy && !resultWindow)
    target.capture("selection", true);
}
void AppController::setAutostart(bool enabled) {
  if (isolated)
    return;
  auto path = QStandardPaths::writableLocation(QStandardPaths::ConfigLocation) +
              "/autostart";
  QDir().mkpath(path);
  path += "/stillepost.desktop";
  if (!enabled) {
    QFile::remove(path);
    return;
  }
  // Fester installierter Launcher statt einer beim nächsten Update veralteten
  // Bundle-Adresse.
  auto launcher = QDir::homePath() + "/.local/bin/stillepost";
  launcher.replace("\\", "\\\\")
      .replace("\"", "\\\"")
      .replace("`", "\\`")
      .replace("$", "\\$");
  QSaveFile file(path);
  if (file.open(QIODevice::WriteOnly)) {
    file.write(("[Desktop Entry]\nType=Application\nName=Stille Post\nExec=\"" +
                launcher + "\" --background\nTerminal=false\n")
                   .toUtf8());
    if (!file.commit())
      notice("Autostart konnte nicht gespeichert werden.", true);
  } else
    notice("Autostart konnte nicht gespeichert werden.", true);
}
void AppController::sound(QString name) {
  if (isolated || !jsonValue(configuration, "ui.sounds").toBool())
    return;
  auto effect = new QSoundEffect(this);
  effect->setSource(
      QUrl::fromLocalFile(executable("../sounds/dictation-" + name + ".wav")));
  effect->setVolume(.25f);
  connect(effect, &QSoundEffect::playingChanged, effect, [effect] {
    if (!effect->isPlaying())
      effect->deleteLater();
  });
  effect->play();
  QTimer::singleShot(5000, effect, &QObject::deleteLater);
}
void AppController::checkUpdates(bool silent) {
  if (updating)
    return;
  auto process = new QProcess(this);
  auto operation = std::make_shared<QString>("check");
  connect(
      process, qOverload<int, QProcess::ExitStatus>(&QProcess::finished), this,
      [this, process, silent, operation](int code, auto) {
        auto response =
            QJsonDocument::fromJson(process->readAllStandardOutput()).object();
        if (*operation == "install") {
          updating = false;
          if (code == 0) {
            QMessageBox::information(nullptr, "Update installiert",
                                     "Stille Post wird beendet. Bitte über den "
                                     "App-Menüeintrag neu starten.");
            QApplication::quit();
          } else
            notice(
                response["error"].toString("Update fehlgeschlagen. Die "
                                           "bisherige Version bleibt aktiv."),
                true);
          process->deleteLater();
          return;
        }
        if (code != 0) {
          if (!silent)
            QMessageBox::information(
                nullptr, "Updates",
                response["error"].toString(
                    "Noch kein signierter Linux-Feed erreichbar."));
          process->deleteLater();
          return;
        }
        if (!response["available"].toBool()) {
          if (!silent)
            QMessageBox::information(nullptr, "Updates",
                                     "Die installierte Version ist aktuell.");
          process->deleteLater();
          return;
        }
        if (silent) {
          notice("Eine neue geprüfte Version ist verfügbar. Im Menü unter "
                 "Updates installieren.");
          process->deleteLater();
          return;
        }
        if (!busy(state) &&
            QMessageBox::question(
                nullptr, "Update verfügbar",
                "Version " + response["version"].toString() +
                    " herunterladen und nach Signaturprüfung installieren?") ==
                QMessageBox::Yes) {
          *operation = "install";
          updating = true;
          process->start("/usr/bin/python3",
                         {executable("../update.py"), "install"});
        } else
          process->deleteLater();
      });
  process->start("/usr/bin/python3", {executable("../update.py"), "check"});
}
void AppController::showPairing(QJsonObject pairing) {
  const auto payload = QJsonDocument(pairing).toJson(QJsonDocument::Compact);
  if (payload.size() > 4096)
    return;
  auto code = QRcode_encodeData(
      payload.size(),
      reinterpret_cast<const unsigned char *>(payload.constData()), 0,
      QR_ECLEVEL_M);
  if (!code) {
    notice("QR-Code konnte nicht erzeugt werden.", true);
    return;
  }
  const int quiet = 4, scale = 6, side = code->width + quiet * 2;
  QImage image(side * scale, side * scale, QImage::Format_RGB32);
  image.fill(Qt::white);
  QPainter painter(&image);
  painter.setPen(Qt::NoPen);
  painter.setBrush(Qt::black);
  for (int y = 0; y < code->width; y++)
    for (int x = 0; x < code->width; x++)
      if (code->data[y * code->width + x] & 1)
        painter.drawRect((x + quiet) * scale, (y + quiet) * scale, scale,
                         scale);
  painter.end();
  QRcode_free(code);
  auto dialog = new QDialog(&settings);
  dialog->setAttribute(Qt::WA_DeleteOnClose);
  dialog->setWindowTitle(trText("Stille Post — iPhone koppeln"));
  dialog->setWindowModality(Qt::WindowModal);
  auto layout = new QVBoxLayout(dialog);
  auto help =
      new QLabel(trText("Diesen Zugangscode ausschließlich mit dem eigenen "
                        "iPhone direkt vom Bildschirm scannen. Er enthält das "
                        "geheime Token und schließt nach zwei Minuten."));
  help->setWordWrap(true);
  layout->addWidget(help);
  auto qr = new QLabel;
  qr->setAlignment(Qt::AlignCenter);
  qr->setPixmap(QPixmap::fromImage(image));
  layout->addWidget(qr);
  auto address = new QLabel(pairing["url"].toString());
  address->setTextInteractionFlags(Qt::TextSelectableByMouse);
  layout->addWidget(address);
  auto fingerprint =
      new QLabel(trText("SHA-256: ") + pairing["pin"].toString());
  fingerprint->setTextInteractionFlags(Qt::TextSelectableByMouse);
  fingerprint->setWordWrap(true);
  layout->addWidget(fingerprint);
  auto controls = new QHBoxLayout;
  layout->addLayout(controls);
  button(controls, "Token kopieren", dialog,
         [this, token = pairing["token"].toString()] {
           if (!copyText(token))
             notice(trKey("linux.clipboard.failed"), true);
         });
  button(controls, "Schließen", dialog, [dialog] { dialog->reject(); });
  QTimer::singleShot(120000, dialog, &QDialog::reject);
  dialog->resize(qMin(680, image.width() + 40), image.height() + 210);
  dialog->show();
}
