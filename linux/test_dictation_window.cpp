#include "test_dictation_window.h"
TestDictationWindow::TestDictationWindow(QWidget *parent) : QDialog(parent) {
  setWindowTitle(trKey("test_dictation.title"));
  setObjectName("testDictationWindow");
  resize(720, 660);
  setMinimumSize(620, 540);
  auto layout = new QVBoxLayout(this);
  layout->setContentsMargins(20, 20, 20, 20);
  layout->setSpacing(12);
  auto title = new QLabel(trKey("test_dictation.title"));
  auto titleFont = title->font();
  titleFont.setPointSizeF(titleFont.pointSizeF() + 2);
  titleFont.setBold(true);
  title->setFont(titleFont);
  layout->addWidget(title);
  profile = new QLabel;
  profile->setWordWrap(true);
  profile->setObjectName("testProfile");
  layout->addWidget(profile);
  auto consent = new QLabel(trKey("test_dictation.consent"));
  consent->setWordWrap(true);
  layout->addWidget(consent);
  policy = new QLabel;
  policy->setWordWrap(true);
  layout->addWidget(policy);
  auto content = new QWidget;
  auto body = new QVBoxLayout(content);
  body->setContentsMargins(0, 0, 0, 0);
  body->setSpacing(12);
  status = new QLabel(trKey("test_dictation.ready"));
  status->setObjectName("testDictationStatus");
  status->setWordWrap(true);
  auto font = status->font();
  font.setBold(true);
  status->setFont(font);
  body->addWidget(status);
  meter = new QProgressBar;
  meter->setRange(0, 100);
  meter->setValue(0);
  meter->setTextVisible(false);
  body->addWidget(meter);
  note = new QLabel;
  note->setWordWrap(true);
  note->setTextInteractionFlags(Qt::TextSelectableByMouse);
  body->addWidget(note);
  auto fixes = new QHBoxLayout;
  microphone = new QPushButton(trKey("test_dictation.microphone_settings"));
  recordings = new QPushButton(trKey("test_dictation.open_recordings"));
  fixes->addWidget(microphone);
  fixes->addWidget(recordings);
  fixes->addStretch();
  body->addLayout(fixes);
  origin = new QLabel(trKey("test_dictation.preview"));
  body->addWidget(origin);
  result = new QPlainTextEdit;
  result->setObjectName("testDictationResult");
  result->setReadOnly(true);
  result->setMinimumHeight(120);
  body->addWidget(result, 1);
  timings = new QLabel;
  timings->setWordWrap(true);
  body->addWidget(timings);
  auto overlap = new QLabel(trKey("test_dictation.overlap"));
  overlap->setWordWrap(true);
  body->addWidget(overlap);
  body->addStretch();
  layout->addWidget(scrollPage(content), 1);
  auto buttons = new QHBoxLayout;
  start = new QPushButton(trKey("test_dictation.start"));
  start->setObjectName("startTestDictation");
  renew = new QPushButton(trKey("test_dictation.refresh"));
  renew->setObjectName("refreshTestDictation");
  stop = new QPushButton(trKey("recording.finish"));
  cancel = new QPushButton(trKey("common.cancel"));
  report = new QPushButton(trKey("test_dictation.copy_report"));
  auto close = new QPushButton(trText("Schließen"));
  for (auto button : {start, renew, stop, cancel})
    buttons->addWidget(button);
  buttons->addStretch();
  buttons->addWidget(report);
  buttons->addWidget(close);
  layout->addLayout(buttons);
  connect(start, &QPushButton::clicked, this, [this] {
    if (active || reviewing || reviewed.isEmpty() || !allowed)
      return;
    result->clear();
    note->clear();
    resultNote.clear();
    active = true;
    updateControls();
    emit command({{"command", "startTest"}, {"reviewed", reviewed}});
  });
  connect(renew, &QPushButton::clicked, this, &TestDictationWindow::refresh);
  connect(stop, &QPushButton::clicked, this,
          [this] { emit command({{"command", "stopTest"}}); });
  connect(cancel, &QPushButton::clicked, this,
          [this] { emit command({{"command", "cancelTest"}}); });
  connect(report, &QPushButton::clicked, this, [this] {
    emit command({{"command", "testReport"},
                  {"version", QCoreApplication::applicationVersion()}});
  });
  connect(microphone, &QPushButton::clicked, this,
          [this] { emit command({{"command", "microphoneSettings"}}); });
  connect(recordings, &QPushButton::clicked, this, [this] {
    if (!recordingsPath.isEmpty())
      QDesktopServices::openUrl(QUrl::fromLocalFile(recordingsPath));
  });
  connect(close, &QPushButton::clicked, this, &QDialog::reject);
  connect(this, &QDialog::finished, this,
          [this] { emit command({{"command", "closeTest"}}); });
  updateControls();
}
void TestDictationWindow::present() {
  if (!isVisible())
    refresh();
  show();
  raise();
  activateWindow();
}
void TestDictationWindow::refresh() {
  if (active)
    return;
  reviewing = true;
  state = "ready";
  hasAttempt = false;
  result->clear();
  result->hide();
  origin->hide();
  timings->clear();
  timings->hide();
  note->clear();
  resultNote.clear();
  status->setText(trKey("test_dictation.ready"));
  updateControls();
  emit command({{"command", "reviewTest"}});
}
void TestDictationWindow::setAllowed(bool value) {
  allowed = value;
  updateControls();
}
void TestDictationWindow::receive(QJsonObject event) {
  if (!isVisible())
    return;
  const auto kind = event.value("event").toString();
  if (kind == "testReview") {
    reviewed = event.value("configuration").toObject();
    reviewing = false;
    profile->setText(
        trFormat("profiles.recording", {event.value("profile").toString(),
                                        event.value("language").toString()}) +
        (event.value("localOnly").toBool()
             ? " · " + trKey("profiles.local_only")
             : "") +
        "\n" + event.value("reason").toString());
    policy->setText(requestPolicyDescription(event) + "\n" +
                    trKey("test_dictation.audio_policy"));
  } else if (kind == "testStatus") {
    state = event.value("state").toString();
    active = event.value("active").toBool();
    hasAttempt = state != "ready";
    timings->setVisible(hasAttempt);
    status->setText(event.value("message").toString());
    note->setText(event.value("error").toString().isEmpty()
                      ? resultNote
                      : event.value("error").toString());
    recordingsPath = event.value("recordings").toString();
    meter->setValue(qBound(
        0, int((event.value("levelDb").toDouble(-120) + 60) * 100 / 60), 100));
    const auto phases = event.value("timings").toObject();
    QStringList lines;
    for (auto pair : QList<QPair<QString, const char *>>{
             {"preparation", "test_dictation.preparation"},
             {"recording", "test_dictation.recording"},
             {"transcription", "test_dictation.transcription"},
             {"cleanup", "test_dictation.cleanup"}})
      lines << trKey(pair.second) + ": " +
                   (phases.value(pair.first).isDouble()
                        ? QLocale().toString(
                              phases.value(pair.first).toDouble(), 'f', 2) +
                              " s"
                        : QString("—"));
    timings->setText(lines.join("\n"));
  } else if (kind == "testResult") {
    result->setPlainText(event.value("failed").toBool()
                             ? QString()
                             : event.value("text").toString());
    result->setVisible(!result->toPlainText().isEmpty());
    origin->setVisible(!result->toPlainText().isEmpty());
    const auto key = "editor.origin." + event.value("origin").toString("raw");
    origin->setText(trKey(key.toUtf8().constData()));
    resultNote = event.value("note").toString();
    if (!resultNote.isEmpty())
      note->setText(resultNote);
  } else if (kind == "testReport") {
    note->setText(trKey(copyText(event.value("text").toString())
                            ? "test_dictation.copied"
                            : "diagnosis.copy_failed"));
  }
  updateControls();
}
void TestDictationWindow::updateControls() {
  const bool ready = state == "ready";
  start->setVisible(!active && ready);
  start->setEnabled(allowed && !reviewing && !reviewed.isEmpty());
  renew->setVisible(!active);
  renew->setText(
      trKey(ready ? "test_dictation.refresh" : "test_dictation.new"));
  stop->setVisible(active);
  stop->setEnabled(state == "recording" || state == "paused");
  cancel->setVisible(active);
  report->setVisible(hasAttempt && !active);
  microphone->setVisible(state == "failed");
  recordings->setVisible(state == "failed" && !recordingsPath.isEmpty());
}
