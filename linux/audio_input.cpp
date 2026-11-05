#include "audio_input.h"
#include <cmath>
#include <cstring>
#include <pulse/pulseaudio.h>
AudioInput::AudioInput(QObject *parent) : QObject(parent) {
  clock.start();
  pump.setInterval(10);
  connect(&pump, &QTimer::timeout, this, &AudioInput::tick);
  connectServer();
  pump.start();
}
AudioInput::~AudioInput() {
  stop(false);
  disconnectServer();
}
QByteArray AudioInput::sourceName(QString uid) const {
  return uid.isEmpty() ? defaultSource
                       : QByteArray::fromBase64(uid.startsWith("pulse:")
                                                    ? uid.mid(6).toLatin1()
                                                    : uid.toLatin1());
}
QJsonArray AudioInput::devices() const {
  QJsonArray result;
  for (auto it = catalog.cbegin(); it != catalog.cend(); ++it)
    result.append(QJsonObject{
        {"name", it->name},
        {"id", "pulse:" + QString::fromLatin1(it.key().toBase64())}});
  return result;
}
bool AudioInput::available(QString uid) const {
  return ready && catalog.contains(sourceName(uid));
}
void AudioInput::markError(QString message) {
  if (pendingError.isEmpty())
    pendingError = message;
}
void AudioInput::connectServer() {
  reconnectAt = clock.elapsed() + 1000;
  loop = pa_mainloop_new();
  if (!loop)
    return;
  context = pa_context_new(pa_mainloop_get_api(loop), "Stille Post");
  if (!context) {
    disconnectServer();
    return;
  }
  connectionDeadline = clock.elapsed() + 3000;
  pa_context_set_state_callback(
      context,
      [](pa_context *context, void *data) {
        auto self = static_cast<AudioInput *>(data);
        if (pa_context_get_state(context) == PA_CONTEXT_READY) {
          self->ready = true;
          auto operation = pa_context_subscribe(
              context,
              pa_subscription_mask_t(PA_SUBSCRIPTION_MASK_SOURCE |
                                     PA_SUBSCRIPTION_MASK_SERVER),
              [](pa_context *, int success, void *data) {
                auto self = static_cast<AudioInput *>(data);
                if (!success) {
                  self->markError(
                      "Audio-Geräteüberwachung konnte nicht gestartet werden.");
                  return;
                }
                self->querySources();
                self->queryDefault();
              },
              self);
          if (operation)
            pa_operation_unref(operation);
          else
            self->markError(
                "Audio-Geräteüberwachung konnte nicht gestartet werden.");
        }
      },
      this);
  pa_context_set_subscribe_callback(
      context,
      [](pa_context *, pa_subscription_event_type_t event, uint32_t index,
         void *data) {
        auto self = static_cast<AudioInput *>(data);
        const auto facility = event & PA_SUBSCRIPTION_EVENT_FACILITY_MASK;
        if (facility == PA_SUBSCRIPTION_EVENT_SOURCE) {
          if ((event & PA_SUBSCRIPTION_EVENT_TYPE_MASK) ==
                  PA_SUBSCRIPTION_EVENT_REMOVE &&
              self->active && index == self->selectedIndex)
            self->markError("Das gewählte Mikrofon wurde getrennt.");
          self->querySources();
        } else if (facility == PA_SUBSCRIPTION_EVENT_SERVER)
          self->queryDefault();
      },
      this);
  if (pa_context_connect(context, nullptr, PA_CONTEXT_NOAUTOSPAWN, nullptr) < 0)
    markError("Der lokale Audiodienst ist nicht verfügbar.");
}
void AudioInput::disconnectServer() {
  if (context) {
    pa_context_set_state_callback(context, nullptr, nullptr);
    pa_context_set_subscribe_callback(context, nullptr, nullptr);
    pa_context_disconnect(context);
    pa_context_unref(context);
    context = nullptr;
  }
  if (loop) {
    pa_mainloop_free(loop);
    loop = nullptr;
  }
  ready = false;
  enumerated = false;
  listing = false;
  refreshAgain = false;
  catalog.clear();
  incoming.clear();
  defaultSource.clear();
  catalogDirty = true;
}
void AudioInput::querySources() {
  if (!ready)
    return;
  if (listing) {
    refreshAgain = true;
    return;
  }
  listing = true;
  incoming.clear();
  auto operation = pa_context_get_source_info_list(
      context,
      [](pa_context *, const pa_source_info *info, int end, void *data) {
        auto self = static_cast<AudioInput *>(data);
        if (end) {
          self->listing = false;
          if (end < 0) {
            self->markError("Audio-Geräteliste konnte nicht gelesen werden.");
            return;
          }
          self->catalog = self->incoming;
          self->enumerated = true;
          self->catalogDirty = true;
          if (self->active && !self->catalog.contains(self->selectedSource))
            self->markError("Das gewählte Mikrofon wurde getrennt.");
          if (self->refreshAgain) {
            self->refreshAgain = false;
            self->querySources();
          }
        } else if (info && info->name &&
                   info->monitor_of_sink == PA_INVALID_INDEX) {
          self->incoming[QByteArray(info->name)] = {
              QString::fromUtf8(info->description ? info->description
                                                  : info->name),
              info->index};
        }
      },
      this);
  if (operation)
    pa_operation_unref(operation);
  else {
    listing = false;
    markError("Audio-Geräteliste konnte nicht gelesen werden.");
  }
}
void AudioInput::queryDefault() {
  if (!ready)
    return;
  auto operation = pa_context_get_server_info(
      context,
      [](pa_context *, const pa_server_info *info, void *data) {
        auto self = static_cast<AudioInput *>(data);
        if (!info) {
          self->markError("Der lokale Audiodienst ist nicht verfügbar.");
          return;
        }
        const QByteArray name(
            info->default_source_name ? info->default_source_name : "");
        if (self->active && self->systemDefault && name != self->selectedSource)
          self->markError(
              "Das Standardmikrofon wurde während der Aufnahme geändert.");
        self->defaultSource = name;
        self->catalogDirty = true;
      },
      this);
  if (operation)
    pa_operation_unref(operation);
}
void AudioInput::start(QString uid) {
  if (active) {
    fail("Eine Mikrofonaufnahme läuft bereits.");
    return;
  }
  if (!available(uid)) {
    fail("Das gespeicherte Mikrofon ist nicht verfügbar.");
    return;
  }
  selectedSource = sourceName(uid);
  selectedIndex = catalog[selectedSource].index;
  systemDefault = uid.isEmpty();
  pa_sample_spec spec{PA_SAMPLE_FLOAT32LE, 16000, 1};
  stream = pa_stream_new(context, "Stille Post dictation", &spec, nullptr);
  if (!stream) {
    fail("Mikrofon konnte nicht geöffnet werden.");
    return;
  }
  active = true;
  pa_stream_set_state_callback(
      stream,
      [](pa_stream *stream, void *data) {
        auto self = static_cast<AudioInput *>(data);
        if (self->active &&
            (pa_stream_get_state(stream) == PA_STREAM_FAILED ||
             pa_stream_get_state(stream) == PA_STREAM_TERMINATED))
          self->markError("Die Mikrofonaufnahme wurde unterbrochen.");
      },
      this);
  pa_buffer_attr buffer{65536, uint32_t(-1), uint32_t(-1), uint32_t(-1), 4096};
  // Qt 6.4 erlaubt eine automatische Umleitung nach Geräteverlust. Der native
  // Stream darf ausdrücklich nie auf ein anderes Mikrofon verschoben werden.
  const auto flags = pa_stream_flags_t(
      PA_STREAM_DONT_MOVE | PA_STREAM_ADJUST_LATENCY |
      PA_STREAM_AUTO_TIMING_UPDATE | PA_STREAM_INTERPOLATE_TIMING);
  if (pa_stream_connect_record(stream, selectedSource.constData(), &buffer,
                               flags) < 0) {
    fail("Mikrofon konnte nicht geöffnet werden.");
    return;
  }
  pump.setInterval(10);
}
void AudioInput::consume() {
  for (int block = 0; active && stream && block < 32 &&
                      pa_stream_get_state(stream) == PA_STREAM_READY;
       ++block) {
    const void *data = nullptr;
    size_t size = 0;
    if (pa_stream_peek(stream, &data, &size) < 0) {
      fail("Mikrofondaten konnten nicht gelesen werden.");
      return;
    }
    if (!size)
      break;
    if (size > 1048576 || size % sizeof(float)) {
      fail("Ungültige Audiosamples vom Mikrofon.");
      return;
    }
    QByteArray samples(
        data ? QByteArray(static_cast<const char *>(data), int(size))
             : QByteArray(int(size), '\0'));
    pa_stream_drop(stream);
    double sum = 0;
    for (int offset = 0; offset < samples.size(); offset += sizeof(float)) {
      float value;
      memcpy(&value, samples.constData() + offset, sizeof(value));
      if (!std::isfinite(value)) {
        fail("Ungültige Audiosamples vom Mikrofon.");
        return;
      }
      sum += double(value) * value;
    }
    emit level(
        20 * std::log10(qMax(1e-12, std::sqrt(sum / (size / sizeof(float))))));
    for (int offset = 0; active && offset < samples.size(); offset += 65536)
      emit this->samples(samples.mid(offset, 65536));
  }
}
void AudioInput::tick() {
  if (!context) {
    if (clock.elapsed() >= reconnectAt) {
      connectServer();
      pump.setInterval(10);
    }
    return;
  }
  for (int step = 0; loop && step < 16; ++step) {
    int result = 0;
    if (pa_mainloop_iterate(loop, 0, &result) <= 0)
      break;
  }
  const auto state = pa_context_get_state(context);
  const bool disconnected = state == PA_CONTEXT_FAILED ||
                            state == PA_CONTEXT_TERMINATED ||
                            (!ready && clock.elapsed() >= connectionDeadline);
  if (disconnected)
    markError("Der lokale Audiodienst ist nicht verfügbar.");
  if (!pendingError.isEmpty()) {
    const auto message = pendingError;
    pendingError.clear();
    if (active)
      fail(message);
  }
  if (disconnected) {
    stop(false);
    disconnectServer();
    reconnectAt = clock.elapsed() + 1000;
  }
  if (catalogDirty) {
    catalogDirty = false;
    if (qEnvironmentVariableIsSet("STILLEPOST_AUDIO_TRACE"))
      qInfo() << "Audio device catalog changed" << active << catalog.size();
    emit devicesChanged(devices());
  }
  consume();
  pump.setInterval(active || !ready ? 10 : 50);
}
void AudioInput::stop(bool flush) {
  if (active && flush)
    consume();
  active = false;
  if (stream) {
    pa_stream_set_state_callback(stream, nullptr, nullptr);
    pa_stream_disconnect(stream);
    pa_stream_unref(stream);
    stream = nullptr;
  }
  pendingError.clear();
  emit level(-120);
}
void AudioInput::fail(QString message) {
  stop(false);
  if (qEnvironmentVariableIsSet("STILLEPOST_AUDIO_TRACE"))
    qInfo() << "Audio capture interrupted";
  emit failed(message);
}
