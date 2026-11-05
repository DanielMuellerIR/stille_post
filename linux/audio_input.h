#pragma once
#include <QtCore>
struct pa_mainloop;
struct pa_context;
struct pa_stream;
class AudioInput final : public QObject {
  Q_OBJECT
public:
  explicit AudioInput(QObject *parent = nullptr);
  ~AudioInput() override;
  QJsonArray devices() const;
  bool hasDeviceCatalog() const { return ready && enumerated; }
  bool available(QString uid = {}) const;
  bool isCapturing() const { return active; }
  void start(QString uid);
  void stop(bool flush = true);
signals:
  void samples(QByteArray);
  void failed(QString);
  void devicesChanged(QJsonArray);
  void level(double);

private:
  struct Device {
    QString name;
    quint32 index;
  };
  void connectServer();
  void disconnectServer();
  void querySources();
  void queryDefault();
  void tick();
  void consume();
  void fail(QString);
  void markError(QString);
  QByteArray sourceName(QString uid) const;
  pa_mainloop *loop = nullptr;
  pa_context *context = nullptr;
  pa_stream *stream = nullptr;
  QTimer pump;
  QElapsedTimer clock;
  QMap<QByteArray, Device> catalog, incoming;
  QByteArray defaultSource, selectedSource;
  QString pendingError;
  quint32 selectedIndex = 0xffffffffu;
  qint64 reconnectAt = 0, connectionDeadline = 0;
  bool active = false, systemDefault = false, ready = false, enumerated = false,
       listing = false, refreshAgain = false, catalogDirty = false;
};
