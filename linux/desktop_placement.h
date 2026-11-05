#pragma once
#include <QtCore>
#include <QtDBus>
class DesktopPlacement final : public QObject, protected QDBusContext {
  Q_OBJECT
  Q_CLASSINFO("D-Bus Interface",
              "io.github.danielmuellerir.stillepost.Placement")
public:
  explicit DesktopPlacement(QObject *parent = nullptr);
  ~DesktopPlacement() override;
  void request();
  bool isPending() const { return !token.isEmpty(); }
signals:
  void ready(QPoint cursor, QRect area);
  void failed();
public slots:
  Q_SCRIPTABLE void report(QString token, QString coordinates);

private:
  void finish(bool success);
  QDBusConnection bus;
  QTemporaryFile script;
  QTimer timeout;
  QString token, owner, name;
  bool registered = false;
};
