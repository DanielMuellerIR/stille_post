#pragma once
#include <QtCore>
class AccessibleTarget final : public QObject {
  Q_OBJECT
public:
  explicit AccessibleTarget(QObject *parent = nullptr);
  ~AccessibleTarget() override;
  void capture(QString request, bool selection = false);
  void insert(QString token, QString text, bool restoreFocus = false);
  void clear(QString token);
signals:
  void captured(QJsonObject);
  void inserted(QString token, bool success, QString reason, bool modified);
  void availability(bool ready);
  void applicationChanged(QString application);

private:
  QThread thread;
  QObject *agent = nullptr;
};
