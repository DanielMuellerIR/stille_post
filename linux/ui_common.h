#pragma once
#include <QtWidgets>
QString trKey(const char *key, QString fallback = QString());
QString trText(QString text);
bool copyText(const QString &text);
QString trFormat(const char *key, QStringList values);
QString requestPolicyDescription(const QJsonObject &review);
void loadTranslations();
QWidget *scrollPage(QWidget *content);
QGroupBox *section(QString title, QWidget *parent = nullptr);
QString nativeDate(double seconds);
QJsonValue jsonValue(const QJsonObject &object, QString path);
void setJsonValue(QJsonObject &object, QString path, QJsonValue value);
void applyAppearance(QApplication &app);
