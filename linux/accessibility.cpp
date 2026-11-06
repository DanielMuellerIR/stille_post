#include "accessibility.h"
#include <QtCore>
#include <atspi/atspi.h>
#include <optional>
#include <unistd.h>
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/keysym.h>
#include <X11/extensions/XTest.h>
namespace {
struct InsertionOutcome {
  bool success;
  QString reason;
  bool modified = false;
  bool needsClipboard = false;
};
struct Snapshot {
  AtspiAccessible *object = nullptr;
  QString path, application, fullText;
  int caret = 0, start = 0, end = 0;
  bool remote = false;
  bool invalidated = false;
  bool utf16 = false;
  bool clipboardPaste = false;
};
QString utf(gchar *value) {
  QString result = QString::fromUtf8(value ? value : "");
  g_free(value);
  return result;
}
QSharedPointer<AtspiAccessible> textObject(AtspiAccessible *object, bool chromium) {
  auto owned = [](AtspiAccessible *value) {
    return QSharedPointer<AtspiAccessible>(value, [](AtspiAccessible *p) {
      if (p)
        g_object_unref(p);
    });
  };
  if (chromium) {
    auto text = atspi_accessible_get_text_iface(object);
    if (!text)
      return {};
    const int count = atspi_text_get_character_count(text, nullptr);
    if (count < 0 || count > 250000)
      return {};
    const auto value = utf(atspi_text_get_text(text, 0, count, nullptr));
    // Chromium stellt den Absatz im Textfeld als eingebettetes Objekt dar.
    // Nur ein eindeutig lesbarer Absatz erlaubt überprüfbare Textpositionen.
    if (value.contains(QChar(0xfffc))) {
      if (atspi_accessible_get_child_count(object, nullptr) != 1)
        return {};
      auto child = owned(atspi_accessible_get_child_at_index(object, 0, nullptr));
      if (!child || atspi_accessible_get_role(child.data(), nullptr) !=
                        ATSPI_ROLE_PARAGRAPH)
        return {};
      return child;
    }
  }
  return owned(static_cast<AtspiAccessible *>(g_object_ref(object)));
}
QString readText(AtspiText *text, int count, bool chromium, GError **error) {
  auto value = utf(atspi_text_get_text(text, 0, count, error));
  if (chromium && value == QString(QChar(0xfffc)) + "\n") {
    auto object = ATSPI_ACCESSIBLE(text);
    auto attributes = atspi_accessible_get_attributes(object, nullptr);
    const auto classes = attributes
                             ? QString::fromUtf8(static_cast<const char *>(
                                   g_hash_table_lookup(attributes, "class")))
                             : QString();
    if (attributes)
      g_hash_table_unref(attributes);
    if (classes.split(' ').contains("placeholder") &&
        atspi_accessible_get_child_count(object, nullptr) == 2) {
      auto before = atspi_accessible_get_child_at_index(object, 0, nullptr);
      auto pseudo =
          before ? atspi_accessible_get_attributes(before, nullptr) : nullptr;
      const auto tag = pseudo ? static_cast<const char *>(
                                    g_hash_table_lookup(pseudo, "tag"))
                              : nullptr;
      // ::before ist sichtbarer Platzhalter, kein Inhalt des Editors.
      if (tag && QByteArray(tag) == "::before")
        value.clear();
      if (pseudo)
        g_hash_table_unref(pseudo);
      if (before)
        g_object_unref(before);
    }
  }
  if (chromium && value == "\n" &&
      atspi_text_get_caret_offset(text, nullptr) == 0 &&
      atspi_text_get_n_selections(text, nullptr) == 0)
    value.clear();
  return value;
}
QString identity(AtspiAccessible *object) {
  auto base = ATSPI_OBJECT(object);
  return QString::fromUtf8(base->app->bus_name) + QString::fromUtf8(base->path);
}
bool has(AtspiAccessible *object, AtspiStateType flag) {
  auto states = atspi_accessible_get_state_set(object);
  if (!states)
    return false;
  const bool value = atspi_state_set_contains(states, flag);
  g_object_unref(states);
  return value;
}
QString application(AtspiAccessible *object) {
  const auto pid = atspi_accessible_get_process_id(object, nullptr);
  const auto executable =
      QFileInfo(QString("/proc/%1/exe").arg(pid)).symLinkTarget();
  QString name = QFileInfo(executable).fileName().toLower();
  name.replace(QRegularExpression("[^a-z0-9-]"), "-");
  return name.isEmpty() ? QString() : "linux." + name;
}
bool pasteToProcess(unsigned pid) {
  Display *display = XOpenDisplay(nullptr);
  if (!display)
    return false;
  auto close = qScopeGuard([&] { XCloseDisplay(display); });
  Window window;
  int revert;
  XGetInputFocus(display, &window, &revert);
  const auto pidAtom = XInternAtom(display, "_NET_WM_PID", True);
  bool matchingWindow = false;
  for (int depth = 0; window != None && window != PointerRoot && depth < 32;
       depth++) {
    Atom actual;
    int format;
    unsigned long count, remaining;
    unsigned char *value = nullptr;
    if (pidAtom != None &&
        XGetWindowProperty(display, window, pidAtom, 0, 1, False, XA_CARDINAL,
                           &actual, &format, &count, &remaining, &value) == Success &&
        value) {
      matchingWindow = actual == XA_CARDINAL && format == 32 && count == 1 &&
                       *reinterpret_cast<unsigned long *>(value) == pid;
      XFree(value);
      if (matchingWindow)
        break;
    }
    Window root, parent, *children = nullptr;
    unsigned childCount;
    if (!XQueryTree(display, window, &root, &parent, &children, &childCount))
      break;
    if (children)
      XFree(children);
    window = parent;
  }
  if (!matchingWindow)
    return false;
  // Gehaltene Modifikatortasten gehören dem Benutzer und werden nicht gelöst.
  char keys[32];
  XQueryKeymap(display, keys);
  for (auto symbol : {XK_Control_L, XK_Control_R, XK_Shift_L, XK_Shift_R,
                      XK_Alt_L, XK_Alt_R, XK_Super_L, XK_Super_R}) {
    const auto key = XKeysymToKeycode(display, symbol);
    if (key && (keys[key / 8] & (1 << (key % 8))))
      return false;
  }
  const auto control = XKeysymToKeycode(display, XK_Control_L);
  const auto paste = XKeysymToKeycode(display, XK_v);
  int event, error, major, minor;
  if (!control || !paste ||
      !XTestQueryExtension(display, &event, &error, &major, &minor))
    return false;
  XTestFakeKeyEvent(display, control, True, CurrentTime);
  XTestFakeKeyEvent(display, paste, True, CurrentTime);
  XTestFakeKeyEvent(display, paste, False, CurrentTime);
  XTestFakeKeyEvent(display, control, False, CurrentTime);
  XFlush(display);
  return true;
}
bool activeWindow(AtspiAccessible *object) {
  auto current = static_cast<AtspiAccessible *>(g_object_ref(object));
  for (int depth = 0; current && depth < 128; depth++) {
    atspi_accessible_clear_cache(current);
    const auto role = atspi_accessible_get_role(current, nullptr);
    auto parent = atspi_accessible_get_parent(current, nullptr);
    const bool topLevel =
        parent &&
        atspi_accessible_get_role(parent, nullptr) == ATSPI_ROLE_APPLICATION;
    const bool active =
        (role == ATSPI_ROLE_FRAME || role == ATSPI_ROLE_WINDOW ||
         role == ATSPI_ROLE_DIALOG || topLevel) &&
        has(current, ATSPI_STATE_ACTIVE);
    g_object_unref(current);
    if (active) {
      if (parent)
        g_object_unref(parent);
      return true;
    }
    current = parent;
  }
  if (current)
    g_object_unref(current);
  return false;
}
bool secure(AtspiAccessible *object) {
  if (atspi_accessible_get_role(object, nullptr) == ATSPI_ROLE_PASSWORD_TEXT)
    return true;
  auto attributes = atspi_accessible_get_attributes(object, nullptr);
  bool protectedField = false;
  if (attributes) {
    for (auto key : {"text-input-type", "input-type", "type"}) {
      auto value =
          static_cast<const char *>(g_hash_table_lookup(attributes, key));
      if (value && QString::fromUtf8(value).compare("password",
                                                    Qt::CaseInsensitive) == 0)
        protectedField = true;
    }
    g_hash_table_unref(attributes);
  }
  return protectedField;
}
AtspiAccessible *focused(AtspiAccessible *root, int &budget,
                         QElapsedTimer &clock) {
  if (!root || --budget < 0 || clock.elapsed() > 900)
    return nullptr;
  atspi_accessible_clear_cache(root);
  // Chromium aktiviert seinen Textbaum erst bei einer echten ATK-Abfrage.
  const auto role = atspi_accessible_get_role(root, nullptr);
  if ((role == ATSPI_ROLE_FRAME || role == ATSPI_ROLE_WINDOW ||
       role == ATSPI_ROLE_DIALOG) && !has(root, ATSPI_STATE_ACTIVE)) {
    auto parent = atspi_accessible_get_parent(root, nullptr);
    const bool topLevel =
        parent && atspi_accessible_get_role(parent, nullptr) ==
                      ATSPI_ROLE_APPLICATION;
    if (parent)
      g_object_unref(parent);
    if (topLevel)
      return nullptr;
  }
  if (role == ATSPI_ROLE_FRAME || role == ATSPI_ROLE_APPLICATION) {
    auto attributes = atspi_accessible_get_attributes(root, nullptr);
    if (attributes)
      g_hash_table_unref(attributes);
  }
  if (qEnvironmentVariableIsSet("STILLEPOST_ACCESSIBILITY_TRACE"))
    qInfo() << "accessible state" << atspi_accessible_get_role(root, nullptr)
            << has(root, ATSPI_STATE_FOCUSED) << has(root, ATSPI_STATE_ACTIVE)
            << atspi_accessible_get_child_count(root, nullptr);
  if (has(root, ATSPI_STATE_FOCUSED) && activeWindow(root))
    return static_cast<AtspiAccessible *>(g_object_ref(root));
  if (has(root, ATSPI_STATE_DEFUNCT))
    return nullptr;
  int count = qMin(300, atspi_accessible_get_child_count(root, nullptr));
  for (int i = 0; i < count; ++i) {
    auto child = atspi_accessible_get_child_at_index(root, i, nullptr);
    auto result = focused(child, budget, clock);
    if (child)
      g_object_unref(child);
    if (result)
      return result;
    if (clock.elapsed() > 900 || budget <= 0)
      break;
  }
  return nullptr;
}
class TargetAgent : public QObject {
public:
  std::function<void(QString)> onApplication;
  QHash<QString, Snapshot> snapshots;
  QQueue<QString> snapshotOrder;
  AtspiEventListener *listener = nullptr;
  AtspiAccessible *lastFocused = nullptr;
  bool initialized = false;
  ~TargetAgent() override {
    for (auto value : snapshots)
      if (value.object)
        g_object_unref(value.object);
    if (lastFocused)
      g_object_unref(lastFocused);
    if (listener) {
      atspi_event_listener_deregister(listener, "object:state-changed:focused",
                                      nullptr);
      g_object_unref(listener);
    }
  }
  void initialize() {
    initialized = atspi_init() == 0;
    atspi_set_timeout(200, 1000);
    if (!initialized)
      return;
    listener = atspi_event_listener_new(
        [](AtspiEvent *event, void *data) {
          auto self = static_cast<TargetAgent *>(data);
          if (event->detail1 && event->source) {
            auto source = QSharedPointer<AtspiAccessible>(
                static_cast<AtspiAccessible *>(g_object_ref(event->source)),
                [](AtspiAccessible *value) { g_object_unref(value); });
            QMetaObject::invokeMethod(
                self,
                [self, source] {
                  if (self->lastFocused)
                    g_object_unref(self->lastFocused);
                  self->lastFocused = static_cast<AtspiAccessible *>(
                      g_object_ref(source.data()));
                  const auto app = application(source.data());
                  const bool active = activeWindow(source.data());
                  if (qEnvironmentVariableIsSet("STILLEPOST_INSERTION_TRACE") &&
                      !self->snapshots.isEmpty())
                    qInfo() << "Insertion focus" << app << active;
                  if (!app.isEmpty() && active && app != "linux.stillepost" &&
                      self->onApplication)
                    self->onApplication(app);
                  for (auto it = self->snapshots.begin();
                       it != self->snapshots.end(); ++it) {
                    if (!app.isEmpty() && active && app != "linux.stillepost" &&
                        app != it->application)
                      it->invalidated = true;
                  }
                },
                Qt::QueuedConnection);
          }
          g_boxed_free(ATSPI_TYPE_EVENT, event);
        },
        this, nullptr);
    atspi_event_listener_register(listener, "object:state-changed:focused",
                                  nullptr);
  }
  AtspiAccessible *current() {
    if (lastFocused) {
      atspi_accessible_clear_cache(lastFocused);
      if (has(lastFocused, ATSPI_STATE_FOCUSED) && activeWindow(lastFocused))
        return static_cast<AtspiAccessible *>(g_object_ref(lastFocused));
    }
    auto desktop = atspi_get_desktop(0);
    int budget = 1800;
    QElapsedTimer clock;
    clock.start();
    auto result = focused(desktop, budget, clock);
    if (desktop)
      g_object_unref(desktop);
    return result;
  }
  QJsonObject capture(QString request, bool selection) {
    QJsonObject result{{"request", request},
                       {"available", initialized},
                       {"token", ""},
                       {"application", ""}};
    if (!initialized) {
      result["reason"] = "Bedienungshilfen-Dienst nicht verfügbar.";
      return result;
    }
    auto object = current();
    if (!object) {
      result["reason"] = "Eingabeziel stellt kein fokussiertes Feld bereit.";
      return result;
    }
    auto app = application(object);
    result["application"] = app;
    bool remote = false;
    for (auto name : {"remmina", "krdc", "vncviewer", "virt-viewer", "rustdesk",
                      "anydesk", "nxplayer"})
      if (app.contains(name))
        remote = true;
    if (secure(object)) {
      g_object_unref(object);
      result["reason"] = "Geschütztes Eingabefeld — kein Zugriff.";
      return result;
    }
    auto editable = atspi_accessible_get_editable_text_iface(object);
    auto applicationRoot = atspi_accessible_get_application(object, nullptr);
    const auto toolkit =
        applicationRoot
            ? utf(atspi_accessible_get_toolkit_name(applicationRoot, nullptr))
            : QString();
    if (applicationRoot)
      g_object_unref(applicationRoot);
    const bool qt = toolkit.startsWith("Qt", Qt::CaseInsensitive);
    const bool clipboardPaste =
        !editable && toolkit.startsWith("Chromium", Qt::CaseInsensitive) &&
        has(object, ATSPI_STATE_EDITABLE) && !remote;
    auto content = textObject(object, clipboardPaste);
    auto text = content ? atspi_accessible_get_text_iface(content.data()) : nullptr;
    if (!text) {
      g_object_unref(object);
      result["reason"] = "Das Eingabeziel unterstützt keinen Textzugriff.";
      return result;
    }
    int count = atspi_text_get_character_count(text, nullptr);
    if (count < 0 || count > 250000) {
      g_object_unref(object);
      result["reason"] = "Eingabeziel ist für die sichere Zielprüfung zu groß.";
      return result;
    }
    GError *error = nullptr;
    const auto contents = readText(text, count, clipboardPaste, &error);
    if (clipboardPaste && contents.isEmpty())
      count = 0;
    if (error) {
      g_error_free(error);
      g_object_unref(object);
      result["reason"] = "Eingabeziel nicht lesbar.";
      return result;
    }
    const auto points = contents.toUcs4();
    // Qt zählt AT-SPI-Positionen und InsertText-Längen in UTF-16-Einheiten.
    // Andere Adapter erwarten für InsertText die dokumentierte UTF-8-Bytelänge.
    const bool utf16 =
        qt || (points.size() != count && contents.size() == count);
    if ((clipboardPaste && contents.contains(QChar(0xfffc))) ||
        contents.toUtf8().size() > 1048576 ||
        (utf16 ? contents.size() != count : points.size() != count)) {
      g_object_unref(object);
      result["reason"] = "Ungültiger Textzugriff.";
      return result;
    }
    const int caret = clipboardPaste && contents.isEmpty()
                          ? 0 : atspi_text_get_caret_offset(text, nullptr);
    int begin = caret, end = caret;
    const int selections = atspi_text_get_n_selections(text, nullptr);
    if (selections < 0 || selections > 1) {
      g_object_unref(object);
      result["reason"] = "Mehrfachauswahl wird nicht unterstützt.";
      return result;
    }
    if (selections == 1) {
      auto range = atspi_text_get_selection(text, 0, nullptr);
      if (range) {
        begin = range->start_offset;
        end = range->end_offset;
        g_boxed_free(ATSPI_TYPE_RANGE, range);
      }
    }
    auto boundary = [&](int offset) {
      return offset >= 0 && offset <= count &&
             (!utf16 || offset == 0 || offset == contents.size() ||
              !contents[offset].isLowSurrogate() ||
              !contents[offset - 1].isHighSurrogate());
    };
    if (begin < 0 || end < begin || end > count || !boundary(begin) ||
        !boundary(end) || !boundary(caret)) {
      g_object_unref(object);
      result["reason"] = "Auswahl ist nicht eindeutig.";
      return result;
    }
    if (selection) {
      auto selected =
          utf16 ? contents.mid(begin, end - begin)
                : QString::fromUcs4(points.constData() + begin, end - begin);
      if (selected.isEmpty() || selected.toUtf8().size() > 8192) {
        g_object_unref(object);
        result["reason"] =
            "Keine unterstützte Textauswahl (höchstens 8192 UTF-8-Bytes).";
        return result;
      }
      result["selection"] = selected;
    }
    const auto token = QUuid::createUuid().toString(QUuid::WithoutBraces);
    while (snapshotOrder.size() >= 16) {
      auto oldest = snapshots.take(snapshotOrder.dequeue());
      if (oldest.object)
        g_object_unref(oldest.object);
    }
    snapshotOrder.enqueue(token);
    snapshots[token] = {object, identity(object), app,   contents, caret, begin,
                        end,    remote,           false, utf16, clipboardPaste};
    result["token"] = token;
    result["editable"] = (editable || clipboardPaste) &&
                         has(object, ATSPI_STATE_EDITABLE) &&
                         !has(object, ATSPI_STATE_READ_ONLY) && !remote;
    result["remote"] = remote;
    return result;
  }
  InsertionOutcome insert(QString token, QString replacement, bool restore,
                          bool clipboardReady) {
    auto found = snapshots.find(token);
    if (found == snapshots.end())
      return {false, "Das ursprüngliche Eingabeziel ist nicht mehr verfügbar."};
    auto &snapshot = *found;
    if (snapshot.invalidated || snapshot.remote)
      return {false, "Eingabeziel gewechselt oder Remote-Viewer aktiv. Text "
                     "bleibt kopiert."};
    auto currentObject = current();
    bool same = currentObject && identity(currentObject) == snapshot.path;
    if (currentObject)
      g_object_unref(currentObject);
    if (!same && restore) {
      auto component = atspi_accessible_get_component_iface(snapshot.object);
      if (component)
        atspi_component_grab_focus(component, nullptr);
      atspi_accessible_clear_cache(snapshot.object);
      same = has(snapshot.object, ATSPI_STATE_FOCUSED) &&
             activeWindow(snapshot.object);
    }
    if (!same)
      return {false, "Das Eingabeziel hat sich geändert. Text bleibt kopiert."};
    atspi_accessible_clear_cache(snapshot.object);
    if (secure(snapshot.object) ||
        !has(snapshot.object, ATSPI_STATE_EDITABLE) ||
        has(snapshot.object, ATSPI_STATE_READ_ONLY))
      return {false, "Eingabeziel ist geschützt oder nicht bearbeitbar."};
    auto content = textObject(snapshot.object, snapshot.clipboardPaste);
    auto text = content ? atspi_accessible_get_text_iface(content.data()) : nullptr;
    auto editable = atspi_accessible_get_editable_text_iface(snapshot.object);
    if (!text || (!editable && !snapshot.clipboardPaste))
      return {false,
              "Sicheres Einfügen wird vom Eingabeziel nicht unterstützt."};
    const int count = atspi_text_get_character_count(text, nullptr);
    if (count < 0 || count > 250000)
      return {false, "Eingabeziel ist für die sichere Zielprüfung zu groß."};
    const auto fresh = readText(text, count, snapshot.clipboardPaste, nullptr);
    if (fresh.toUtf8().size() > 1048576)
      return {false, "Eingabeziel ist für die sichere Zielprüfung zu groß."};
    const auto caret = snapshot.clipboardPaste && fresh.isEmpty()
                           ? 0 : atspi_text_get_caret_offset(text, nullptr);
    int begin = caret, end = caret;
    const int selections = atspi_text_get_n_selections(text, nullptr);
    if (selections < 0 || selections > 1)
      return {false, "Auswahl ist nicht eindeutig."};
    if (selections == 1) {
      auto range = atspi_text_get_selection(text, 0, nullptr);
      if (range) {
        begin = range->start_offset;
        end = range->end_offset;
        g_boxed_free(ATSPI_TYPE_RANGE, range);
      }
    }
    if (fresh != snapshot.fullText || caret != snapshot.caret ||
        begin != snapshot.start || end != snapshot.end)
      return {
          false,
          "Text oder Auswahl wurde inzwischen geändert. Text bleibt kopiert."};
    const auto encoded = replacement.toUtf8();
    if (encoded.size() > 1048576 || replacement.contains(QChar(0)) ||
        QString::fromUtf8(encoded) != replacement)
      return {false,
              "Ergebnis ist für das sichere Einfügen ungültig oder zu groß."};
    const auto inserted = replacement.toUcs4();
    const int insertedCount =
        snapshot.utf16 ? replacement.size() : inserted.size();
    auto replace = [&](int start, int finish) {
      if (snapshot.utf16)
        return fresh.left(start) + replacement + fresh.mid(finish);
      const auto points = fresh.toUcs4();
      QList<uint> result;
      result.reserve(points.size() + inserted.size());
      for (int i = 0; i < start; i++)
        result.append(points[i]);
      for (auto point : inserted)
        result.append(point);
      for (int i = finish; i < points.size(); i++)
        result.append(points[i]);
      return QString::fromUcs4(result.constData(), result.size());
    };
    const auto afterInsertion = replace(begin, begin),
               finalText = replace(begin, end);
    if (afterInsertion.toUtf8().size() > 1048576 || insertedCount > 250000)
      return {false, "Ergebnis ist für das sichere Einfügen zu groß."};
    auto readCurrent = [&]() -> std::optional<QString> {
      auto currentContent = textObject(snapshot.object, snapshot.clipboardPaste);
      auto currentText = currentContent
                             ? atspi_accessible_get_text_iface(currentContent.data())
                             : nullptr;
      if (!currentText)
        return std::nullopt;
      const int size = atspi_text_get_character_count(currentText, nullptr);
      if (size < 0 || size > 500000)
        return std::nullopt;
      GError *error = nullptr;
      auto value = readText(currentText, size, snapshot.clipboardPaste, &error);
      if (error) {
        g_error_free(error);
        return std::nullopt;
      }
      if (value.toUtf8().size() > 1048576)
        return std::nullopt;
      return value;
    };
    auto sameTarget = [&] {
      auto object = current();
      const bool same = object && identity(object) == snapshot.path;
      if (object)
        g_object_unref(object);
      atspi_accessible_clear_cache(snapshot.object);
      return same && !has(snapshot.object, ATSPI_STATE_READ_ONLY) &&
             has(snapshot.object, ATSPI_STATE_EDITABLE);
    };
    if (!editable) {
      if (replacement.contains('\n') || replacement.contains('\r'))
        return {false, "Mehrzeiliges Ergebnis bitte selbst einfügen."};
      if (!clipboardReady)
        return {false, {}, false, true};
      if (!sameTarget() ||
          !pasteToProcess(atspi_accessible_get_process_id(snapshot.object, nullptr)))
        return {false, "Das Eingabeziel unterstützt kein sicheres automatisches "
                       "Einfügen."};
      // Chromium verarbeitet Paste asynchron; niemals blind zweimal senden.
      for (int attempt = 0; attempt < 25; attempt++) {
        QThread::msleep(20);
        atspi_accessible_clear_cache(snapshot.object);
        const auto actual = readCurrent();
        if (actual && *actual == finalText)
          return {true, {}, true};
        if (!sameTarget() || !actual || *actual != fresh)
          return {false, "Bitte die Übernahme im Eingabefeld prüfen.",
                  !actual || *actual != fresh};
      }
      return {false, "Das Eingabeziel hat den kopierten Text nicht übernommen."};
    }
    auto remove = [&](int start, int finish) {
      GError *error = nullptr;
      bool ok =
          atspi_editable_text_delete_text(editable, start, finish, &error);
      if (error) {
        g_error_free(error);
        return false;
      }
      return ok;
    };
    if (insertedCount) {
      GError *error = nullptr;
      const bool ok = atspi_editable_text_insert_text(
          editable, begin, encoded.constData(),
          snapshot.utf16 ? replacement.size() : encoded.size(), &error);
      if (error)
        g_error_free(error);
      const auto actual = readCurrent();
      if (!ok || error || !actual || *actual != afterInsertion)
        return {false,
                "Das Eingabeziel konnte den Text nicht vollständig übernehmen.",
                !actual || *actual != fresh};
    }
    if (begin != end) {
      // Erst den neuen Text verifizieren. Die alte Auswahl wird erst danach
      // entfernt; bei einem Fehler bleiben die ursprünglichen Daten erhalten.
      if (!sameTarget())
        return {false,
                "Eingabeziel während der Übernahme gewechselt. Bitte das "
                "Ergebnis im Feld prüfen.",
                insertedCount > 0};
      const bool deleted = remove(begin + insertedCount, end + insertedCount);
      const auto actual = readCurrent();
      if (!deleted || !actual || *actual != finalText) {
        if (insertedCount && actual && *actual == afterInsertion &&
            sameTarget()) {
          remove(begin, begin + insertedCount);
          if (auto restored = readCurrent(); restored && *restored == fresh)
            return {false, "Die Auswahl konnte nicht ersetzt werden. Der "
                           "ursprüngliche Text wurde erhalten."};
        }
        return {false,
                "Die Übernahme wurde nur teilweise ausgeführt. Bitte beide "
                "Fassungen im Eingabefeld prüfen.",
                !actual || *actual != fresh};
      }
    }
    atspi_text_set_caret_offset(text, begin + insertedCount, nullptr);
    return {true, {}, true};
  }
};
} // namespace
AccessibleTarget::AccessibleTarget(QObject *parent) : QObject(parent) {
  auto worker = new TargetAgent;
  worker->onApplication = [this](QString value) {
    emit applicationChanged(value);
  };
  agent = worker;
  worker->moveToThread(&thread);
  connect(&thread, &QThread::finished, worker, &QObject::deleteLater);
  thread.start();
  QMetaObject::invokeMethod(
      worker,
      [this, worker] {
        worker->initialize();
        emit availability(worker->initialized);
      },
      Qt::QueuedConnection);
}
AccessibleTarget::~AccessibleTarget() {
  thread.quit();
  thread.wait(3000);
}
void AccessibleTarget::capture(QString request, bool selection) {
  auto worker = static_cast<TargetAgent *>(agent);
  QMetaObject::invokeMethod(
      worker,
      [this, worker, request, selection] {
        emit captured(worker->capture(request, selection));
      },
      Qt::QueuedConnection);
}
void AccessibleTarget::insert(QString token, QString text, bool restoreFocus,
                               bool clipboardReady) {
  auto worker = static_cast<TargetAgent *>(agent);
  QMetaObject::invokeMethod(
      worker,
      [this, worker, token, text, restoreFocus, clipboardReady] {
        auto result = worker->insert(token, text, restoreFocus, clipboardReady);
        if (result.needsClipboard) {
          emit clipboardRequested(token, text, restoreFocus);
          return;
        }
        emit inserted(token, result.success, result.reason, result.modified);
      },
      Qt::QueuedConnection);
}
void AccessibleTarget::clear(QString token) {
  auto worker = static_cast<TargetAgent *>(agent);
  QMetaObject::invokeMethod(
      worker,
      [worker, token] {
        worker->snapshotOrder.removeAll(token);
        auto found = worker->snapshots.find(token);
        if (found != worker->snapshots.end()) {
          if (found->object)
            g_object_unref(found->object);
          worker->snapshots.erase(found);
        }
      },
      Qt::QueuedConnection);
}
