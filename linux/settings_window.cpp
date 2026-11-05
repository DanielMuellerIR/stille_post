#include "settings_window.h"
#include "shortcut_codec.h"
namespace {
QFormLayout *rows(QGroupBox *box) {
  return qobject_cast<QFormLayout *>(box->layout());
}
QVBoxLayout *pageLayout(QWidget *page) {
  auto layout = new QVBoxLayout(page);
  layout->setContentsMargins(20, 8, 20, 20);
  layout->setSpacing(18);
  return layout;
}
QString T(const char *key, QString fallback = {}) {
  return trKey(key, fallback);
}
} // namespace
SettingsWindow::SettingsWindow(QWidget *parent) : QDialog(parent) {
  setWindowTitle(T("window.settings.title", "Stille Post — Einstellungen"));
  resize(850, 760);
  setMinimumSize(760, 650);
  auto layout = new QVBoxLayout(this);
  layout->setContentsMargins(12, 12, 12, 12);
  tabs = new QTabWidget;
  layout->addWidget(tabs, 1);
  auto footer = new QHBoxLayout;
  message =
      new QLabel(trText("Einstellungen werden erst mit Speichern übernommen."));
  message->setWordWrap(true);
  footer->addWidget(message, 1);
  cancelOperation = new QPushButton(trText("Vorgang abbrechen"));
  cancelOperation->hide();
  footer->addWidget(cancelOperation);
  connect(cancelOperation, &QPushButton::clicked, this,
          [this] { emit command({{"command", "cancelOperation"}}); });
  auto cancel = new QPushButton(T("common.cancel", "Abbrechen"));
  save = new QPushButton(T("common.save", "Speichern"));
  save->setDefault(true);
  footer->addWidget(cancel);
  footer->addWidget(save);
  layout->addLayout(footer);
  connect(cancel, &QPushButton::clicked, this, &QDialog::reject);
  connect(save, &QPushButton::clicked, this, [this] {
    save->setEnabled(false);
    emit saveRequested(draft, expected);
  });
  connect(this, &QDialog::finished, this,
          [this] { emit hotkeyCapture(false); });
}
void SettingsWindow::present(QJsonObject configuration, QJsonArray available,
                             QString tab) {
  draft = configuration;
  expected = configuration;
  devices = available;
  rebuild();
  const QStringList names{"allgemein",   "profile",         "apps",
                          "bereinigung", "spracherkennung", "aufnahme",
                          "verlauf"};
  int index = names.indexOf(tab);
  if (index < 0)
    index = QStringList{"general", "profiles",  "apps",   "cleanup",
                        "speech",  "recording", "history"}
                .indexOf(tab);
  if (index >= 0)
    tabs->setCurrentIndex(index);
  show();
  raise();
  activateWindow();
}
void SettingsWindow::setHotkeyStatus(QString text, bool ready) {
  if (hotkeyStatus) {
    hotkeyStatus->setText(text);
    hotkeyStatus->setProperty("ready", ready);
  }
}
void SettingsWindow::setInputTarget(QString application) {
  lastApplication = application;
  if (applicationLabel)
    applicationLabel->setText(application.isEmpty()
                                  ? trText("Noch kein Eingabeziel erkannt.")
                                  : application);
}
void SettingsWindow::receive(QJsonObject event) {
  const auto kind = event["event"].toString();
  if (kind == "operation") {
    cancelOperation->setVisible(event["active"].toBool());
    if (!event["active"].toBool())
      save->setEnabled(true);
  } else if (kind == "configSaved") {
    save->setEnabled(true);
    accept();
  } else if (kind == "bridgeCredentialsChanged") {
    message->setText(trText("Erneuert. Bitte die Geräte erneut koppeln."));
  } else if (kind == "error") {
    message->setText(event["message"].toString());
    save->setEnabled(true);
  } else if (kind == "modelProgress") {
    message->setText(trText("Modell: %1 / %2 MB")
                         .arg(event["received"].toDouble() / 1048576, 0, 'f', 0)
                         .arg(event["total"].toDouble() / 1048576, 0, 'f', 0));
  } else if (kind == "modelInstalled")
    message->setText(T("model.installed", "Modell ist installiert."));
  else if (kind == "sileroInstalled") {
    message->setText(T("vad.ready"));
    if (sileroStatusLabel)
      sileroStatusLabel->setText(T("vad.ready"));
  } else if (kind == "sileroStatus") {
    if (sileroStatusLabel)
      sileroStatusLabel->setText(event["message"].toString());
  } else if (kind == "endpointCheck")
    message->setText(T("settings.cleanup.primary", "Endpoint") + ": " +
                     event["state"].toString());
  else if (kind == "keyStored")
    message->setText(T("settings.cleanup.api_key_saved", "Gespeichert."));
}
QCheckBox *SettingsWindow::check(QFormLayout *form, QString text,
                                 QString path) {
  auto widget = new QCheckBox(trText(text));
  widget->setChecked(jsonValue(draft, path).toBool());
  widget->setObjectName(path);
  form->addRow(widget);
  connect(widget, &QCheckBox::toggled, this,
          [this, path](bool value) { setJsonValue(draft, path, value); });
  return widget;
}
QLineEdit *SettingsWindow::line(QFormLayout *form, QString text, QString path) {
  auto widget = new QLineEdit(jsonValue(draft, path).toString());
  widget->setObjectName(path);
  form->addRow(trText(text), widget);
  connect(widget, &QLineEdit::textChanged, this,
          [this, path](QString value) { setJsonValue(draft, path, value); });
  return widget;
}
QComboBox *SettingsWindow::choice(QFormLayout *form, QString text, QString path,
                                  QList<QPair<QString, QJsonValue>> options) {
  auto widget = new QComboBox;
  widget->setObjectName(path);
  for (const auto &value : options)
    widget->addItem(trText(value.first), value.second.toVariant());
  const auto wanted = jsonValue(draft, path);
  for (int i = 0; i < options.size(); ++i)
    if (options[i].second == wanted)
      widget->setCurrentIndex(i);
  form->addRow(trText(text), widget);
  connect(widget, qOverload<int>(&QComboBox::currentIndexChanged), this,
          [this, widget, path](int) {
            setJsonValue(draft, path,
                         QJsonValue::fromVariant(widget->currentData()));
          });
  return widget;
}
QDoubleSpinBox *SettingsWindow::number(QFormLayout *form, QString text,
                                       QString path, double minimum,
                                       double maximum, double step) {
  auto widget = new QDoubleSpinBox;
  widget->setObjectName(path);
  widget->setRange(minimum, maximum);
  widget->setSingleStep(step);
  widget->setDecimals(step >= 1 ? 0 : 2);
  widget->setValue(jsonValue(draft, path).toDouble());
  form->addRow(trText(text), widget);
  connect(widget, qOverload<double>(&QDoubleSpinBox::valueChanged), this,
          [this, path](double value) { setJsonValue(draft, path, value); });
  return widget;
}
void SettingsWindow::rebuild() {
  loading = true;
  const auto active = tabs->currentIndex();
  while (tabs->count()) {
    auto page = tabs->widget(0);
    tabs->removeTab(0);
    page->deleteLater();
  }
  hotkeyStatus = nullptr;
  tabs->addTab(scrollPage(generalPage()),
               T("settings.tab.general", "Allgemein"));
  tabs->addTab(profilesPage(), T("profiles.title", "Profile"));
  tabs->addTab(scrollPage(appsPage()), T("app_profiles.title", "Apps"));
  tabs->addTab(scrollPage(cleanupPage()),
               T("settings.tab.cleanup", "Bereinigung"));
  tabs->addTab(scrollPage(speechPage()),
               T("settings.tab.speech", "Spracherkennung"));
  tabs->addTab(scrollPage(recordingPage()),
               T("settings.tab.recording", "Aufnahme"));
  tabs->addTab(scrollPage(historyPage()), T("settings.tab.history", "Verlauf"));
  if (active >= 0)
    tabs->setCurrentIndex(active);
  save->setEnabled(true);
  loading = false;
}
void SettingsWindow::setShortcutDescriptions(QMap<QString, QString> labels) {
  shortcutDescriptions = labels;
  for (auto it = shortcutFields.begin(); it != shortcutFields.end(); ++it)
    if (it.value())
      it.value()->setText(labels.value(it.key(), trText("Nicht belegt")));
}
QWidget *SettingsWindow::generalPage() {
  auto page = new QWidget;
  auto layout = pageLayout(page);
  auto hotkeys = section(T("settings.hotkey.section", "Aufnahme-Hotkey"));
  layout->addWidget(hotkeys);
  auto form = rows(hotkeys);
  choice(form, T("hotkey.mode", "Verhalten"), "hotkeyMode",
         {{T("hotkey.mode.toggle", "Start/Stopp"), "toggle"},
          {T("hotkey.mode.hold", "Zum Sprechen halten"), "hold"}});
  auto addKey = [this, form](QString label, QString path) {
    auto row = new QWidget;
    auto horizontal = new QHBoxLayout(row);
    horizontal->setContentsMargins(0, 0, 0, 0);
    auto current =
        new QLabel(displayShortcut(jsonValue(draft, path).toString()));
    current->setObjectName(path);
    const auto id = path.endsWith("dictationShortcut") ? "dictate" : "recall";
    shortcutFields[id] = current;
    if (QGuiApplication::platformName() == "wayland" &&
        !shortcutDescriptions.isEmpty())
      current->setText(shortcutDescriptions.value(id, trText("Nicht belegt")));
    auto button =
        new QPushButton(QGuiApplication::platformName() == "wayland"
                            ? trText("Im Desktop ändern …")
                            : T("settings.hotkey.record", "Hotkey aufnehmen"));
    horizontal->addWidget(current, 1);
    horizontal->addWidget(button);
    form->addRow(label, row);
    connect(button, &QPushButton::clicked, this, [this, current, path] {
      if (QGuiApplication::platformName() == "wayland") {
        emit configureHotkeys();
        return;
      }
      emit hotkeyCapture(true);
      QDialog dialog(this);
      dialog.setWindowTitle(T("settings.hotkey.press_now", "Jetzt drücken …"));
      auto box = new QVBoxLayout(&dialog);
      auto hint = new QLabel(trText(
          "Kombination mit Strg, Alt oder Super drücken. Escape bricht ab."));
      hint->setWordWrap(true);
      box->addWidget(hint);
      auto editor = new QKeySequenceEdit;
      box->addWidget(editor);
      auto buttons =
          new QDialogButtonBox(QDialogButtonBox::Ok | QDialogButtonBox::Cancel);
      box->addWidget(buttons);
      connect(buttons, &QDialogButtonBox::accepted, &dialog, &QDialog::accept);
      connect(buttons, &QDialogButtonBox::rejected, &dialog, &QDialog::reject);
      if (dialog.exec() == QDialog::Accepted &&
          !editor->keySequence().isEmpty()) {
        auto value = encodeShortcut(editor->keySequence()[0]);
        if (!value.isEmpty()) {
          setJsonValue(draft, path, value);
          current->setText(displayShortcut(value));
        } else
          message->setText(trText("Mindestens Strg, Alt oder Super und eine "
                                  "unterstützte Taste erforderlich."));
      }
      emit hotkeyCapture(false);
    });
  };
  addKey(T("settings.hotkey.combination", "Tastenkombination"),
         "linux.dictationShortcut");
  addKey(T("settings.result.section", "Letzten Text anzeigen"),
         "linux.recallShortcut");
  hotkeyStatus = new QLabel(trText("Registrierungszustand wird geprüft."));
  hotkeyStatus->setWordWrap(true);
  form->addRow(hotkeyStatus);
  auto configure = new QPushButton(
      trText("Desktop-Freigabe / Tastenkürzel konfigurieren …"));
  form->addRow(configure);
  connect(configure, &QPushButton::clicked, this,
          &SettingsWindow::configureHotkeys);
  auto result =
      section(T("settings.result.section", "Ergebnis und letzter Text"));
  layout->addWidget(result);
  check(rows(result),
        T("settings.result.preview", "Ergebnis vor dem Einfügen prüfen"),
        "ui.previewBeforePaste");
  check(rows(result),
        T("settings.live_preview", "Rohtext während der Aufnahme anzeigen"),
        "ui.liveTranscriptPreview");
  check(rows(result), "Automatisch in das unveränderte Eingabefeld einfügen",
        "linux.automaticPaste");
  auto start = section(T("settings.start.section", "Start"));
  layout->addWidget(start);
  check(rows(start), "Stille Post beim Anmelden starten", "linux.startAtLogin");
  auto appearance = section(T("settings.interface.section", "Oberfläche"));
  layout->addWidget(appearance);
  choice(
      rows(appearance), T("settings.overlay_position", "Overlay-Position"),
      "ui.overlayPosition",
      {{T("settings.overlay_position.mouse", "An der Mausposition"), "mouse"},
       {T("settings.overlay_position.bottom_center", "Unten mittig"),
        "bottomCenter"}});
  check(rows(appearance),
        T("settings.sounds", "Start-/Stopp-/Fehler-Sounds abspielen"),
        "ui.sounds");
  choice(rows(appearance), "Sprache (nach Neustart)", "linux.language",
         {{"System", "system"}, {"Deutsch", "de"}, {"English", "en"}});
  auto bridge = section(T("settings.bridge.section", "Diktat vom iPhone"));
  layout->addWidget(bridge);
  check(rows(bridge), "Empfang über die lokale HTTPS-Brücke aktivieren",
        "bridge.enabled");
  number(rows(bridge), "Port", "bridge.port", 1024, 65535, 1);
  auto pair = new QPushButton(trText("Gerät koppeln / QR-Code anzeigen …"));
  rows(bridge)->addRow(pair);
  connect(pair, &QPushButton::clicked, this,
          [this] { emit command({{"command", "bridgePair"}}); });
  for (const auto &entry : QList<QPair<QString, QString>>{
           {"Zertifikat erneuern …", "bridgeRenewIdentity"},
           {"Zugriffstoken erneuern …", "bridgeRotateToken"}}) {
    auto control = new QPushButton(trText(entry.first));
    rows(bridge)->addRow(control);
    connect(control, &QPushButton::clicked, this, [this, entry] {
      if (QMessageBox::question(
              this, trText(entry.first),
              trText(
                  "Bestehende Kopplungen müssen anschließend mit einem neuen "
                  "QR-Code aktualisiert werden. Aktive Brückenaufträge werden "
                  "abgebrochen. Jetzt erneuern?")) == QMessageBox::Yes)
        emit command({{"command", entry.second}});
    });
  }
  auto diagnostics = section(T("diagnosis.title", "Diagnose"));
  layout->addWidget(diagnostics);
  auto diagnose = new QPushButton(T("diagnosis.open", "Diagnose öffnen …"));
  rows(diagnostics)->addRow(diagnose);
  connect(diagnose, &QPushButton::clicked, this,
          [this] { emit command({{"command", "showDiagnostics"}}); });
  layout->addStretch();
  return page;
}
void SettingsWindow::vocabulary(QVBoxLayout *layout, QString root) {
  auto group =
      section(T("settings.cleanup.dictionary", "Fachbegriffs-Wörterbuch"));
  layout->addWidget(group);
  auto words = new QPlainTextEdit;
  QStringList terms;
  for (auto value : jsonValue(draft, root + ".dictionary").toArray())
    terms << value.toString();
  words->setPlainText(terms.join('\n'));
  words->setMaximumHeight(160);
  words->setObjectName(root + ".dictionary");
  rows(group)->addRow(words);
  auto help = new QLabel(
      T("settings.cleanup.dictionary_help", "Ein Begriff pro Zeile."));
  help->setWordWrap(true);
  rows(group)->addRow(help);
  connect(words, &QPlainTextEdit::textChanged, this, [this, root, words] {
    QJsonArray array;
    for (auto word : words->toPlainText().split('\n'))
      if (!word.trimmed().isEmpty())
        array.append(word.trimmed());
    setJsonValue(draft, root + ".dictionary", array);
  });
  auto variants = new QTableWidget(0, 2);
  variants->setHorizontalHeaderLabels(
      {trText("Verhörvariante"), trText("Zielschreibweise")});
  variants->horizontalHeader()->setSectionResizeMode(QHeaderView::Stretch);
  variants->setMaximumHeight(160);
  const auto array = jsonValue(draft, root + ".dictionaryVariants").toArray();
  for (auto item : array) {
    auto row = variants->rowCount();
    variants->insertRow(row);
    variants->setItem(
        row, 0, new QTableWidgetItem(item.toObject()["source"].toString()));
    variants->setItem(
        row, 1, new QTableWidgetItem(item.toObject()["target"].toString()));
  }
  rows(group)->addRow(variants);
  auto add = new QPushButton(trText("Variante hinzufügen"));
  auto remove = new QPushButton(trText("Ausgewählte Variante löschen"));
  auto actions = new QHBoxLayout;
  actions->addWidget(add);
  actions->addWidget(remove);
  rows(group)->addRow(actions);
  auto commit = [this, variants, root] {
    QJsonArray array;
    for (int i = 0; i < variants->rowCount(); ++i) {
      auto a = variants->item(i, 0), b = variants->item(i, 1);
      if (a && b && !a->text().trimmed().isEmpty() &&
          !b->text().trimmed().isEmpty())
        array.append(QJsonObject{{"source", a->text().trimmed()},
                                 {"target", b->text().trimmed()}});
    }
    setJsonValue(draft, root + ".dictionaryVariants", array);
  };
  connect(variants, &QTableWidget::cellChanged, this,
          [commit](int, int) { commit(); });
  connect(add, &QPushButton::clicked, this, [variants] {
    int row = variants->rowCount();
    variants->insertRow(row);
    variants->setItem(row, 0, new QTableWidgetItem);
    variants->setItem(row, 1, new QTableWidgetItem);
    variants->editItem(variants->item(row, 0));
  });
  connect(remove, &QPushButton::clicked, this, [variants, commit] {
    if (variants->currentRow() >= 0) {
      variants->removeRow(variants->currentRow());
      commit();
    }
  });
}
void SettingsWindow::endpoints(QVBoxLayout *layout, QString root,
                               bool includePrimary, QString fallbackRoot) {
  auto showProviderFields = [](QFormLayout *form, QComboBox *provider,
                               QString path) {
    auto refresh = [form, provider, path] {
      const bool ollama = provider->currentData().toString() == "ollama";
      for (const auto &suffix :
           {".ollamaURL", ".model", ".numCtx", ".keepAlive"})
        if (auto field =
                form->parentWidget()->findChild<QWidget *>(path + suffix))
          form->setRowVisible(field, ollama);
      for (const auto &suffix :
           {".remote.baseURL", ".remote.model", ".remote.apiKeyEnvVar"})
        if (auto field =
                form->parentWidget()->findChild<QWidget *>(path + suffix))
          form->setRowVisible(field, !ollama);
    };
    QObject::connect(provider, qOverload<int>(&QComboBox::currentIndexChanged),
                     form->parentWidget(), [refresh](int) { refresh(); });
    refresh();
  };
  if (includePrimary) {
    auto box = section(T("settings.cleanup.primary", "Primärer Endpoint"));
    layout->addWidget(box);
    auto form = rows(box);
    auto provider = choice(
        form, T("settings.cleanup.provider", "Anbieter"), root + ".provider",
        {{"Ollama", "ollama"}, {"OpenAI-kompatibel", "openai"}});
    line(form, T("settings.cleanup.ollama_url", "Ollama-URL"),
         root + ".ollamaURL");
    line(form, T("settings.cleanup.model", "Modell"), root + ".model");
    line(form, T("settings.cleanup.base_url", "Base-URL"),
         root + ".remote.baseURL");
    line(form, "Remote-Modell", root + ".remote.model");
    line(form, "Umgebungsvariable für API-Key", root + ".remote.apiKeyEnvVar");
    number(form, T("settings.cleanup.context", "Kontextfenster"),
           root + ".numCtx", 1024, 131072, 1024);
    choice(form, T("settings.cleanup.keep_alive", "Geladen lassen"),
           root + ".keepAlive",
           {{"2 Stunden", "2h"},
            {"1 Stunde", "1h"},
            {"30 Minuten", "30m"},
            {"10 Minuten", "10m"},
            {"5 Minuten", "5m"},
            {"Sofort entladen", "0"},
            {"Dauerhaft", "-1"}});
    showProviderFields(form, provider, root);
    auto test = new QPushButton(trText("Endpoint prüfen"));
    form->addRow(test);
    connect(test, &QPushButton::clicked, this, [this, root] {
      emit command(
          {{"command", "checkEndpoint"}, {"endpoint", jsonValue(draft, root)}});
    });
  }
  if (!fallbackRoot.isEmpty())
    root = fallbackRoot;
  auto fallback = section(T("settings.cleanup.fallbacks", "Fallbacks"));
  layout->addWidget(fallback);
  auto container = new QWidget;
  auto list = new QVBoxLayout(container);
  list->setContentsMargins(0, 0, 0, 0);
  rows(fallback)->addRow(container);
  auto array = jsonValue(draft, root + ".fallbacks").toArray();
  for (int i = 0; i < array.size(); ++i) {
    auto entry = section(trText("Fallback %1").arg(i + 1));
    list->addWidget(entry);
    auto form = rows(entry);
    auto path = root + ".fallbacks." + QString::number(i);
    auto provider = choice(
        form, T("settings.cleanup.provider", "Anbieter"), path + ".provider",
        {{"Ollama", "ollama"}, {"OpenAI-kompatibel", "openai"}});
    line(form, T("settings.cleanup.ollama_url", "Ollama-URL"),
         path + ".ollamaURL");
    line(form, T("settings.cleanup.model", "Modell"), path + ".model");
    line(form, T("settings.cleanup.base_url", "Base-URL"),
         path + ".remote.baseURL");
    line(form, "Remote-Modell", path + ".remote.model");
    line(form, "API-Key-Umgebungsvariable", path + ".remote.apiKeyEnvVar");
    number(form, T("settings.cleanup.context", "Kontextfenster"),
           path + ".numCtx", 1024, 131072, 1024);
    line(form, T("settings.cleanup.keep_alive", "Geladen lassen"),
         path + ".keepAlive");
    showProviderFields(form, provider, path);
    auto actions = new QHBoxLayout;
    for (auto pair :
         QList<QPair<QString, int>>{{"↑", -1}, {"↓", 1}, {"Entfernen", 0}}) {
      auto button = new QPushButton(trText(pair.first));
      button->setObjectName(path + (pair.second < 0   ? ".up"
                                    : pair.second > 0 ? ".down"
                                                      : ".remove"));
      actions->addWidget(button);
      connect(button, &QPushButton::clicked, this,
              [this, root, i, delta = pair.second] {
                auto entries = jsonValue(draft, root + ".fallbacks").toArray();
                if (delta == 0)
                  entries.removeAt(i);
                else if (i + delta >= 0 && i + delta < entries.size()) {
                  const QJsonValue value = entries[i];
                  entries.removeAt(i);
                  entries.insert(i + delta, value);
                }
                setJsonValue(draft, root + ".fallbacks", entries);
                rebuild();
              });
    }
    form->addRow(actions);
  }
  auto add = new QPushButton(
      T("settings.cleanup.add_fallback", "Fallback hinzufügen"));
  rows(fallback)->addRow(add);
  connect(add, &QPushButton::clicked, this, [this, root] {
    auto entries = jsonValue(draft, root + ".fallbacks").toArray();
    if (entries.size() >= 8)
      return;
    entries.append(QJsonObject{
        {"provider", "ollama"},
        {"ollamaURL", "http://127.0.0.1:11434"},
        {"model", "gemma4:e4b-it-qat"},
        {"numCtx", 16384},
        {"keepAlive", "30m"},
        {"remote",
         QJsonObject{{"baseURL", ""},
                     {"model", ""},
                     {"apiKeyEnvVar", "STILLEPOST_CLEANUP_API_KEY"}}}});
    setJsonValue(draft, root + ".fallbacks", entries);
    rebuild();
  });
}
QWidget *SettingsWindow::cleanupPage(QString root, bool withVocabulary) {
  auto page = new QWidget;
  auto layout = pageLayout(page);
  auto enabled = section(T("settings.tab.cleanup", "Bereinigung"));
  layout->addWidget(enabled);
  check(rows(enabled),
        T("settings.cleanup.enabled", "Textbereinigung aktivieren"),
        root + ".enabled");
  check(rows(enabled), "Nur lokale Bereinigung (keine LAN-/Cloud-Dienste)",
        root + ".localOnly");
  check(rows(enabled),
        T("formatting.enabled", "Gesprochene Formatierungsbefehle"),
        root + ".spokenFormatting");
  endpoints(layout, root, true);
  if (withVocabulary)
    vocabulary(layout, root);
  auto keys = section(T("settings.cleanup.api_key_section", "API-Key"));
  layout->addWidget(keys);
  auto secret = new QLineEdit;
  secret->setEchoMode(QLineEdit::Password);
  secret->setPlaceholderText(
      T("settings.cleanup.api_key_new", "Neuen API-Key eintragen"));
  rows(keys)->addRow(secret);
  auto store = new QPushButton(
      T("settings.cleanup.api_key_store", "Im Schlüsselbund speichern"));
  rows(keys)->addRow(store);
  connect(store, &QPushButton::clicked, this, [this, secret] {
    if (!secret->text().isEmpty()) {
      emit command({{"command", "setCleanupKey"}, {"key", secret->text()}});
      secret->clear();
    }
  });
  auto privacy =
      new QLabel(T("settings.cleanup.api_key_privacy",
                   "Der Key wird nie in der Config-Datei gespeichert."));
  privacy->setWordWrap(true);
  rows(keys)->addRow(privacy);
  layout->addStretch();
  return page;
}
QWidget *SettingsWindow::speechPage() {
  auto page = new QWidget;
  auto layout = pageLayout(page);
  auto speech = section(T("settings.tab.speech", "Spracherkennung"));
  layout->addWidget(speech);
  choice(rows(speech), T("settings.whisper.language", "Sprache"),
         "whisper.language",
         {{"Deutsch", "de"}, {"English", "en"}, {"Automatisch", "auto"}});
  auto hint = new QLabel(T("settings.whisper.language_help"));
  hint->setWordWrap(true);
  rows(speech)->addRow(hint);
  auto model = section("Whisper-Modell");
  layout->addWidget(model);
  auto selected = new QComboBox;
  selected->addItem(trText("large-v3-turbo · ca. 1,6 GB"), "large-v3-turbo");
  selected->addItem(trText("large-v3 · ca. 3,1 GB"), "large-v3");
  rows(model)->addRow(trText("Modell"), selected);
  auto install = new QPushButton(trText("Modell herunterladen / ersetzen …"));
  rows(model)->addRow(install);
  connect(install, &QPushButton::clicked, this, [this, selected] {
    if (QMessageBox::question(
            this, "Whisper-Modell",
            "Das gewählte Modell wird an den gespeicherten Modellpfad geladen. "
            "Ein dort vorhandenes Modell wird ersetzt. Fortfahren?") ==
        QMessageBox::Yes)
      emit command({{"command", "installModel"},
                    {"model", selected->currentData().toString()}});
  });
  auto advanced = section(T("settings.whisper.advanced", "Erweitert"));
  layout->addWidget(advanced);
  check(rows(advanced),
        T("settings.whisper.autostart", "whisper-server automatisch starten"),
        "whisper.autostart");
  line(rows(advanced), T("settings.whisper.server_url", "Server-URL"),
       "whisper.serverURL");
  line(rows(advanced), "Programmdatei", "whisper.binaryPath");
  line(rows(advanced), "Modellpfad", "whisper.modelPath");
  number(rows(advanced), "CPU-Threads", "whisper.threads", 1, 128, 1);
  check(rows(advanced), "Geprüften Vulkan-GPU-Pfad verwenden",
        "whisper.useGPU");
  layout->addStretch();
  return page;
}
void SettingsWindow::setAudioDevices(QJsonArray value) {
  devices = value;
  populateAudioDevices();
}
void SettingsWindow::populateAudioDevices() {
  if (!audioDeviceChoice)
    return;
  QSignalBlocker blocker(audioDeviceChoice);
  const auto uid = jsonValue(draft, "audio.inputDeviceUID").toString();
  audioDeviceChoice->clear();
  audioDeviceChoice->addItem(trText("Systemstandard"), "");
  for (const auto &value : devices) {
    const auto device = value.toObject();
    audioDeviceChoice->addItem(device["name"].toString(),
                               device["id"].toString());
  }
  if (audioDeviceChoice->findData(uid) < 0) {
    const auto name = jsonValue(draft, "audio.inputDeviceName").toString();
    audioDeviceChoice->addItem(
        trText("Nicht verfügbar: ") +
            (name.isEmpty() ? trText("Ausgewähltes Mikrofon") : name),
        uid);
  }
  audioDeviceChoice->setCurrentIndex(audioDeviceChoice->findData(uid));
}
QWidget *SettingsWindow::recordingPage() {
  auto page = new QWidget;
  auto layout = pageLayout(page);
  auto microphone = section("Mikrofon");
  layout->addWidget(microphone);
  audioDeviceChoice = new QComboBox;
  audioDeviceChoice->setObjectName("audio.inputDeviceUID");
  rows(microphone)->addRow(trText("Eingabegerät"), audioDeviceChoice);
  populateAudioDevices();
  connect(audioDeviceChoice, qOverload<int>(&QComboBox::currentIndexChanged),
          this, [this](int) {
            const auto uid = audioDeviceChoice->currentData().toString();
            setJsonValue(draft, "audio.inputDeviceUID", uid);
            if (uid.isEmpty())
              setJsonValue(draft, "audio.inputDeviceName", "");
            for (const auto &value : devices)
              if (value.toObject()["id"] == uid)
                setJsonValue(draft, "audio.inputDeviceName",
                             value.toObject()["name"]);
          });
  auto vad = section("Sprachaktivität und Segmentierung");
  layout->addWidget(vad);
  choice(rows(vad), "Detektor", "vad.detector",
         {{"RMS", "rms"}, {"Silero", "silero"}});
  number(rows(vad), "Stillegrenze (dBFS)", "vad.silenceThresholdDb", -100, -5,
         1);
  number(rows(vad), "Mindest-Sprachdauer (s)", "vad.minSpeechSec", .03, 10,
         .05);
  number(rows(vad),
         T("settings.vad.split_silence", "Nach Stille schneiden (s)"),
         "vad.splitAfterSilenceSec", .1, 10, .1);
  number(rows(vad), T("settings.vad.min_segment", "Mindest-Segmentlänge (s)"),
         "vad.minSegmentSec", .1, 120, .1);
  number(rows(vad), T("settings.vad.max_segment", "Maximale Segmentlänge (s)"),
         "vad.maxSegmentSec", 1, 300, 1);
  number(rows(vad), T("settings.vad.padding", "Vor-/Nachlauf (s)"),
         "vad.paddingSec", 0, 5, .05);
  auto absence = section(T("settings.vad.absence", "Abwesenheit"));
  layout->addWidget(absence);
  number(rows(absence),
         T("settings.vad.auto_stop", "Auto-Stopp nach Stille (s, 0 = aus)"),
         "vad.autoStopAfterSilenceSec", 0, 3600, 1);
  auto silero =
      new QPushButton(trText("Silero-Modell prüfen / herunterladen …"));
  sileroStatusLabel = new QLabel(trText("Modellzustand wird geprüft …"));
  sileroStatusLabel->setWordWrap(true);
  rows(vad)->addRow(sileroStatusLabel);
  rows(vad)->addRow(silero);
  QTimer::singleShot(0, this,
                     [this] { emit command({{"command", "sileroStatus"}}); });
  connect(silero, &QPushButton::clicked, this,
          [this] { emit command({{"command", "installSilero"}}); });
  layout->addStretch();
  return page;
}
QWidget *SettingsWindow::historyPage(QString root) {
  auto page = new QWidget;
  auto layout = pageLayout(page);
  auto text = section(T("settings.history.text", "Textaufbewahrung"));
  layout->addWidget(text);
  check(rows(text),
        T("settings.history.store_text", "Text neuer Diktate speichern"),
        root + ".storeText");
  choice(rows(text), T("settings.history.text_period", "Text aufbewahren"),
         root + ".textRetentionDays",
         {{T("settings.history.unlimited", "Unbegrenzt"), 0},
          {"1 Tag", 1},
          {"7 Tage", 7},
          {"30 Tage", 30}});
  auto hint = new QLabel(T("settings.history.future_only"));
  hint->setWordWrap(true);
  rows(text)->addRow(hint);
  auto audio = section(T("settings.history.audio", "Fehleraufnahmen"));
  layout->addWidget(audio);
  choice(rows(audio),
         T("settings.history.audio_period", "Aufnahmen aufbewahren"),
         root + ".audioRetentionDays",
         {{T("settings.history.manual", "Bis manuell gelöscht"), 0},
          {"7 Tage", 7},
          {"30 Tage", 30}});
  auto privacy = section(T("settings.history.private", "Ohne Textverlauf"));
  layout->addWidget(privacy);
  auto description = new QLabel(T("settings.history.memory_help"));
  description->setWordWrap(true);
  rows(privacy)->addRow(description);
  layout->addStretch();
  return page;
}
QWidget *SettingsWindow::profilesPage() {
  auto page = new QWidget;
  auto layout = pageLayout(page);
  auto top = section(T("profiles.title", "Profile"));
  layout->addWidget(top);
  QList<QPair<QString, QJsonValue>> options{
      {T("profiles.global", "Globale Einstellungen"),
       QJsonValue(QJsonValue::Null)}};
  auto profiles = draft["profiles"].toArray();
  for (auto item : profiles)
    options.append({item.toObject()["name"].toString(), item.toObject()["id"]});
  choice(rows(top), T("profiles.default", "Standardprofil"), "defaultProfileID",
         options);
  auto toolbar = new QHBoxLayout;
  profileSelection = new QComboBox;
  for (auto item : profiles)
    profileSelection->addItem(item.toObject()["name"].toString());
  auto create = new QPushButton(T("profiles.new", "Neues Profil"));
  create->setObjectName("profiles.create");
  auto remove = new QPushButton(T("common.delete", "Löschen"));
  remove->setObjectName("profiles.delete");
  toolbar->addWidget(profileSelection, 1);
  toolbar->addWidget(create);
  toolbar->addWidget(remove);
  rows(top)->addRow(toolbar);
  profileEditor = new QWidget;
  profileLayout = new QVBoxLayout(profileEditor);
  profileLayout->setContentsMargins(0, 0, 0, 0);
  layout->addWidget(profileEditor, 1);
  selectedProfile = qBound(0, selectedProfile, profiles.size() - 1);
  if (!profiles.isEmpty())
    profileSelection->setCurrentIndex(selectedProfile);
  connect(profileSelection, qOverload<int>(&QComboBox::currentIndexChanged),
          this, [this](int index) {
            selectedProfile = index;
            rebuildProfileEditor();
          });
  connect(create, &QPushButton::clicked, this, [this] {
    auto array = draft["profiles"].toArray();
    if (array.size() >= 50)
      return;
    array.append(QJsonObject{
        {"id", QUuid::createUuid().toString(QUuid::WithoutBraces).toUpper()},
        {"name", T("profiles.new_name", "Neues Profil")}});
    draft["profiles"] = array;
    selectedProfile = array.size() - 1;
    rebuild();
  });
  connect(remove, &QPushButton::clicked, this, [this] {
    auto array = draft["profiles"].toArray();
    if (selectedProfile < 0 || selectedProfile >= array.size())
      return;
    const QJsonValue id = array[selectedProfile].toObject()["id"];
    if (draft["defaultProfileID"] == id)
      draft["defaultProfileID"] = QJsonValue(QJsonValue::Null);
    if (draft["selectedProfileID"] == id)
      draft["selectedProfileID"] = QJsonValue(QJsonValue::Null);
    auto apps = draft["appProfiles"].toObject();
    for (auto it = apps.begin(); it != apps.end();)
      if (it.value() == id)
        it = apps.erase(it);
      else
        ++it;
    draft["appProfiles"] = apps;
    array.removeAt(selectedProfile);
    draft["profiles"] = array;
    selectedProfile = 0;
    rebuild();
  });
  rebuildProfileEditor();
  return page;
}
QWidget *SettingsWindow::profileSection(QString key, QString path,
                                        QWidget *editor, QJsonValue inherited) {
  auto page = new QWidget;
  auto layout = pageLayout(page);
  auto inherit =
      new QCheckBox(T("profiles.inherit", "Globale Einstellung verwenden"));
  const bool isInherited =
      jsonValue(draft, path).isNull() || jsonValue(draft, path).isUndefined();
  inherit->setChecked(isInherited);
  editor->setEnabled(!isInherited);
  editor->setVisible(!isInherited);
  layout->addWidget(inherit);
  auto inheritedHint =
      new QLabel(trText("Die globalen Werte gelten. Deaktivieren Sie die "
                        "Vererbung, um eigene Werte festzulegen."));
  inheritedHint->setWordWrap(true);
  inheritedHint->setVisible(isInherited);
  layout->addWidget(inheritedHint);
  layout->addWidget(editor, 1);
  connect(inherit, &QCheckBox::toggled, this,
          [this, path, inherited](bool value) {
            setJsonValue(draft, path,
                         value ? QJsonValue(QJsonValue::Null) : inherited);
            rebuildProfileEditor();
          });
  Q_UNUSED(key);
  return page;
}
void SettingsWindow::rebuildProfileEditor() {
  if (!profileLayout)
    return;
  while (auto item = profileLayout->takeAt(0)) {
    if (item->widget())
      item->widget()->deleteLater();
    delete item;
  }
  auto array = draft["profiles"].toArray();
  if (selectedProfile < 0 || selectedProfile >= array.size()) {
    profileLayout->addWidget(new QLabel(
        T("profiles.choose_help", "Profil auswählen oder anlegen.")));
    return;
  }
  QString root = "profiles." + QString::number(selectedProfile);
  auto header = section(T("profiles.name", "Profilname"));
  line(rows(header), T("profiles.name", "Name"), root + ".name");
  profileLayout->addWidget(header);
  auto sections = new QTabWidget;
  profileLayout->addWidget(sections, 1);
  auto language = new QWidget;
  auto form = new QFormLayout(language);
  line(form, T("settings.whisper.language", "Sprache"), root + ".language");
  sections->addTab(profileSection("language", root + ".language", language,
                                  jsonValue(draft, "whisper.language")),
                   T("profiles.language", "Sprache"));
  auto vocabularyPage = new QWidget;
  auto vocabularyLayout = pageLayout(vocabularyPage);
  vocabulary(vocabularyLayout, root + ".vocabulary");
  sections->addTab(
      scrollPage(profileSection(
          "vocabulary", root + ".vocabulary", vocabularyPage,
          QJsonObject{{"dictionary", jsonValue(draft, "cleanup.dictionary")},
                      {"dictionaryVariants",
                       jsonValue(draft, "cleanup.dictionaryVariants")}})),
      T("profiles.vocabulary", "Wörterbuch"));
  auto clean = new QWidget;
  auto cleanLayout = pageLayout(clean);
  auto enabled = section(T("profiles.cleanup", "Bereinigung"));
  cleanLayout->addWidget(enabled);
  check(rows(enabled), T("settings.cleanup.enabled"),
        root + ".cleanup.enabled");
  check(rows(enabled), "Nur lokal", root + ".cleanup.localOnly");
  endpoints(cleanLayout, root + ".cleanup.primary", true, root + ".cleanup");
  auto inherited =
      QJsonObject{{"enabled", jsonValue(draft, "cleanup.enabled")},
                  {"localOnly", jsonValue(draft, "cleanup.localOnly")},
                  {"primary", draft["cleanup"]},
                  {"fallbacks", jsonValue(draft, "cleanup.fallbacks")}};
  sections->addTab(scrollPage(profileSection("cleanup", root + ".cleanup",
                                             clean, inherited)),
                   T("profiles.cleanup", "Bereinigung"));
  auto formatting = new QWidget;
  auto formattingForm = new QFormLayout(formatting);
  check(formattingForm, T("formatting.enabled", "Gesprochene Formatierung"),
        root + ".spokenFormatting");
  sections->addTab(profileSection("formatting", root + ".spokenFormatting",
                                  formatting,
                                  jsonValue(draft, "cleanup.spokenFormatting")),
                   T("profiles.formatting", "Formatierung"));
  sections->addTab(scrollPage(profileSection("history", root + ".history",
                                             historyPage(root + ".history"),
                                             draft["history"])),
                   T("profiles.history", "Verlauf"));
  sections->setCurrentIndex(
      qBound(0, selectedProfileSection, sections->count() - 1));
  connect(sections, &QTabWidget::currentChanged, this, [this](int index) {
    if (index >= 0)
      selectedProfileSection = index;
  });
}
QWidget *SettingsWindow::appsPage() {
  auto page = new QWidget;
  auto layout = pageLayout(page);
  auto box = section(T("app_profiles.title", "App-Zuordnung"));
  layout->addWidget(box);
  applicationLabel = new QLabel(lastApplication.isEmpty()
                                    ? trText("Noch kein Eingabeziel erkannt.")
                                    : lastApplication);
  applicationLabel->setTextInteractionFlags(Qt::TextSelectableByMouse);
  rows(box)->addRow(trText("Letztes Eingabeziel"), applicationLabel);
  auto table = new QTableWidget(0, 2);
  table->setObjectName("apps.rules");
  table->setHorizontalHeaderLabels({trText("Linux-App-ID"), trText("Profil")});
  table->horizontalHeader()->setSectionResizeMode(QHeaderView::Stretch);
  rows(box)->addRow(table);
  auto rules = draft["appProfiles"].toObject();
  auto profiles = draft["profiles"].toArray();
  auto saveRules = [this, table] {
    QJsonObject object;
    for (int i = 0; i < table->rowCount(); ++i) {
      auto item = table->item(i, 0);
      auto combo = qobject_cast<QComboBox *>(table->cellWidget(i, 1));
      if (item && combo && !item->text().isEmpty())
        object[item->text()] = combo->currentData().toString();
    }
    draft["appProfiles"] = object;
  };
  auto addRow = [this, table, profiles, saveRules](QString app,
                                                   QString profile) {
    int row = table->rowCount();
    table->insertRow(row);
    table->setItem(row, 0, new QTableWidgetItem(app));
    auto combo = new QComboBox;
    for (auto item : profiles)
      combo->addItem(item.toObject()["name"].toString(),
                     item.toObject()["id"].toString());
    int selected = combo->findData(profile);
    if (selected >= 0)
      combo->setCurrentIndex(selected);
    table->setCellWidget(row, 1, combo);
    connect(combo, qOverload<int>(&QComboBox::currentIndexChanged), this,
            [saveRules](int) { saveRules(); });
  };
  for (auto it = rules.begin(); it != rules.end(); ++it)
    addRow(it.key(), it.value().toString());
  connect(table, &QTableWidget::cellChanged, this,
          [saveRules](int, int) { saveRules(); });
  auto add = new QPushButton(trText("App-Regel hinzufügen"));
  add->setObjectName("apps.add");
  add->setEnabled(!profiles.isEmpty());
  auto remove = new QPushButton(trText("Regel löschen"));
  rows(box)->addRow(add, remove);
  connect(add, &QPushButton::clicked, this, [this, addRow, saveRules] {
    addRow(lastApplication, "");
    saveRules();
  });
  connect(remove, &QPushButton::clicked, this, [table, saveRules] {
    if (table->currentRow() >= 0)
      table->removeRow(table->currentRow());
    saveRules();
  });
  auto help = new QLabel(
      trText("Die tatsächlich erkannte App-ID wird bei der Zielprüfung "
             "angezeigt. Bei unbekanntem oder geschütztem Eingabeziel "
             "bleibt die manuelle Profilauswahl verfügbar."));
  help->setWordWrap(true);
  rows(box)->addRow(help);
  layout->addStretch();
  return page;
}
