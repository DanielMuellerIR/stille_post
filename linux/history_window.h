#pragma once
#include "ui_common.h"
class HistoryWindow final : public QDialog {
  Q_OBJECT
public:
  explicit HistoryWindow(QWidget *parent = nullptr);
  void present();
  void receive(QJsonObject event);
signals:
  void command(QJsonObject value);

private:
  void query(bool more = false);
  void select();
  void edit();
  void vocabulary();
  void refreshActions();
  void operation(QString name);
  void renderDifference(QJsonArray segments, bool summarized,
                        QTextBrowser *view = nullptr);
  QLineEdit *search;
  QComboBox *status, *period;
  QListWidget *list;
  QPlainTextEdit *text, *raw;
  QTextBrowser *difference;
  QLabel *summary, *detail;
  QPushButton *more, *editButton, *retryButton, *recleanButton,
      *vocabularyButton;
  QTabWidget *versions;
  QJsonObject selected;
  QString vocabularyProfileID, vocabularyLabel;
  QJsonArray entries;
  int generation = 0, offset = 0;
  QPointer<QDialog> editor;
  QPlainTextEdit *editorText = nullptr;
  QString candidate;
  QString editorDifferenceID;
  QPointer<QTextBrowser> editorDifference;
  bool pending = false;
};
