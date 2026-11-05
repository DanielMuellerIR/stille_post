#include "desktop_placement.h"
#include <cmath>
namespace {
const QString endpoint = "/io/github/danielmuellerir/stillepost/placement";
QDBusMessage managerCall(QString method, QVariantList arguments) {
  auto call = QDBusMessage::createMethodCall("org.kde.KWin", "/Scripting",
                                             "org.kde.kwin.Scripting", method);
  call.setArguments(arguments);
  return call;
}
} // namespace
DesktopPlacement::DesktopPlacement(QObject *parent)
    : QObject(parent), bus(QDBusConnection::sessionBus()),
      script(QDir::tempPath() + "/stillepost-placement-XXXXXX.js") {
  registered = bus.registerObject(endpoint, this,
                                  QDBusConnection::ExportScriptableSlots);
  timeout.setSingleShot(true);
  timeout.setInterval(1500);
  connect(&timeout, &QTimer::timeout, this, [this] { finish(false); });
}
DesktopPlacement::~DesktopPlacement() {
  finish(true);
  if (registered)
    bus.unregisterObject(endpoint);
}
void DesktopPlacement::request() {
  if (!token.isEmpty())
    return;
  if (!registered || !bus.interface()) {
    emit failed();
    return;
  }
  owner = bus.interface()->serviceOwner("org.kde.KWin").value();
  if (owner.isEmpty() || (!script.isOpen() && !script.open())) {
    emit failed();
    return;
  }
  token = QUuid::createUuid().toString(QUuid::Id128);
  name = "stillepost-placement-" + token;
  const auto source =
      QString(
          "const p=workspace.cursorPos;"
          "const s=workspace.screens.find(s=>{const r=s.geometry;return "
          "p.x>=r.x&&p.x<r.x+r.width&&p.y>=r.y&&p.y<r.y+r.height;})||workspace."
          "activeScreen;"
          "const "
          "a=workspace.clientArea(KWin.WorkArea,s,workspace.currentDesktop);"
          "callDBus('%1','%2','io.github.danielmuellerir.stillepost.Placement',"
          "'report','%3',JSON.stringify([p.x,p.y,a.x,a.y,a.width,a.height]));")
          .arg(bus.baseService(), endpoint, token)
          .toUtf8();
  script.resize(0);
  script.seek(0);
  script.write(source);
  script.flush();
  const auto epoch = token;
  auto pending = new QDBusPendingCallWatcher(
      bus.asyncCall(managerCall("loadScript", {script.fileName(), name}), 1000),
      this);
  connect(pending, &QDBusPendingCallWatcher::finished, this,
          [this, pending, epoch] {
            QDBusPendingReply<int> reply = *pending;
            pending->deleteLater();
            if (token != epoch)
              return;
            if (reply.isError() || reply.value() < 0) {
              finish(false);
              return;
            }
            auto call = QDBusMessage::createMethodCall(
                "org.kde.KWin",
                "/Scripting/Script" + QString::number(reply.value()),
                "org.kde.kwin.Script", "run");
            bus.asyncCall(call, 1000);
          });
  timeout.start();
}
void DesktopPlacement::report(QString receivedToken, QString coordinates) {
  if (token.isEmpty() || receivedToken != token || !calledFromDBus() ||
      message().service() != owner)
    return;
  const auto values = QJsonDocument::fromJson(coordinates.toUtf8()).array();
  if (coordinates.size() > 256 || values.size() != 6) {
    finish(false);
    return;
  }
  for (auto value : values)
    if (!value.isDouble() || !std::isfinite(value.toDouble()) ||
        std::abs(value.toDouble()) > 1000000) {
      finish(false);
      return;
    }
  const QPoint cursor(qRound(values[0].toDouble()),
                      qRound(values[1].toDouble()));
  const QRect area(qRound(values[2].toDouble()), qRound(values[3].toDouble()),
                   qRound(values[4].toDouble()), qRound(values[5].toDouble()));
  if (area.isEmpty()) {
    finish(false);
    return;
  }
  finish(true);
  emit ready(cursor, area);
}
void DesktopPlacement::finish(bool success) {
  const bool pending = !token.isEmpty();
  timeout.stop();
  if (!name.isEmpty())
    bus.asyncCall(managerCall("unloadScript", {name}), 1000);
  token.clear();
  name.clear();
  if (!success && pending)
    emit failed();
}
