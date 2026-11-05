#include "shortcut_codec.h"
namespace {
const QList<QPair<Qt::Key, QString>> names{
    {Qt::Key_Space, "space"},
    {Qt::Key_Return, "Return"},
    {Qt::Key_Enter, "KP_Enter"},
    {Qt::Key_Escape, "Escape"},
    {Qt::Key_Tab, "Tab"},
    {Qt::Key_Backspace, "BackSpace"},
    {Qt::Key_Delete, "Delete"},
    {Qt::Key_Insert, "Insert"},
    {Qt::Key_Home, "Home"},
    {Qt::Key_End, "End"},
    {Qt::Key_Left, "Left"},
    {Qt::Key_Right, "Right"},
    {Qt::Key_Up, "Up"},
    {Qt::Key_Down, "Down"},
    {Qt::Key_PageUp, "Page_Up"},
    {Qt::Key_PageDown, "Page_Down"},
    {Qt::Key_Plus, "plus"},
    {Qt::Key_Minus, "minus"},
    {Qt::Key_Equal, "equal"},
    {Qt::Key_Comma, "comma"},
    {Qt::Key_Period, "period"},
    {Qt::Key_Slash, "slash"},
    {Qt::Key_Backslash, "backslash"},
    {Qt::Key_Semicolon, "semicolon"},
    {Qt::Key_Apostrophe, "apostrophe"},
    {Qt::Key_BracketLeft, "bracketleft"},
    {Qt::Key_BracketRight, "bracketright"},
    {Qt::Key_QuoteLeft, "grave"}};
}
QString encodeShortcut(QKeyCombination combination) {
  auto modifiers = combination.keyboardModifiers();
  if (!(modifiers & (Qt::ControlModifier | Qt::AltModifier | Qt::MetaModifier)))
    return {};
  if (modifiers & ~(Qt::ControlModifier | Qt::AltModifier | Qt::MetaModifier |
                    Qt::ShiftModifier | Qt::KeypadModifier))
    return {};
  QStringList parts;
  if (modifiers & Qt::ControlModifier)
    parts << "CTRL";
  if (modifiers & Qt::AltModifier)
    parts << "ALT";
  if (modifiers & Qt::MetaModifier)
    parts << "LOGO";
  if (modifiers & Qt::ShiftModifier)
    parts << "SHIFT";
  const auto key = combination.key();
  QString symbol;
  for (auto pair : names)
    if (pair.first == key) {
      symbol = pair.second;
      break;
    }
  if (symbol.isEmpty() && key >= Qt::Key_F1 && key <= Qt::Key_F35)
    symbol = "F" + QString::number(key - Qt::Key_F1 + 1);
  if (symbol.isEmpty() && key >= Qt::Key_0 && key <= Qt::Key_9)
    symbol = QString(QChar(key));
  if (symbol.isEmpty() && key >= Qt::Key_A && key <= Qt::Key_Z)
    symbol = QString(QChar(key)).toLower();
  if (symbol.isEmpty() && key >= 0x80 && key <= 0xffff)
    symbol =
        QString("U%1").arg(QChar(key).toLower().unicode(), 4, 16, QChar('0'));
  if ((modifiers & Qt::KeypadModifier) && key >= Qt::Key_0 && key <= Qt::Key_9)
    symbol = "KP_" + symbol;
  if (symbol.isEmpty())
    return {};
  parts << symbol;
  return parts.join('+');
}
QString displayShortcut(QString shortcut) {
  auto parts = shortcut.split('+');
  if (parts.isEmpty())
    return shortcut;
  auto symbol = parts.takeLast();
  Qt::KeyboardModifiers modifiers;
  for (auto modifier : parts) {
    if (modifier == "CTRL")
      modifiers |= Qt::ControlModifier;
    else if (modifier == "ALT")
      modifiers |= Qt::AltModifier;
    else if (modifier == "LOGO")
      modifiers |= Qt::MetaModifier;
    else if (modifier == "SHIFT")
      modifiers |= Qt::ShiftModifier;
    else
      return shortcut;
  }
  int key = 0;
  for (auto pair : names)
    if (pair.second == symbol) {
      key = pair.first;
      break;
    }
  if (!key && symbol.size() == 1)
    key = symbol.toUpper()[0].unicode();
  if (!key && symbol.startsWith('F')) {
    bool ok;
    auto number = symbol.mid(1).toInt(&ok);
    if (ok && number >= 1 && number <= 35)
      key = Qt::Key_F1 + number - 1;
  }
  if (!key && symbol.startsWith('U')) {
    bool ok;
    auto value = symbol.mid(1).toUInt(&ok, 16);
    if (ok && value <= 0xffff)
      key = QChar(value).toUpper().unicode();
  }
  return key ? QKeySequence(QKeyCombination(modifiers, Qt::Key(key)))
                   .toString(QKeySequence::NativeText)
             : shortcut;
}
