#pragma once
#include "accessibility.h"
#include "audio_import_window.h"
#include "audio_input.h"
#include "desktop_placement.h"
#include "history_window.h"
#include "hotkeys.h"
#include "settings_window.h"
#include "test_dictation_window.h"
#include "x11_hotkeys.h"
class AppController final : public QObject {
  Q_OBJECT
public:
  explicit AppController(bool isolated, QObject *parent = nullptr);
  ~AppController() override;
  void showSettings(QString tab = {});
  void showHistory();
  void toggle();

private slots:
  void screenStateChanged(bool active);

private:
  void interruptHold();
  bool eventFilter(QObject *, QEvent *) override;
  void shutdownWorker();
  void send(QJsonObject);
  void readWorker();
  void receive(QJsonObject);
  void bindHotkeys();
  void keyPressed(QString);
  void keyReleased(QString);
  void start(bool hold = false);
  void stop();
  void changeState(QString, QString profile = {});
  void notice(QString, bool error = false);
  void rebuildMenu();
  void result(QJsonObject);
  void preview(QString text, QString title, QString token = {},
               bool insert = false, QJsonObject outcome = {});
  void presentNextPreview();
  void recall();
  void copyOrPreview(QString text, QString message, QString failureNote = {});
  void deliver(QString text, QString token, bool restore = false,
               QString note = {});
  void diagnostics();
  void testDictation();
  void importAudio();
  void cleanupSelection();
  void showPairing(QJsonObject);
  void checkUpdates(bool silent = false);
  void setAutostart(bool);
  void sound(QString);
  void positionOverlay();
  SettingsWindow settings;
  HistoryWindow history;
  AudioInput audio;
  AccessibleTarget target;
  DesktopPlacement placement;
  QPoint placementCursor;
  QRect placementArea;
  GlobalShortcuts portal;
  X11Shortcuts x11;
  QProcess worker;
  QByteArray messages;
  QJsonObject configuration;
  QJsonObject historyPolicy;
  QSystemTrayIcon tray;
  QMenu menu;
  QWidget overlay;
  QLabel *stateLabel, *profileLabel, *durationLabel, *liveText, *contextLabel,
      *detailLabel;
  QProgressBar *meter;
  QPushButton *pauseButton, *stopButton;
  struct Preview {
    QString text, title, token;
    bool insert;
    QJsonObject outcome;
  };
  QQueue<Preview> previewQueue;
  QPointer<QDialog> resultWindow;
  QString recallToken;
  QPointer<TestDictationWindow> testWindow;
  QPointer<QDialog> selectionProgress;
  QPointer<AudioImportWindow> importWindow;
  QString sessionKind = "dictation";
  QString state = "idle", hotkeyText, targetToken, captureRequest,
          selectionToken;
  QHash<QString, QString> pendingInsertions, pendingNotes;
  bool hotkeyReady = false, accessible = false, isolated = false, held = false,
       pendingHold = false, capturingTarget = false, initialized = false,
       shutdown = false, updating = false;
  bool auxiliaryBusy = false;
  qint64 testBytes = 0;
  double testPeak = -120;
};
