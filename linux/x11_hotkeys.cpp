#include "x11_hotkeys.h"
#include <X11/XKBlib.h>
#include <X11/keysym.h>
namespace {
int grabError = 0;
int errorHandler(Display *, XErrorEvent *error) {
  grabError = error->error_code;
  return 0;
}
} // namespace
X11Shortcuts::X11Shortcuts(QObject *parent) : QObject(parent) {
  display = XOpenDisplay(nullptr);
  if (display) {
    int supported = 0;
    XkbSetDetectableAutoRepeat(display, True, &supported);
  }
  timer.setInterval(10);
  connect(&timer, &QTimer::timeout, this, &X11Shortcuts::poll);
  timer.start();
}
X11Shortcuts::~X11Shortcuts() {
  suspend();
  if (display)
    XCloseDisplay(display);
}
void X11Shortcuts::suspend() {
  if (display) {
    XUngrabKey(display, AnyKey, AnyModifier, DefaultRootWindow(display));
    XSync(display, False);
  }
  actions.clear();
  down.clear();
  heldBeforeBinding.clear();
  ready = false;
}
bool X11Shortcuts::bind(QString dictate, QString recall) {
  suspend();
  if (!display) {
    emit status("X11-Verbindung ist nicht verfügbar.", false);
    return false;
  }
  XSync(display, False);
  grabError = 0;
  auto previous = XSetErrorHandler(errorHandler);
  for (auto pair : QList<QPair<QString, QString>>{{dictate, "dictate"},
                                                  {recall, "recall"}}) {
    if (pair.first.isEmpty())
      continue;
    auto parts = pair.first.split('+');
    const auto key = parts.takeLast();
    unsigned modifiers = 0;
    for (auto modifier : parts) {
      if (modifier == "CTRL")
        modifiers |= ControlMask;
      else if (modifier == "ALT")
        modifiers |= Mod1Mask;
      else if (modifier == "SHIFT")
        modifiers |= ShiftMask;
      else if (modifier == "LOGO")
        modifiers |= Mod4Mask;
      else {
        grabError = BadValue;
        break;
      }
    }
    if (!(modifiers & (ControlMask | Mod1Mask | Mod4Mask))) {
      grabError = BadValue;
      break;
    }
    const auto symbol = XStringToKeysym(key.toLatin1().constData());
    const auto code = XKeysymToKeycode(display, symbol);
    if (!code) {
      grabError = BadValue;
      break;
    }
    for (unsigned extra : {0u, unsigned(LockMask), unsigned(Mod2Mask),
                           unsigned(LockMask | Mod2Mask)})
      XGrabKey(display, code, modifiers | extra, DefaultRootWindow(display),
               False, GrabModeAsync, GrabModeAsync);
    actions[(modifiers << 8) | code] = pair.second;
  }
  XSync(display, False);
  XSetErrorHandler(previous);
  if (grabError) {
    suspend();
    emit status("Tastenkürzel ist ungültig oder wird bereits von einer anderen "
                "Anwendung verwendet.",
                false);
    return false;
  }
  char keys[32];
  XQueryKeymap(display, keys);
  for (unsigned key = 0; key < 256; ++key)
    if (keys[key / 8] & (1 << (key % 8)))
      heldBeforeBinding.insert(key);
  ready = true;
  emit status("Globale Tastenkürzel aktiv: " + dictate + " · " + recall, true);
  return true;
}
void X11Shortcuts::poll() {
  if (!display)
    return;
  while (XPending(display)) {
    XEvent event;
    XNextEvent(display, &event);
    if (qEnvironmentVariableIsSet("STILLEPOST_HOTKEY_TRACE"))
      qInfo() << "X11 shortcut event" << event.type << event.xkey.keycode
              << event.xkey.state;
    if (event.type == KeyPress) {
      const auto key = event.xkey.keycode;
      const auto index =
          ((event.xkey.state & ~(LockMask | Mod2Mask)) << 8) | key;
      const auto id = actions.value(index);
      if (!id.isEmpty() && !down.contains(key) &&
          !heldBeforeBinding.contains(key)) {
        down.insert(key, id);
        emit pressed(id);
      }
    } else if (event.type == KeyRelease) {
      const auto key = event.xkey.keycode;
      heldBeforeBinding.remove(key);
      if (!down.contains(key))
        continue;
      if (XPending(display)) {
        XEvent next;
        XPeekEvent(display, &next);
        if (next.type == KeyPress && next.xkey.time == event.xkey.time &&
            next.xkey.keycode == key)
          continue;
      }
      emit released(down.take(key));
    }
  }
}
