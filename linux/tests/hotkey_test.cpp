#include "x11_hotkeys.h"
#include <QtTest>
#include <stdexcept>
namespace {
void check(bool value, const char *reason) {
  if (!value)
    throw std::runtime_error(reason);
}
void wait(std::function<bool()> condition) {
  QElapsedTimer timer;
  timer.start();
  while (!condition()) {
    check(timer.elapsed() < 2000, "Zeitlimit beim globalen X11-Tastenkürzel");
    QTest::qWait(10);
  }
}
void key(QString operation, QString chord) {
  check(QProcess::execute("xdotool", {operation, chord}) == 0,
        "Künstlicher Tastendruck fehlgeschlagen");
}
void run() {
  X11Shortcuts first, second;
  QSignalSpy pressed(&first, &X11Shortcuts::pressed);
  QSignalSpy released(&first, &X11Shortcuts::released);
  QSignalSpy status(&second, &X11Shortcuts::status);
  auto assertChord = [&](QString chord, QString action) {
    pressed.clear();
    released.clear();
    key("key", chord);
    wait([&] { return !pressed.isEmpty() && !released.isEmpty(); });
    check(pressed.size() == 1 && released.size() == 1 &&
              pressed[0][0].toString() == action &&
              released[0][0].toString() == action,
          "Druck/Loslassen liefert nicht genau die gebundene Aktion");
  };
  check(first.bind("CTRL+ALT+space", "CTRL+ALT+r"), "Erste Bindung scheitert");
  check(!second.bind("CTRL+ALT+space", "CTRL+ALT+r"),
        "Konkurrierende Bindung wurde akzeptiert");
  check(!status.isEmpty() && !status.last()[1].toBool() &&
            !status.last()[0].toString().isEmpty(),
        "Tastenkonflikt wird nicht gemeldet");
  assertChord("ctrl+alt+space", "dictate");
  assertChord("ctrl+alt+r", "recall");
  qInfo() << "PASS global-conflict-preserves-owner";
  key("key", "Caps_Lock");
  key("key", "Num_Lock");
  assertChord("ctrl+alt+space", "dictate");
  key("key", "Caps_Lock");
  key("key", "Num_Lock");
  qInfo() << "PASS caps-and-num-lock";
  check(first.bind("CTRL+ALT+space", "CTRL+ALT+SHIFT+space"),
        "Bindung mit gemeinsamem Grundzeichen scheitert");
  assertChord("ctrl+alt+space", "dictate");
  assertChord("ctrl+alt+shift+space", "recall");
  qInfo() << "PASS shared-key-distinct-actions";
  pressed.clear();
  released.clear();
  key("keydown", "ctrl+alt+space");
  wait([&] { return pressed.size() == 1; });
  key("keydown", "space");
  QTest::qWait(100);
  check(pressed.size() == 1, "Wiederholung startet eine zweite Aktion");
  check(first.bind("CTRL+ALT+space", "CTRL+ALT+SHIFT+space"),
        "Erneutes Binden scheitert");
  pressed.clear();
  released.clear();
  key("keyup", "ctrl+alt+space");
  QTest::qWait(100);
  check(pressed.isEmpty() && released.isEmpty(),
        "Gehaltene Taste erzeugt nach erneutem Binden eine Aktion");
  assertChord("ctrl+alt+space", "dictate");
  qInfo() << "PASS repeat-and-rebind-while-held";
  first.suspend();
  check(second.bind("CTRL+ALT+space", "CTRL+ALT+r"),
        "Freigegebene Tastenkürzel bleiben belegt");
  qInfo() << "PASS shortcut-release";
}
} // namespace
int main(int argc, char **argv) {
  if (qEnvironmentVariable("STILLEPOST_TEST_ISOLATED_X11") != "1") {
    qCritical() << "Nur in einem eigenen X11-Testdisplay ausführen.";
    return 2;
  }
  QApplication app(argc, argv);
  try {
    run();
    return 0;
  } catch (const std::exception &error) {
    qCritical() << error.what();
    return 1;
  }
}
