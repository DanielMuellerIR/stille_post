#pragma once
#include "ui_common.h"
class AudioImportWindow final : public QDialog {
  Q_OBJECT
public:
  explicit AudioImportWindow(QWidget *parent = nullptr);
  void present();
  void receive(QJsonObject);
  void setAllowed(bool);
signals:
  void command(QJsonObject);

protected:
  void dragEnterEvent(QDragEnterEvent *) override;
  void dropEvent(QDropEvent *) override;

private:
  void chooseFile();
  void selectFile(QUrl);
  void refresh();
  void updateControls();
  bool validFile(QUrl) const;
  QLabel *profile, *reason, *selected, *policy, *status, *note, *origin;
  QProgressBar *progress;
  QPlainTextEdit *result;
  QPushButton *choose, *start, *renew, *cancel, *copy, *recordings;
  QJsonObject reviewed;
  QString path, recordingsPath, resultNote;
  bool active = false, finished = false, allowed = true, reviewing = false,
       copyAllowed = false;
};
