#pragma once
#include "ui_common.h"
class TestDictationWindow final : public QDialog {
  Q_OBJECT
public:
  explicit TestDictationWindow(QWidget *parent = nullptr);
  void present();
  void receive(QJsonObject);
  void setAllowed(bool);
signals:
  void command(QJsonObject);

private:
  void refresh();
  void updateControls();
  QLabel *profile, *policy, *status, *timings, *note, *origin;
  QProgressBar *meter;
  QPlainTextEdit *result;
  QPushButton *start, *renew, *stop, *cancel, *report, *recordings, *microphone;
  QJsonObject reviewed;
  QString state = "ready", recordingsPath, resultNote;
  bool allowed = true, active = false, reviewing = true, hasAttempt = false;
};
