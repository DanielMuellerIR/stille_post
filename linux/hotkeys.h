#pragma once
#include <QtCore>
#include <QtDBus>

struct PortalShortcut {
  QString id;
  QVariantMap options;
};
using PortalShortcuts = QList<PortalShortcut>;
Q_DECLARE_METATYPE(PortalShortcut)
Q_DECLARE_METATYPE(PortalShortcuts)
QDBusArgument &operator<<(QDBusArgument &, const PortalShortcut &);
const QDBusArgument &operator>>(const QDBusArgument &, PortalShortcut &);

class GlobalShortcuts final : public QObject {
  Q_OBJECT
public:
  explicit GlobalShortcuts(QObject *parent = nullptr);
  ~GlobalShortcuts() override;
  void bind(QString dictate = "CTRL+ALT+space", QString recall = "CTRL+ALT+r");
  void configure();
  QString description() const { return label; }
  bool isReady() const { return ready; }
  QMap<QString, QString> shortcutLabels() const { return assigned; }
signals:
  void pressed(QString id);
  void released(QString id);
  void status(QString text, bool ready);
private slots:
  void response(uint code, QVariantMap result, const QDBusMessage &message);
  void activated(QDBusObjectPath session, QString id, qulonglong timestamp,
                 QVariantMap options);
  void deactivated(QDBusObjectPath session, QString id, qulonglong timestamp,
                   QVariantMap options);
  void closed(QVariantMap, const QDBusMessage &);
  void shortcutsChanged(QDBusObjectPath, PortalShortcuts);

private:
  void request(QString method, QList<QVariant> arguments, QString token);
  void setStatus(QString text, bool ready = false);
  void closeSession();
  void updateAssignments(PortalShortcuts);
  QDBusConnection bus;
  QDBusObjectPath session;
  QString pendingPath, pendingMethod, sender, trigger, recallTrigger, label;
  QTimer timeout;
  bool ready = false;
  bool registered = false;
  bool registering = false;
  quint64 generation = 0;
  QSet<QString> down;
  QMap<QString, QString> assigned;
};
