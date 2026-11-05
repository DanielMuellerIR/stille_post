#include "audio_import_window.h"
namespace {
QString timeLabel(double seconds) {
  const int value = qMax(0, int(seconds));
  return QString("%1:%2").arg(value / 60).arg(value % 60, 2, 10, QChar('0'));
}
} // namespace
AudioImportWindow::AudioImportWindow(QWidget *parent) : QDialog(parent) {
  setWindowTitle(trKey("audio_import.title"));
  setObjectName("audioImportWindow");
  resize(720, 640);
  setMinimumSize(620, 520);
  setAcceptDrops(true);
  auto layout = new QVBoxLayout(this);
  layout->setContentsMargins(20, 20, 20, 20);
  layout->setSpacing(12);
  auto title = new QLabel(trKey("audio_import.title"));
  auto titleFont = title->font();
  titleFont.setPointSizeF(titleFont.pointSizeF() + 2);
  titleFont.setBold(true);
  title->setFont(titleFont);
  layout->addWidget(title);
  profile = new QLabel;
  profile->setWordWrap(true);
  layout->addWidget(profile);
  reason = new QLabel;
  reason->setWordWrap(true);
  layout->addWidget(reason);
  auto file = section(trKey("audio_import.choose"));
  selected = new QLabel(trKey("audio_import.no_file"));
  selected->setObjectName("importSelectedFile");
  selected->setSizePolicy(QSizePolicy::Ignored, QSizePolicy::Preferred);
  choose = new QPushButton(trKey("audio_import.choose"));
  choose->setObjectName("chooseImportFile");
  auto row = new QHBoxLayout;
  row->addWidget(selected, 1);
  row->addWidget(choose);
  static_cast<QFormLayout *>(file->layout())->addRow(row);
  layout->addWidget(file);
  auto hint = new QLabel(trKey("audio_import.drop_hint"));
  hint->setWordWrap(true);
  layout->addWidget(hint);
  auto information = new QWidget;
  auto contents = new QVBoxLayout(information);
  contents->setContentsMargins(0, 0, 0, 0);
  contents->setSpacing(12);
  for (const auto key : {"audio_import.limits", "audio_import.audio_policy"}) {
    auto label = new QLabel(trKey(key));
    label->setWordWrap(true);
    contents->addWidget(label);
  }
  policy = new QLabel;
  policy->setWordWrap(true);
  contents->addWidget(policy);
  status = new QLabel(trKey("audio_import.ready"));
  status->setObjectName("audioImportStatus");
  status->setWordWrap(true);
  auto font = status->font();
  font.setBold(true);
  status->setFont(font);
  contents->addWidget(status);
  progress = new QProgressBar;
  progress->hide();
  contents->addWidget(progress);
  note = new QLabel;
  note->setWordWrap(true);
  note->setTextInteractionFlags(Qt::TextSelectableByMouse);
  contents->addWidget(note);
  recordings = new QPushButton(trKey("audio_import.open_audio"));
  recordings->hide();
  contents->addWidget(recordings);
  origin = new QLabel;
  origin->setWordWrap(true);
  contents->addWidget(origin);
  result = new QPlainTextEdit;
  result->setObjectName("audioImportResult");
  result->setReadOnly(true);
  result->setMinimumHeight(130);
  contents->addWidget(result, 1);
  contents->addStretch();
  layout->addWidget(scrollPage(information), 1);
  auto buttons = new QHBoxLayout;
  start = new QPushButton(trKey("audio_import.start"));
  start->setObjectName("startAudioImport");
  renew = new QPushButton(trKey("audio_import.refresh"));
  renew->setObjectName("refreshAudioImport");
  cancel = new QPushButton(trKey("common.cancel"));
  cancel->setObjectName("cancelAudioImport");
  copy = new QPushButton(trKey("audio_import.copy"));
  copy->setObjectName("copyAudioImport");
  auto close = new QPushButton(trText("Schließen"));
  for (auto control : {start, renew, cancel})
    buttons->addWidget(control);
  buttons->addStretch();
  buttons->addWidget(copy);
  buttons->addWidget(close);
  layout->addLayout(buttons);
  connect(choose, &QPushButton::clicked, this, &AudioImportWindow::chooseFile);
  connect(start, &QPushButton::clicked, this, [this] {
    if (active || finished || reviewing || reviewed.isEmpty() ||
        path.isEmpty() || !allowed)
      return;
    active = true;
    note->clear();
    status->setText(trKey("audio_import.decoding"));
    updateControls();
    emit command(
        {{"command", "import"}, {"path", path}, {"reviewed", reviewed}});
  });
  connect(renew, &QPushButton::clicked, this, &AudioImportWindow::refresh);
  connect(cancel, &QPushButton::clicked, this, [this] {
    cancel->setEnabled(false);
    emit command({{"command", "cancelImport"}});
  });
  connect(copy, &QPushButton::clicked, this, [this] {
    if (!copyAllowed)
      return;
    note->setText(trKey(copyText(result->toPlainText())
                            ? "audio_import.copied"
                            : "linux.clipboard.failed"));
  });
  connect(recordings, &QPushButton::clicked, this, [this] {
    if (!recordingsPath.isEmpty())
      QDesktopServices::openUrl(QUrl::fromLocalFile(recordingsPath));
  });
  connect(close, &QPushButton::clicked, this, &QDialog::reject);
  connect(this, &QDialog::finished, this, [this] {
    emit command({{"command", "closeImport"}});
    active = false;
    path.clear();
    reviewed = {};
    result->clear();
    note->clear();
  });
  updateControls();
}
void AudioImportWindow::present() {
  if (!isVisible()) {
    path.clear();
    selected->setText(trKey("audio_import.no_file"));
    refresh();
  }
  show();
  raise();
  activateWindow();
}
void AudioImportWindow::setAllowed(bool value) {
  allowed = value;
  updateControls();
}
void AudioImportWindow::refresh() {
  if (active)
    return;
  finished = false;
  reviewing = true;
  copyAllowed = false;
  result->clear();
  result->hide();
  origin->hide();
  note->clear();
  resultNote.clear();
  origin->clear();
  recordings->hide();
  status->setText(trKey("audio_import.ready"));
  updateControls();
  emit command({{"command", "reviewImport"}});
}
bool AudioImportWindow::validFile(QUrl url) const {
  if (!url.isLocalFile() ||
      (!url.host().isEmpty() &&
       url.host().compare("localhost", Qt::CaseInsensitive)))
    return false;
  const QFileInfo file(url.toLocalFile());
  const auto type =
      QMimeDatabase().mimeTypeForFile(file, QMimeDatabase::MatchExtension);
  return file.isAbsolute() && file.isFile() && file.isReadable() &&
         (type.name().startsWith("audio/") ||
          QStringList{"wav", "wave", "mp3", "m4a", "aac", "flac", "ogg", "opus",
                      "aiff", "aif", "aifc", "caf"}
              .contains(file.suffix().toLower()));
}
void AudioImportWindow::selectFile(QUrl url) {
  if (active)
    return;
  if (!validFile(url)) {
    path.clear();
    selected->setText(trKey("audio_import.no_file"));
    refresh();
    note->setText(trKey("audio_import.invalid_drop"));
    return;
  }
  path = url.toLocalFile();
  selected->setText(QFileInfo(path).fileName());
  selected->setToolTip(path);
  refresh();
}
void AudioImportWindow::chooseFile() {
  if (active)
    return;
  const auto selectedPath = QFileDialog::getOpenFileName(
      this, trKey("audio_import.choose"), {},
      trText("Audio (*.wav *.mp3 *.m4a *.aac *.flac *.ogg *.opus *.aiff *.aif "
             "*.caf);;Alle Dateien (*)"));
  if (!selectedPath.isEmpty())
    selectFile(QUrl::fromLocalFile(selectedPath));
}
void AudioImportWindow::dragEnterEvent(QDragEnterEvent *event) {
  const auto urls = event->mimeData()->urls();
  if (!active && urls.size() == 1 && validFile(urls[0]))
    event->acceptProposedAction();
}
void AudioImportWindow::dropEvent(QDropEvent *event) {
  if (active)
    return;
  const auto urls = event->mimeData()->urls();
  selectFile(urls.size() == 1 ? urls[0] : QUrl());
  event->acceptProposedAction();
}
void AudioImportWindow::receive(QJsonObject event) {
  if (!isVisible())
    return;
  const auto kind = event.value("event").toString();
  if (kind == "importReview") {
    reviewed = event.value("configuration").toObject();
    reviewing = false;
    profile->setText(
        trFormat("profiles.recording", {event.value("profile").toString(),
                                        event.value("language").toString()}) +
        (event.value("localOnly").toBool()
             ? " · " + trKey("profiles.local_only")
             : ""));
    reason->setText(event.value("reason").toString());
    policy->setText(requestPolicyDescription(event));
  } else if (kind == "importStatus") {
    active = event.value("active").toBool();
    finished = event.value("finished").toBool();
    status->setText(event.value("message").toString());
    note->setText(event.value("error").toString().isEmpty()
                      ? resultNote
                      : event.value("error").toString());
    recordingsPath = event.value("recordings").toString();
    recordings->setVisible(!note->text().isEmpty() &&
                           !recordingsPath.isEmpty());
  } else if (kind == "importProgress") {
    const double fraction = event.value("fraction").toDouble(-1);
    progress->setRange(0, fraction < 0 ? 0 : 1000);
    if (fraction >= 0)
      progress->setValue(qBound(0, int(fraction * 1000), 1000));
    progress->setFormat(
        timeLabel(event.value("seconds").toDouble()) + " / " +
        timeLabel(event.value("total").toDouble()) + " · " +
        trFormat("audio_import.segment_many",
                 {QString::number(event.value("segments").toInt())}));
  } else if (kind == "importResult") {
    active = false;
    finished = true;
    const bool failed = event.value("failed").toBool();
    const auto entry = event.value("entry").toObject();
    const auto text = failed ? entry.value("rawText").toString()
                             : event.value("text").toString();
    result->setPlainText(text);
    result->setVisible(!text.isEmpty());
    origin->setVisible(!text.isEmpty());
    copyAllowed = !failed && !text.isEmpty();
    const auto originKey =
        failed ? QString("audio_import.partial")
               : "editor.origin." + event.value("origin").toString("raw");
    origin->setText(trKey(originKey.toUtf8().constData()));
    resultNote = event.value("note").toString();
    if (!resultNote.isEmpty())
      note->setText(resultNote);
  }
  updateControls();
}
void AudioImportWindow::updateControls() {
  choose->setEnabled(!active);
  start->setVisible(!active && !finished);
  start->setEnabled(allowed && !reviewing && !path.isEmpty() &&
                    !reviewed.isEmpty());
  renew->setVisible(!active);
  renew->setText(trKey(finished ? "audio_import.new" : "audio_import.refresh"));
  cancel->setVisible(active);
  cancel->setEnabled(active);
  copy->setVisible(copyAllowed);
  progress->setVisible(active);
}
