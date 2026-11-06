#include <LayerShellQt/Window>
#include <QCoreApplication>
#include <QDir>
#include <QPluginLoader>
#include <QWindow>
#include <QtWaylandClient/private/qwaylanddisplay_p.h>
#include <QtWaylandClient/private/qwaylandshellintegrationplugin_p.h>
#include <QtWaylandClient/private/qwaylandwindow_p.h>
#include <memory>
#include <qwaylandlayershellintegration_p.h>
using namespace QtWaylandClient;
namespace {
// Qt 6.4 überträgt das Fokusverbot nicht über XDG. Nur automatische
// Anzeigen nutzen Layer Shell; reguläre Fenster behalten ihre XDG-Rolle.
class MixedShell final : public QWaylandShellIntegration {
public:
  bool initialize(QWaylandDisplay *display) override {
    for (const auto &path : QCoreApplication::libraryPaths()) {
      loader.setFileName(
          QDir(path).filePath("wayland-shell-integration/libxdg-shell.so"));
      auto factory =
          qobject_cast<QWaylandShellIntegrationPlugin *>(loader.instance());
      if (!factory)
        continue;
      normal.reset(factory->create("xdg-shell", {}));
      if (normal && normal->initialize(display)) {
        layersAvailable = layers.initialize(display);
        if (qEnvironmentVariableIsSet("STILLEPOST_WINDOW_TRACE"))
          qInfo() << "Shell integration" << layersAvailable;
        return true;
      }
      normal.reset();
      loader.unload();
    }
    return false;
  }
  QWaylandShellSurface *createShellSurface(QWaylandWindow *platform) override {
    auto window = platform->window();
    const bool layerPopup =
        window->transientParent() &&
        window->transientParent()
            ->property("_stillepostLayerSurface")
            .toBool() &&
        (window->type() == Qt::Popup || window->type() == Qt::ToolTip);
    const bool useLayer =
        layersAvailable &&
        (window->flags().testFlag(Qt::WindowDoesNotAcceptFocus) || layerPopup);
    window->setProperty("_stillepostLayerSurface", useLayer);
    if (qEnvironmentVariableIsSet("STILLEPOST_WINDOW_TRACE"))
      qInfo() << "Window surface" << window->type()
              << window->flags().testFlag(Qt::WindowDoesNotAcceptFocus)
              << useLayer;
    if (!useLayer)
      return normal->createShellSurface(platform);
    auto interface = LayerShellQt::Window::get(window);
    interface->setLayer(LayerShellQt::Window::LayerOverlay);
    interface->setExclusiveZone(0);
    interface->setDesiredOutput(window->screen());
    const bool overlay = window->type() == Qt::Tool &&
                         window->title() == QStringLiteral("Stille Post");
    interface->setScope(overlay ? "stillepost-overlay" : "stillepost-preview");
    interface->setAnchors(
        overlay || layerPopup
            ? LayerShellQt::Window::Anchors(LayerShellQt::Window::AnchorTop) |
                  LayerShellQt::Window::AnchorLeft
            : LayerShellQt::Window::Anchors{});
    interface->setKeyboardInteractivity(
        overlay || window->type() == Qt::ToolTip
            ? LayerShellQt::Window::KeyboardInteractivityNone
        : window->type() == Qt::Popup
            ? LayerShellQt::Window::KeyboardInteractivityExclusive
            : LayerShellQt::Window::KeyboardInteractivityNone);
    return layers.createShellSurface(platform);
  }
  void *nativeResourceForWindow(const QByteArray &name,
                                QWindow *window) override {
    return window->property("_stillepostLayerSurface").toBool()
               ? layers.nativeResourceForWindow(name, window)
               : normal->nativeResourceForWindow(name, window);
  }

private:
  QPluginLoader loader;
  std::unique_ptr<QWaylandShellIntegration> normal;
  LayerShellQt::QWaylandLayerShellIntegration layers;
  bool layersAvailable = false;
};
class ShellPlugin final : public QWaylandShellIntegrationPlugin {
  Q_OBJECT
  Q_PLUGIN_METADATA(IID QWaylandShellIntegrationFactoryInterface_iid FILE
                    "wayland_shell.json")
public:
  QWaylandShellIntegration *create(const QString &,
                                   const QStringList &) override {
    return new MixedShell;
  }
};
} // namespace
#include "wayland_shell.moc"
