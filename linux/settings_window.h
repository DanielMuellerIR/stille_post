#pragma once
#include "ui_common.h"
class SettingsWindow final : public QDialog {
  Q_OBJECT
public:
  explicit SettingsWindow(QWidget *parent = nullptr);
  void present(QJsonObject configuration, QJsonArray devices,
               QString tab = QString());
  void setHotkeyStatus(QString text, bool ready);
  void receive(QJsonObject event);
  void setShortcutDescriptions(QMap<QString, QString> labels);
  void setAudioDevices(QJsonArray value);
  void setInputTarget(QString application);
signals:
  void saveRequested(QJsonObject value, QJsonObject expected);
  void command(QJsonObject value);
  void configureHotkeys();
  void hotkeyCapture(bool capturing);

private:
  void populateAudioDevices();
  void rebuild();
  QWidget *generalPage();
  QWidget *profilesPage();
  QWidget *appsPage();
  QWidget *cleanupPage(QString root = "cleanup", bool vocabulary = true);
  QWidget *speechPage();
  QWidget *recordingPage();
  QWidget *historyPage(QString root = "history");
  QCheckBox *check(QFormLayout *form, QString text, QString path);
  QLineEdit *line(QFormLayout *form, QString text, QString path);
  QComboBox *choice(QFormLayout *form, QString text, QString path,
                    QList<QPair<QString, QJsonValue>> options);
  QDoubleSpinBox *number(QFormLayout *form, QString text, QString path,
                         double minimum, double maximum, double step = .1);
  void endpoints(QVBoxLayout *, QString root, bool includePrimary,
                 QString fallbackRoot = QString());
  void vocabulary(QVBoxLayout *, QString root);
  QWidget *profileSection(QString key, QString path, QWidget *editor,
                          QJsonValue inherited);
  void rebuildProfileEditor();
  QJsonObject draft, expected;
  QJsonArray devices;
  QTabWidget *tabs;
  QLabel *message, *hotkeyStatus = nullptr;
  QPointer<QLabel> applicationLabel;
  QPointer<QComboBox> audioDeviceChoice;
  QPointer<QLabel> sileroStatusLabel;
  QString lastApplication;
  QMap<QString, QString> shortcutDescriptions;
  QMap<QString, QPointer<QLabel>> shortcutFields;
  QPushButton *save;
  QPushButton *cancelOperation;
  QComboBox *profileSelection = nullptr;
  QWidget *profileEditor = nullptr;
  QVBoxLayout *profileLayout = nullptr;
  int selectedProfile = -1;
  int selectedProfileSection = 0;
  bool loading = false;
};
