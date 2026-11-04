#include <QtDBus>
#include <QtMultimedia>
#include <QtNetwork>
#include <QtWidgets>
#include <X11/Xlib.h>
#include <X11/extensions/XTest.h>
#include <X11/keysym.h>
#include <atomic>
#include <thread>
#include <unistd.h>
#undef None
#undef Bool
#undef Status

struct Shortcut {
  QString id;
  QVariantMap options;
};
using Shortcuts = QList<Shortcut>;
Q_DECLARE_METATYPE(Shortcut)
Q_DECLARE_METATYPE(Shortcuts)
QDBusArgument &operator<<(QDBusArgument &a, const Shortcut &s) {
  a.beginStructure();
  a << s.id << s.options;
  a.endStructure();
  return a;
}
const QDBusArgument &operator>>(const QDBusArgument &a, Shortcut &s) {
  a.beginStructure();
  a >> s.id >> s.options;
  a.endStructure();
  return a;
}

class Portal : public QObject {
  Q_OBJECT
public:
  explicit Portal(QObject *parent = nullptr) : QObject(parent) {
    qDBusRegisterMetaType<Shortcut>();
    qDBusRegisterMetaType<Shortcuts>();
  }
  void bind() {
    auto bus = QDBusConnection::sessionBus();
    bus.connect("org.freedesktop.portal.Desktop", "",
                "org.freedesktop.portal.Request", "Response", this,
                SLOT(response(uint, QVariantMap, QDBusMessage)));
    bus.connect(
        "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.GlobalShortcuts", "Activated", this,
        SLOT(activated(QDBusObjectPath, QString, qulonglong, QVariantMap)));
    const QString token = "sp" + QUuid::createUuid().toString(QUuid::Id128);
    QDBusInterface portal("org.freedesktop.portal.Desktop",
                          "/org/freedesktop/portal/desktop",
                          "org.freedesktop.portal.GlobalShortcuts", bus);
    auto call = portal.asyncCall("CreateSession",
                                 QVariantMap{{"session_handle_token", token},
                                             {"handle_token", token + "r"}});
    auto watcher = new QDBusPendingCallWatcher(call, this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, watcher] {
      QDBusPendingReply<QDBusObjectPath> reply = *watcher;
      if (reply.isError())
        emit status("Hotkey-Portal nicht verfügbar. Aufnahme über die "
                    "Schaltfläche oder Desktop-Tastenkürzel starten.");
      watcher->deleteLater();
    });
  }
signals:
  void toggle();
  void status(QString);
private slots:
  void response(uint code, const QVariantMap &result, const QDBusMessage &) {
    if (code != 0) {
      emit status(
          "Hotkey wurde nicht freigegeben. Schaltfläche bleibt verfügbar.");
      return;
    }
    if (result.contains("session_handle")) {
      session = qvariant_cast<QDBusObjectPath>(result.value("session_handle"));
      if (session.path().isEmpty())
        session = QDBusObjectPath(result.value("session_handle").toString());
      QDBusInterface portal("org.freedesktop.portal.Desktop",
                            "/org/freedesktop/portal/desktop",
                            "org.freedesktop.portal.GlobalShortcuts",
                            QDBusConnection::sessionBus());
      Shortcuts shortcuts{
          {"dictate",
           {{"description", QString("Diktat starten / stoppen")},
            {"preferred_trigger", QString("CTRL+ALT+space")}}}};
      portal.asyncCall("BindShortcuts", QVariant::fromValue(session),
                       QVariant::fromValue(shortcuts), QString(),
                       QVariantMap{});
    } else if (result.contains("shortcuts"))
      emit status(
          "Globaler Diktier-Hotkey registriert (Vorgabe: Strg+Alt+Leertaste).");
  }
  void activated(const QDBusObjectPath &path, const QString &id, qulonglong,
                 const QVariantMap &) {
    if (path.path() == session.path() && id == "dictate")
      emit toggle();
  }

private:
  QDBusObjectPath session;
};

class DictationWindow : public QMainWindow {
  Q_OBJECT
public:
  explicit DictationWindow(bool smoke) : smoke(smoke) {
    setWindowTitle("Stille Post · Linux");
    if (smoke) {
      setAttribute(Qt::WA_ShowWithoutActivating);
      setWindowFlag(Qt::WindowDoesNotAcceptFocus);
    }
    resize(680, 560);
    auto central = new QWidget;
    auto layout = new QVBoxLayout(central);
    layout->setContentsMargins(24, 24, 24, 24);
    layout->setSpacing(14);
    auto heading = new QLabel("Stille Post");
    auto font = heading->font();
    font.setPointSize(24);
    font.setBold(true);
    heading->setFont(font);
    layout->addWidget(heading);
    auto subtitle =
        new QLabel("Lokales Diktat · Audio bleibt auf diesem Rechner");
    layout->addWidget(subtitle);
    tabs = new QTabWidget;
    layout->addWidget(tabs, 1);
    auto dictation = new QWidget;
    auto form = new QVBoxLayout(dictation);
    stateLabel = new QLabel("Bereit");
    stateLabel->setWordWrap(true);
    form->addWidget(stateLabel);
    devices = new QComboBox;
    form->addWidget(new QLabel("Mikrofon"));
    form->addWidget(devices);
    refreshDevices();
    connect(devices, qOverload<int>(&QComboBox::activated), this, [this](int) {
      if (!busy && !config.isEmpty())
        saveConfig();
    });
    QMediaDevices *media = new QMediaDevices(this);
    connect(media, &QMediaDevices::audioInputsChanged, this, [this] {
      if (audio)
        captureFailed();
      refreshDevices();
    });
    auto controls = new QHBoxLayout;
    record = new QPushButton("Aufnahme starten");
    cancel = new QPushButton("Abbrechen");
    cancel->setEnabled(false);
    controls->addWidget(record);
    controls->addWidget(cancel);
    form->addLayout(controls);
    connect(record, &QPushButton::clicked, this, &DictationWindow::toggle);
    connect(cancel, &QPushButton::clicked, this, [this] {
      stopAudio();
      send({{"command", "cancel"}});
    });
    meter = new QProgressBar;
    meter->setRange(0, 100);
    meter->setValue(0);
    meter->setTextVisible(false);
    meter->setMaximumHeight(8);
    form->addWidget(meter);
    output = new QPlainTextEdit;
    auto textPalette = output->palette();
    auto placeholder = textPalette.color(QPalette::Text);
    placeholder.setAlpha(160);
    textPalette.setColor(QPalette::PlaceholderText, placeholder);
    output->setPalette(textPalette);
    output->setPlaceholderText("Der fertige Text erscheint hier und wird in "
                               "die Zwischenablage kopiert.");
    form->addWidget(output, 1);
    auto actions = new QHBoxLayout;
    auto copy = new QPushButton("Text kopieren");
    auto import = new QPushButton("Audiodatei öffnen …");
    actions->addWidget(copy);
    actions->addWidget(import);
    form->addLayout(actions);
    connect(copy, &QPushButton::clicked, this, [this] {
      QApplication::clipboard()->setText(output->toPlainText());
    });
    connect(import, &QPushButton::clicked, this, [this] {
      if (busy)
        return;
      auto file = QFileDialog::getOpenFileName(this, "Lokale Audiodatei");
      if (!file.isEmpty())
        send({{"command", "import"}, {"path", file}});
    });
    auto hint = new QLabel("Wayland / unbekanntes Ziel: Text wird kopiert. "
                           "Bitte selbst einfügen.\nGlobaler Hotkey: "
                           "Strg+Alt+Leertaste (im Desktop änderbar).");
    hint->setWordWrap(true);
    form->addWidget(hint);
    tabs->addTab(dictation, "Diktat");
    auto history = new QWidget;
    auto hl = new QVBoxLayout(history);
    historyList = new QListWidget;
    hl->addWidget(historyList);
    auto hr = new QHBoxLayout;
    auto reload = new QPushButton("Aktualisieren");
    auto deleteEntry = new QPushButton("Eintrag löschen");
    hr->addWidget(reload);
    hr->addWidget(deleteEntry);
    hl->addLayout(hr);
    tabs->addTab(history, "Verlauf");
    connect(reload, &QPushButton::clicked, this,
            [this] { send({{"command", "history"}}); });
    connect(historyList, &QListWidget::itemActivated, this,
            [this](QListWidgetItem *item) {
              output->setPlainText(item->data(Qt::UserRole + 1).toString());
              tabs->setCurrentIndex(0);
            });
    connect(deleteEntry, &QPushButton::clicked, this, [this] {
      if (auto item = historyList->currentItem())
        if (QMessageBox::question(
                this, "Eintrag löschen",
                "Text und gegebenenfalls Diagnose-Audio endgültig löschen?") ==
            QMessageBox::Yes)
          send({{"command", "deleteHistory"},
                {"id", item->data(Qt::UserRole).toString()}});
    });
    auto settings = new QWidget;
    auto sl = new QFormLayout(settings);
    primary = new QLineEdit;
    model = new QLineEdit;
    fallbackModel = new QLineEdit;
    language = new QComboBox;
    language->addItems({"de", "en", "auto"});
    storeHistory = new QCheckBox("Diktattexte im Verlauf speichern");
    save = new QPushButton("Einstellungen speichern");
    sl->addRow("Primärer Ollama-Dienst", primary);
    sl->addRow("Bereinigungsmodell", model);
    sl->addRow("Lokales Fallback-Modell", fallbackModel);
    sl->addRow("Diktatsprache", language);
    sl->addRow(storeHistory);
    sl->addRow(save);
    auto explanation =
        new QLabel("M5/LAN-Dienst zuerst, danach Ollama auf 127.0.0.1.\nLokale "
                   "Modelle werden bei Bedarf geladen.\nSpracherkennung: "
                   "Whisper large-v3-turbo, ausschließlich lokal.");
    explanation->setWordWrap(true);
    sl->addRow(explanation);
    tabs->addTab(settings, "Einstellungen");
    connect(save, &QPushButton::clicked, this, [this] { saveConfig(); });
    connect(tabs, &QTabWidget::currentChanged, this, [this](int tab) {
      if (tab == 1)
        send({{"command", "history"}});
      if (tab == 2)
        send({{"command", "config"}});
    });
    auto about = new QWidget;
    auto al = new QVBoxLayout(about);
    auto aboutText = new QLabel(
        QString("Stille Post %1\nLinux · lokale Spracherkennung\n\nUpdates "
                "werden nur nach Signaturprüfung installiert.\nKeine "
                "Telemetrie. Audio wird nie an den M5 gesendet.")
            .arg(STILLEPOST_VERSION));
    aboutText->setWordWrap(true);
    al->addWidget(aboutText);
    auto update = new QPushButton("Nach Updates suchen");
    al->addWidget(update);
    al->addStretch();
    tabs->addTab(about, "Über / Updates");
    connect(update, &QPushButton::clicked, this, [this] { checkUpdates(); });
    setCentralWidget(central);
    auto icon = QIcon(QCoreApplication::applicationDirPath() + "/../icon.png");
    setWindowIcon(icon);
    tray = new QSystemTrayIcon(icon, this);
    auto menu = new QMenu(this);
    menu->addAction("Stille Post öffnen", this, [this] {
      show();
      raise();
    });
    menu->addAction("Aufnahme starten / stoppen", this,
                    &DictationWindow::toggle);
    menu->addSeparator();
    menu->addAction("Beenden", this, [this] { QApplication::quit(); });
    tray->setContextMenu(menu);
    connect(tray, &QSystemTrayIcon::activated, this,
            [this](QSystemTrayIcon::ActivationReason reason) {
              if (reason == QSystemTrayIcon::Trigger) {
                show();
                raise();
              }
            });
    tray->show();
    worker.setProgram(QCoreApplication::applicationDirPath() +
                      "/stillepost-linux");
    connect(&worker, &QProcess::readyReadStandardOutput, this,
            &DictationWindow::readWorker);
    connect(&worker, &QProcess::errorOccurred, this, [this] {
      stateLabel->setText(
          "Diktierkern konnte nicht gestartet werden. Installation prüfen.");
    });
    connect(&worker, qOverload<int, QProcess::ExitStatus>(&QProcess::finished),
            this, [this](int, QProcess::ExitStatus) {
              stopAudio();
              stateLabel->setText(
                  "Diktierkern beendet. App bitte neu starten.");
              record->setEnabled(false);
            });
    worker.setProcessChannelMode(QProcess::SeparateChannels);
    worker.start();
    connect(qApp, &QCoreApplication::aboutToQuit, this, [this] {
      stopAudio();
      send({{"command", "quit"}});
      worker.closeWriteChannel();
      if (!worker.waitForFinished(5000)) {
        worker.terminate();
        worker.waitForFinished(2000);
      }
    });
    if (!smoke) {
      QTimer::singleShot(30000, this, [this] { checkUpdates(true); });
      auto portal = new Portal(this);
      connect(portal, &Portal::toggle, this, &DictationWindow::toggle);
      connect(portal, &Portal::status, this,
              [this](QString s) { statusBar()->showMessage(s); });
      portal->bind();
      setupX11();
    }
    if (QCoreApplication::arguments().contains("--pipeline-test")) {
      const auto wanted = qEnvironmentVariable("STILLEPOST_TEST_INPUT");
      int chosen = -1;
      for (int i = 1; i < devices->count(); ++i)
        if (!wanted.isEmpty() && devices->itemText(i).contains(wanted))
          chosen = i;
      if (chosen < 0) {
        QTimer::singleShot(0, qApp, [] { QCoreApplication::exit(3); });
      } else {
        devices->setCurrentIndex(chosen);
        QTimer::singleShot(1000, this, [this] { toggle(); });
        QTimer::singleShot(20000, this, [this] {
          if (currentState == "recording")
            toggle();
        });
      }
      QTimer::singleShot(120000, qApp, [] { QCoreApplication::exit(4); });
    }
    QTimer::singleShot(500, this, [this] { send({{"command", "config"}}); });
    if (!qEnvironmentVariable("STILLEPOST_OPEN_SETTINGS").isEmpty())
      tabs->setCurrentIndex(2);
    else if (qEnvironmentVariable("STILLEPOST_OPEN_HISTORY") == "1")
      tabs->setCurrentIndex(1);
    if (smoke && !QCoreApplication::arguments().contains("--pipeline-test"))
      QTimer::singleShot(1500, this, [this] {
        grab().save(qEnvironmentVariable("STILLEPOST_SCREENSHOT",
                                         "/tmp/stillepost-linux.png"));
        QApplication::quit();
      });
  }

protected:
  void closeEvent(QCloseEvent *event) override {
    if (!smoke && tray->isSystemTrayAvailable()) {
      hide();
      event->ignore();
    } else
      QMainWindow::closeEvent(event);
  }
private slots:
  void toggle() {
    if (updating)
      return;
    if (!busy) {
      captureTarget();
      send({{"command", "start"}});
    } else if (currentState == "recording") {
      stopAudio();
      send({{"command", "stop"}});
    }
  }
  void readWorker() {
    messages += worker.readAllStandardOutput();
    if (messages.size() > 8 * 1024 * 1024) {
      worker.kill();
      return;
    }
    qsizetype index;
    while ((index = messages.indexOf('\n')) >= 0) {
      auto data = messages.left(index);
      messages.remove(0, index + 1);
      auto object = QJsonDocument::fromJson(data).object();
      auto event = object["event"].toString();
      if (event == "ready") {
        const auto ack = qEnvironmentVariable("STILLEPOST_STARTUP_ACK");
        if (!ack.isEmpty()) {
          QFile ready(ack);
          if (ready.open(QIODevice::WriteOnly))
            ready.write("ready");
        }
      } else if (event == "capture") {
        if (object["active"].toBool())
          startAudio();
        else
          stopAudio();
      } else if (event == "state") {
        currentState = object["state"].toString();
        busy = currentState != "idle" && currentState != "error";
        devices->setEnabled(!busy);
        save->setEnabled(!busy);
        cancel->setEnabled(busy);
        record->setEnabled(!busy || currentState == "recording");
        record->setText(currentState == "recording" ? "Aufnahme stoppen"
                                                    : "Aufnahme starten");
        stateLabel->setText(currentState == "recording" ? "Aufnahme läuft …"
                            : currentState == "processing"
                                ? "Transkription / Textbereinigung …"
                            : currentState == "starting"
                                ? "Lokale Spracherkennung wird vorbereitet …"
                            : currentState == "error"
                                ? "Fehler – Diagnose-Audio bleibt erhalten."
                                : "Bereit");
      } else if (event == "result") {
        QString text = object["text"].toString();
        if (QCoreApplication::arguments().contains("--pipeline-test")) {
          const bool ok = text.contains("künstlicher", Qt::CaseInsensitive) &&
                          text.contains("Besprechung", Qt::CaseInsensitive);
          QFile report(qEnvironmentVariable("STILLEPOST_TEST_REPORT",
                                            "/tmp/stillepost-qt-result.json"));
          if (report.open(QIODevice::WriteOnly))
            report.write(QJsonDocument(QJsonObject{{"ok", ok},
                                                   {"characters", text.size()},
                                                   {"sampleBytes", testBytes},
                                                   {"peak", testPeak},
                                                   {"rawFallback",
                                                    object["rawFallback"]}})
                             .toJson(QJsonDocument::Compact));
          QTimer::singleShot(100, qApp,
                             [ok] { QCoreApplication::exit(ok ? 0 : 5); });
        }

        output->setPlainText(text);
        if (!text.isEmpty() &&
            !QCoreApplication::arguments().contains("--pipeline-test")) {
          QApplication::clipboard()->setText(text);
        }
        stateLabel->setText(
            text.isEmpty()                   ? "Keine Sprache erkannt."
            : object["rawFallback"].toBool() ? "Rohtext kopiert – Bereinigung "
                                               "nicht verfügbar oder verworfen."
            : object["localFallback"].toBool()
                ? "Lokal bereinigt und kopiert."
                : "Bereinigt und kopiert – bereit zum Einfügen.");
      } else if (event == "error" || event == "notice") {
        if (event == "error" &&
            QCoreApplication::arguments().contains("--pipeline-test"))
          QTimer::singleShot(100, qApp, [] { QCoreApplication::exit(6); });
        stateLabel->setText(object["message"].toString());
      } else if (event == "history") {
        historyList->clear();
        for (auto value : object["entries"].toArray()) {
          auto entry = value.toObject();
          auto text = entry["cleanText"].toString();
          auto item = new QListWidgetItem(text.left(140), historyList);
          item->setData(Qt::UserRole, entry["id"].toString());
          item->setData(Qt::UserRole + 1, text);
        }
      } else if (event == "config") {
        config = object["config"].toObject();
        const auto uid =
            config["audio"].toObject()["inputDeviceUID"].toString();
        if (uid.startsWith("pulse:")) {
          const int selected =
              devices->findData(QByteArray::fromBase64(uid.mid(6).toLatin1()));
          if (selected >= 0)
            devices->setCurrentIndex(selected);
        }
        auto clean = config["cleanup"].toObject();
        primary->setText(clean["ollamaURL"].toString());
        model->setText(clean["model"].toString());
        auto fallbacks = clean["fallbacks"].toArray();
        fallbackModel->setText(
            fallbacks.isEmpty() ? "gemma4:e4b-it-qat"
                                : fallbacks[0].toObject()["model"].toString());
        language->setCurrentText(
            config["whisper"].toObject()["language"].toString());
        storeHistory->setChecked(
            config["history"].toObject()["storeText"].toBool(true));
      }
    }
  }

private:
  void send(const QJsonObject &message) {
    if (worker.state() != QProcess::Running)
      return;
    worker.write(QJsonDocument(message).toJson(QJsonDocument::Compact) + '\n');
  }
  void refreshDevices() {
    auto id = devices->currentData().toByteArray();
    devices->clear();
    devices->addItem("Systemstandard", QByteArray{});
    for (auto device : QMediaDevices::audioInputs())
      devices->addItem(device.description(), device.id());
    int index = devices->findData(id);
    devices->setCurrentIndex(qMax(0, index));
  }
  void startAudio() {
    if (audio)
      return;
    QAudioDevice selected = QMediaDevices::defaultAudioInput();
    for (auto device : QMediaDevices::audioInputs())
      if (device.id() == devices->currentData().toByteArray())
        selected = device;
    QAudioFormat format;
    format.setSampleRate(16000);
    format.setChannelCount(1);
    format.setSampleFormat(QAudioFormat::Float);
    if (selected.isNull() || !selected.isFormatSupported(format)) {
      captureFailed();
      return;
    }
    audio = new QAudioSource(selected, format, this);
    audio->setBufferSize(8192);
    connect(audio, &QAudioSource::stateChanged, this,
            [this](QAudio::State state) {
              if (audio && state == QAudio::StoppedState &&
                  audio->error() != QAudio::NoError)
                captureFailed();
            });
    input = audio->start();
    if (QCoreApplication::arguments().contains("--pipeline-test")) {
      QFile marker(qEnvironmentVariable("STILLEPOST_TEST_REPORT",
                                        "/tmp/stillepost-qt-result.json") +
                   ".capturing");
      if (marker.open(QIODevice::WriteOnly))
        marker.write("capturing");
    }
    if (!input) {
      captureFailed();
      return;
    }
    connect(input, &QIODevice::readyRead, this, [this] { drainAudio(); });
  }
  void drainAudio() {
    if (!input)
      return;
    while (audio && audio->bytesAvailable() > 0) {
      auto bytes = input->read(4096);
      pendingAudio += bytes;
      auto count = pendingAudio.size() / 4 * 4;
      if (count == 0)
        continue;
      auto block = pendingAudio.left(count);
      testBytes += block.size();
      pendingAudio.remove(0, count);
      if (worker.bytesToWrite() > 1024 * 1024) {
        captureFailed();
        return;
      }
      send({{"command", "samples"},
            {"data", QString::fromLatin1(block.toBase64())}});
      float peak = 0;
      for (int i = 0; i + 4 <= block.size(); i += 4) {
        float value;
        memcpy(&value, block.constData() + i, 4);
        peak = qMax(peak, std::abs(value));
      }
      testPeak = qMax(testPeak, peak);
      meter->setValue(qBound(0, int(peak * 100), 100));
    }
  }
  void stopAudio() {
    if (!audio)
      return;
    drainAudio();
    auto old = audio;
    audio = nullptr;
    input = nullptr;
    old->stop();
    old->deleteLater();
    pendingAudio.clear();
    meter->setValue(0);
  }
  void captureFailed() {
    if (audio) {
      auto old = audio;
      audio = nullptr;
      input = nullptr;
      old->stop();
      old->deleteLater();
    }
    send({{"command", "captureError"}});
    stateLabel->setText("Mikrofon fehlt, wurde getrennt oder unterstützt das "
                        "Aufnahmeformat nicht.");
  }
  void saveConfig() {
    if (busy)
      return;
    auto clean = config["cleanup"].toObject();
    clean["provider"] = "ollama";
    clean["ollamaURL"] = primary->text();
    clean["model"] = model->text();
    clean["numCtx"] = 16384;
    clean["keepAlive"] = "2h";
    clean["fallbacks"] =
        QJsonArray{QJsonObject{{"provider", "ollama"},
                               {"ollamaURL", "http://127.0.0.1:11434"},
                               {"model", fallbackModel->text()},
                               {"numCtx", 16384},
                               {"keepAlive", "10m"}}};
    config["cleanup"] = clean;
    auto whisper = config["whisper"].toObject();
    whisper["language"] = language->currentText();
    config["whisper"] = whisper;
    auto history = config["history"].toObject();
    history["storeText"] = storeHistory->isChecked();
    config["history"] = history;
    auto audioConfig = config["audio"].toObject();
    const auto id = devices->currentData().toByteArray();
    audioConfig["inputDeviceUID"] =
        id.isEmpty() ? QString()
                     : "pulse:" + QString::fromLatin1(id.toBase64());
    audioConfig["inputDeviceName"] = devices->currentText();
    config["audio"] = audioConfig;
    send({{"command", "saveConfig"}, {"config", config}});
  }
  void setupX11() {
    if (qEnvironmentVariable("XDG_SESSION_TYPE") != "x11")
      return;
    display = XOpenDisplay(nullptr);
    if (!display)
      return;
    auto key = XKeysymToKeycode(display, XK_space);
    for (unsigned extra : {0u, unsigned(LockMask), unsigned(Mod2Mask),
                           unsigned(LockMask | Mod2Mask)})
      XGrabKey(display, key, ControlMask | Mod1Mask | extra,
               DefaultRootWindow(display), False, GrabModeAsync, GrabModeAsync);
    XFlush(display);
    auto timer = new QTimer(this);
    connect(timer, &QTimer::timeout, this, [this] {
      while (display && XPending(display)) {
        XEvent event;
        XNextEvent(display, &event);
        if (event.type == KeyPress)
          toggle();
      }
    });
    timer->start(25);
  }
  void captureTarget() {
    target = 0;
    if (display) {
      int revert;
      XGetInputFocus(display, &target, &revert);
    }
  }
  void checkUpdates(bool silent = false);
  void installUpdate();
  qint64 testBytes = 0;
  float testPeak = 0;
  bool smoke = false, busy = false, updating = false;
  QString currentState;
  QProcess worker;
  QByteArray messages, pendingAudio;
  QAudioSource *audio = nullptr;
  QIODevice *input = nullptr;
  QSystemTrayIcon *tray;
  QTabWidget *tabs;
  QLabel *stateLabel;
  QPlainTextEdit *output;
  QComboBox *devices, *language;
  QPushButton *record, *cancel, *save;
  QProgressBar *meter;
  QCheckBox *storeHistory;
  QLineEdit *primary, *model, *fallbackModel;
  QListWidget *historyList;
  QJsonObject config;
  Display *display = nullptr;
  unsigned long target = 0;
};

void DictationWindow::checkUpdates(bool silent) {
  if (updating || busy)
    return;
  auto check = new QProcess(this);
  connect(
      check, qOverload<int, QProcess::ExitStatus>(&QProcess::finished), this,
      [this, check, silent](int code, QProcess::ExitStatus) {
        const auto result =
            QJsonDocument::fromJson(check->readAllStandardOutput()).object();
        check->deleteLater();
        if (code != 0) {
          if (!silent)
            QMessageBox::information(
                this, "Updates",
                result["error"].toString(
                    "Noch kein signierter Linux-Feed erreichbar."));
          return;
        }
        if (!result["available"].toBool()) {
          if (!silent)
            QMessageBox::information(this, "Updates",
                                     "Die installierte Version ist aktuell.");
          return;
        }
        if (silent) {
          tray->showMessage("Stille Post",
                            "Eine neue geprüfte Version ist verfügbar. Unter "
                            "Über / Updates installieren.");
          return;
        }
        if (!busy &&
            QMessageBox::question(
                this, "Update verfügbar",
                "Version " + result["version"].toString() +
                    " herunterladen und nach Signaturprüfung installieren?") ==
                QMessageBox::Yes)
          installUpdate();
      });
  check->start(
      "/usr/bin/python3",
      {QCoreApplication::applicationDirPath() + "/../update.py", "check"});
}
void DictationWindow::installUpdate() {
  if (busy || updating)
    return;
  updating = true;
  record->setEnabled(false);
  save->setEnabled(false);
  stateLabel->setText("Update wird geladen und geprüft …");
  auto install = new QProcess(this);
  connect(
      install, qOverload<int, QProcess::ExitStatus>(&QProcess::finished), this,
      [this, install](int code, QProcess::ExitStatus) {
        const auto result =
            QJsonDocument::fromJson(install->readAllStandardOutput()).object();
        install->deleteLater();
        updating = false;
        record->setEnabled(true);
        save->setEnabled(true);
        if (code == 0) {
          QMessageBox::information(
              this, "Update installiert",
              "Das Update ist installiert. Stille Post beenden und über den "
              "App-Menüeintrag neu starten.");
          QApplication::quit();
        } else
          stateLabel->setText(result["error"].toString(
              "Update fehlgeschlagen; bisherige Version bleibt aktiv."));
      });
  install->start(
      "/usr/bin/python3",
      {QCoreApplication::applicationDirPath() + "/../update.py", "install"});
}

int main(int argc, char **argv) {
  XInitThreads();
  XSetErrorHandler([](Display *, XErrorEvent *) { return 0; });
  QApplication app(argc, argv);
  app.setApplicationName("stillepost");
  app.setDesktopFileName("io.github.danielmuellerir.stillepost");
  app.setApplicationVersion(STILLEPOST_VERSION);
  if (app.arguments().contains("--audio-devices")) {
    QJsonArray list;
    QAudioFormat format;
    format.setSampleRate(16000);
    format.setChannelCount(1);
    format.setSampleFormat(QAudioFormat::Float);
    for (const auto &device : QMediaDevices::audioInputs())
      list.append(
          QJsonObject{{"name", device.description()},
                      {"pcm16kFloat", device.isFormatSupported(format)}});
    puts(QJsonDocument(list).toJson(QJsonDocument::Compact).constData());
    return 0;
  }
  const bool smoke = app.arguments().contains("--smoke-test") ||
                     app.arguments().contains("--pipeline-test");
  QString socket =
      QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation) +
      "/stillepost-" + QString::number(getuid()) +
      (smoke ? "-smoke-" + QString::number(getpid()) : QString());
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
  DictationWindow window(smoke);
  QObject::connect(&server, &QLocalServer::newConnection, &app, [&] {
    auto connection = server.nextPendingConnection();
    QObject::connect(connection, &QLocalSocket::readyRead, &app,
                     [&, connection] {
                       auto command = connection->read(16);
                       if (command == "toggle")
                         QMetaObject::invokeMethod(&window, "toggle");
                       else if (command == "show") {
                         window.show();
                         window.raise();
                       }
                       connection->disconnectFromServer();
                       connection->deleteLater();
                     });
  });
  if (!app.arguments().contains("--background"))
    window.show();
  return app.exec();
}
#include "main.moc"
