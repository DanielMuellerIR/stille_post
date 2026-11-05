#pragma once
#include <QtCore>
struct _XDisplay;
class X11Shortcuts final : public QObject {
  Q_OBJECT
public:
  explicit X11Shortcuts(QObject *parent = nullptr);
  ~X11Shortcuts() override;
  bool bind(QString dictate, QString recall);
  void suspend();
  bool isReady() const { return ready; }
signals:
  void pressed(QString);
  void released(QString);
  void status(QString, bool);

private:
  void poll();
  _XDisplay *display = nullptr;
  QTimer timer;
  QHash<unsigned int, QString> actions;
  QHash<unsigned int, QString> down;
  QSet<unsigned int> heldBeforeBinding;
  bool ready = false;
};
