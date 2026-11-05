#include "history_window.h"
namespace {
QString H(const char *key, QString fallback = {}) {
  return trKey(key, fallback);
}
} // namespace
HistoryWindow::HistoryWindow(QWidget *parent) : QDialog(parent) {
  setWindowTitle(H("window.history.title", "Stille Post — Verlauf"));
  resize(1000, 740);
  setMinimumSize(800, 600);
  auto layout = new QVBoxLayout(this);
  layout->setContentsMargins(16, 16, 16, 16);
  auto filters = new QHBoxLayout;
  search = new QLineEdit;
  search->setPlaceholderText(
      H("history.search", "Im lokalen Verlauf suchen …"));
  search->setObjectName("historySearch");
  status = new QComboBox;
  status->addItem(trText("Alle Zustände"), "all");
  status->addItem(trText("Erfolgreich"), "successful");
  status->addItem(trText("Fehlgeschlagen"), "failed");
  period = new QComboBox;
  period->addItem(trText("Gesamter Zeitraum"), "all");
  period->addItem(trText("Heute"), "today");
  period->addItem(trText("Letzte 7 Tage"), "lastSevenDays");
  period->addItem(trText("Letzte 30 Tage"), "lastThirtyDays");
  filters->addWidget(search, 1);
  filters->addWidget(status);
  filters->addWidget(period);
  layout->addLayout(filters);
  auto timer = new QTimer(this);
  timer->setSingleShot(true);
  timer->setInterval(180);
  connect(search, &QLineEdit::textChanged, timer, qOverload<>(&QTimer::start));
  connect(timer, &QTimer::timeout, this, [this] { query(); });
  connect(status, qOverload<int>(&QComboBox::currentIndexChanged), this,
          [this](int) { query(); });
  connect(period, qOverload<int>(&QComboBox::currentIndexChanged), this,
          [this](int) { query(); });
  auto split = new QSplitter;
  list = new QListWidget;
  list->setTextElideMode(Qt::ElideRight);
  list->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
  list->setObjectName("historyEntries");
  list->setMinimumWidth(240);
  split->addWidget(list);
  auto content = new QWidget;
  auto body = new QVBoxLayout(content);
  body->setContentsMargins(16, 0, 0, 0);
  detail = new QLabel;
  detail->setWordWrap(true);
  body->addWidget(detail);
  versions = new QTabWidget;
  text = new QPlainTextEdit;
  text->setReadOnly(true);
  text->setObjectName("historyFinalText");
  raw = new QPlainTextEdit;
  raw->setReadOnly(true);
  difference = new QTextBrowser;
  versions->addTab(text, trText("Ergebnis"));
  versions->addTab(raw, trText("Rohtext"));
  versions->addTab(difference, trText("Änderungsvergleich"));
  body->addWidget(versions, 1);
  split->addWidget(content);
  split->setStretchFactor(1, 1);
  layout->addWidget(split, 1);
  auto actions = new QHBoxLayout;
  auto copy = new QPushButton(H("common.copy", "Kopieren"));
  editButton = new QPushButton(trText("Korrigieren …"));
  editButton->setObjectName("historyEdit");
  recleanButton = new QPushButton(trText("Erneut bereinigen …"));
  retryButton = new QPushButton(trText("Audio erneut transkribieren"));
  vocabularyButton = new QPushButton(trText("Ins Wörterbuch …"));
  auto remove = new QPushButton(H("common.delete", "Löschen"));
  for (auto b :
       {copy, editButton, recleanButton, retryButton, vocabularyButton, remove})
    actions->addWidget(b);
  layout->addLayout(actions);
  connect(copy, &QPushButton::clicked, this, [this] {
    if (!copyText(versions->currentIndex() == 1 ? raw->toPlainText()
                                                : text->toPlainText()))
      summary->setText(trKey("linux.clipboard.failed"));
  });
  connect(editButton, &QPushButton::clicked, this, &HistoryWindow::edit);
  connect(vocabularyButton, &QPushButton::clicked, this,
          &HistoryWindow::vocabulary);
  connect(retryButton, &QPushButton::clicked, this,
          [this] { operation("retryHistory"); });
  connect(recleanButton, &QPushButton::clicked, this,
          [this] { operation("recleanHistory"); });
  connect(remove, &QPushButton::clicked, this, [this] {
    if (selected.isEmpty())
      return;
    if (QMessageBox::question(this, H("common.delete", "Löschen"),
                              "Diesen Eintrag und gegebenenfalls sein "
                              "Diagnose-Audio endgültig löschen?") ==
        QMessageBox::Yes) {
      emit command({{"command", "deleteHistory"}, {"id", selected["id"]}});
    }
  });
  auto footer = new QHBoxLayout;
  summary = new QLabel;
  more = new QPushButton(trText("Weitere Einträge laden"));
  auto reload = new QPushButton(trText("Aktualisieren"));
  auto removeAll = new QPushButton(trText("Alle löschen …"));
  footer->addWidget(summary, 1);
  footer->addWidget(more);
  footer->addWidget(reload);
  footer->addWidget(removeAll);
  layout->addLayout(footer);
  connect(more, &QPushButton::clicked, this, [this] { query(true); });
  connect(reload, &QPushButton::clicked, this, [this] { query(); });
  connect(removeAll, &QPushButton::clicked, this, [this] {
    if (QMessageBox::warning(this, "Gesamten Verlauf löschen",
                             "Alle Einträge und zurückbehaltenen "
                             "Fehleraufnahmen endgültig löschen?",
                             QMessageBox::Yes | QMessageBox::Cancel) ==
        QMessageBox::Yes)
      emit command({{"command", "deleteAllHistory"}});
  });
  connect(list, &QListWidget::currentRowChanged, this,
          [this](int) { select(); });
  refreshActions();
}
void HistoryWindow::present() {
  show();
  raise();
  activateWindow();
  query();
}
void HistoryWindow::query(bool loadMore) {
  if (!loadMore) {
    ++generation;
    offset = 0;
  } else
    offset = entries.size();
  emit command({{"command", "history"},
                {"text", search->text()},
                {"status", status->currentData().toString()},
                {"period", period->currentData().toString()},
                {"queryId", generation},
                {"offset", offset}});
}
void HistoryWindow::receive(QJsonObject event) {
  const auto kind = event["event"].toString();
  if (kind == "config") {
    vocabularyProfileID = event["vocabularyProfileID"].toString();
    vocabularyLabel = event["vocabularyLabel"].toString();
    return;
  }
  if (kind == "historyChanged") {
    if (isVisible())
      query();
    return;
  }
  if (kind == "history") {
    if (event["queryId"].toInt() != generation)
      return;
    const QString previous = selected["id"].toString();
    if (offset == 0) {
      entries = {};
      list->clear();
    }
    for (auto item : event["entries"].toArray()) {
      auto entry = item.toObject();
      entries.append(entry);
      QString label =
          (entry["status"] == "ok" ? "✓ " : "⚠ ") +
          nativeDate(entry["date"].toDouble()) + " · " +
          QString::number(entry["durationSec"].toDouble(), 'f', 0) + " s\n" +
          (entry["private"].toBool() ? "Ohne Textverlauf"
                                     : entry["cleanText"].toString().left(85));
      auto row = new QListWidgetItem(label, list);
      row->setData(Qt::UserRole, entry["id"].toString());
    }
    int index = 0;
    for (int i = 0; i < entries.size(); ++i)
      if (entries[i].toObject()["id"] == previous)
        index = i;
    if (!entries.isEmpty())
      list->setCurrentRow(index);
    else {
      selected = {};
      text->clear();
      raw->clear();
      detail->clear();
      difference->clear();
    }
    summary->setText(trText("%1 von %2 Einträgen")
                         .arg(entries.size())
                         .arg(event["total"].toInt(entries.size())));
    more->setEnabled(entries.size() < event["total"].toInt());
    pending = false;
    refreshActions();
  } else if (kind == "historySaved" || kind == "vocabularySaved" ||
             kind == "historyDeleted" || kind == "historyChanged") {
    if (editor) {
      editor->accept();
      editor->deleteLater();
      editor = nullptr;
    }
    pending = false;
    query();
  } else if (kind == "difference" && editorDifference &&
             event["entryID"] == editorDifferenceID)
    renderDifference(event["segments"].toArray(), event["summarized"].toBool(),
                     editorDifference);
  else if (kind == "difference" && event["entryID"] == selected["id"])
    renderDifference(event["segments"].toArray(), event["summarized"].toBool());
  else if (kind == "recleanupPreview") {
    pending = false;
    refreshActions();
    candidate = event["candidate"].toString();
    auto dialog = new QDialog(this);
    dialog->setWindowTitle(trText("Erneute Bereinigung prüfen"));
    dialog->setWindowModality(Qt::WindowModal);
    dialog->resize(760, 520);
    auto layout = new QVBoxLayout(dialog);
    auto compare = new QSplitter;
    auto before = new QPlainTextEdit(event["before"].toString());
    auto after = new QPlainTextEdit(event["text"].toString());
    before->setReadOnly(true);
    after->setReadOnly(true);
    compare->addWidget(before);
    compare->addWidget(after);
    layout->addWidget(compare, 1);
    auto buttons = new QDialogButtonBox;
    auto accept =
        buttons->addButton("Übernehmen", QDialogButtonBox::AcceptRole);
    buttons->addButton(QDialogButtonBox::Cancel);
    layout->addWidget(buttons);
    connect(accept, &QPushButton::clicked, this, [this, dialog] {
      pending = true;
      emit command({{"command", "acceptRecleanup"}, {"candidate", candidate}});
      dialog->accept();
      dialog->deleteLater();
    });
    connect(buttons, &QDialogButtonBox::rejected, dialog, &QDialog::reject);
    const auto id = candidate;
    connect(dialog, &QDialog::rejected, this, [this, id] {
      emit command({{"command", "discardRecleanup"}, {"candidate", id}});
    });
    dialog->setAttribute(Qt::WA_DeleteOnClose);
    dialog->show();
  } else if (kind == "error" && isVisible()) {
    pending = false;
    detail->setText(event["message"].toString());
    if (editor)
      if (auto error = editor->findChild<QLabel *>("historyEditorError"))
        error->setText(event["message"].toString());
    refreshActions();
  }
}
void HistoryWindow::select() {
  int index = list->currentRow();
  if (index < 0 || index >= entries.size()) {
    selected = {};
    refreshActions();
    return;
  }
  selected = entries[index].toObject();
  text->setPlainText(selected["cleanText"].toString());
  raw->setPlainText(selected["rawText"].toString());
  QString metadata =
      nativeDate(selected["date"].toDouble()) + " · " +
      QString::number(selected["durationSec"].toDouble(), 'f', 1) + " s";
  if (selected.contains("cleanupSec"))
    metadata += " · " + trText("Bereinigung") + " " +
                QString::number(selected["cleanupSec"].toDouble(), 'f', 2) +
                " s";
  if (selected.contains("cleanupEndpoint"))
    metadata += "\n" + selected["cleanupEndpoint"].toString();
  if (!selected["diagnostic"].toString().isEmpty())
    metadata += "\n" + selected["diagnostic"].toString();
  detail->setText(metadata);
  while (versions->count() > 3) {
    auto page = versions->widget(3);
    versions->removeTab(3);
    page->deleteLater();
  }
  if (selected.contains("originalCleanText")) {
    auto original =
        new QPlainTextEdit(selected["originalCleanText"].toString());
    original->setReadOnly(true);
    versions->addTab(original, trText("Ursprüngliches Ergebnis"));
  }
  int number = 1;
  for (auto item : selected["previousResults"].toArray()) {
    auto old = new QPlainTextEdit(item.toObject()["text"].toString());
    old->setReadOnly(true);
    versions->addTab(old, trText("Vorherige Fassung %1").arg(number++));
  }
  emit command({{"command", "difference"},
                {"entryID", selected["id"]},
                {"before", selected["rawText"]},
                {"after", selected["cleanText"]}});
  refreshActions();
}
void HistoryWindow::refreshActions() {
  editButton->setEnabled(!pending && selected["canEdit"].toBool());
  recleanButton->setEnabled(!pending && selected["canEdit"].toBool());
  vocabularyButton->setEnabled(!pending && selected["canEdit"].toBool());
  retryButton->setEnabled(!pending && selected["canRetry"].toBool());
}
void HistoryWindow::operation(QString name) {
  if (selected.isEmpty() || pending)
    return;
  pending = true;
  refreshActions();
  emit command({{"command", name}, {"expected", selected}});
  detail->setText(trText("Verarbeitung läuft …"));
}
void HistoryWindow::edit() {
  if (!selected["canEdit"].toBool() || pending)
    return;
  editor = new QDialog(this);
  editor->setWindowTitle(trText("Textkorrektur"));
  editor->setWindowModality(Qt::WindowModal);
  editor->setAttribute(Qt::WA_DeleteOnClose);
  editor->resize(760, 520);
  auto layout = new QVBoxLayout(editor);
  auto original =
      new QLabel(trText("Der Rohtext bleibt unverändert. Die bisherige "
                        "Ergebnisfassung bleibt nachvollziehbar."));
  original->setWordWrap(true);
  layout->addWidget(original);
  editorText = new QPlainTextEdit(selected["cleanText"].toString());
  editorText->setObjectName("historyCorrection");
  auto pages = new QTabWidget;
  pages->addTab(editorText, trText("Bearbeiten"));
  editorDifference = new QTextBrowser;
  pages->addTab(editorDifference, trText("Änderungsvergleich"));
  layout->addWidget(pages, 1);
  editorDifferenceID =
      "editor-" + QUuid::createUuid().toString(QUuid::WithoutBraces);
  auto comparison = new QTimer(editor);
  comparison->setSingleShot(true);
  comparison->setInterval(180);
  connect(editorText, &QPlainTextEdit::textChanged, comparison,
          [comparison] { comparison->start(); });
  connect(comparison, &QTimer::timeout, editor,
          [this, before = QJsonValue(selected["cleanText"]),
           id = editorDifferenceID] {
            emit command({{"command", "difference"},
                          {"entryID", id},
                          {"before", before},
                          {"after", editorText->toPlainText()}});
          });
  comparison->start();
  auto error = new QLabel;
  error->setObjectName("historyEditorError");
  error->setWordWrap(true);
  layout->addWidget(error);
  auto buttons =
      new QDialogButtonBox(QDialogButtonBox::Save | QDialogButtonBox::Cancel);
  layout->addWidget(buttons);
  const auto expected = selected;
  connect(buttons, &QDialogButtonBox::accepted, this, [this, expected] {
    pending = true;
    refreshActions();
    emit command({{"command", "editHistory"},
                  {"expected", expected},
                  {"text", editorText->toPlainText()}});
  });
  connect(buttons, &QDialogButtonBox::rejected, editor, &QDialog::reject);
  connect(editor, &QDialog::finished, this, [this] {
    pending = false;
    refreshActions();
  });
  editor->show();
}
void HistoryWindow::vocabulary() {
  if (!selected["canEdit"].toBool() || pending)
    return;
  const auto expected = selected;
  const auto profile = vocabularyProfileID, label = vocabularyLabel;
  editor = new QDialog(this);
  editor->setAttribute(Qt::WA_DeleteOnClose);
  editor->setWindowModality(Qt::WindowModal);
  editor->setWindowTitle(trText("Korrektur ins Wörterbuch übernehmen"));
  auto layout = new QFormLayout(editor);
  auto term = new QLineEdit;
  auto variant = new QLineEdit;
  layout->addRow(trText("Zielschreibweise"), term);
  layout->addRow(trText("Verhörvariante (optional)"), variant);
  auto note = new QLabel(
      trText(
          "Nur diese ausdrückliche Übernahme ändert das Wörterbuch des aktiven "
          "Profils. Der Text wird nicht zum Lernen an einen Dienst gesendet.") +
      "\n" + label);
  note->setWordWrap(true);
  layout->addRow(note);
  auto error = new QLabel;
  error->setObjectName("historyEditorError");
  error->setWordWrap(true);
  layout->addRow(error);
  auto buttons =
      new QDialogButtonBox(QDialogButtonBox::Save | QDialogButtonBox::Cancel);
  layout->addRow(buttons);
  connect(buttons, &QDialogButtonBox::accepted, this,
          [this, expected, profile, term, variant] {
            if (pending)
              return;
            pending = true;
            refreshActions();
            emit command({{"command", "addVocabulary"},
                          {"expected", expected},
                          {"vocabularyProfileID", profile},
                          {"term", term->text()},
                          {"variant", variant->text()}});
          });
  connect(buttons, &QDialogButtonBox::rejected, editor, &QDialog::reject);
  connect(editor, &QDialog::finished, this, [this] {
    pending = false;
    refreshActions();
  });
  editor->show();
}
void HistoryWindow::renderDifference(QJsonArray segments, bool summarized,
                                     QTextBrowser *view) {
  if (!view)
    view = difference;
  if (summarized) {
    view->setPlainText(trText(
        "Großer Unterschied — bitte die vollständigen Fassungen vergleichen."));
    return;
  }
  QString html = "<p style='white-space:pre-wrap'>";
  for (auto value : segments) {
    auto part = value.toObject();
    auto escaped =
        part["text"].toString().toHtmlEscaped().replace("\n", "<br>");
    auto kind = part["kind"].toString();
    if (kind == "removed")
      html += "<span "
              "style='background:#ffd6d6;color:#6f1111;text-decoration:line-"
              "through'>" +
              escaped + "</span>";
    else if (kind == "added")
      html += "<span style='background:#cfefd8;color:#174c26'>" + escaped +
              "</span>";
    else
      html += escaped;
  }
  view->setHtml(html + "</p>");
}
