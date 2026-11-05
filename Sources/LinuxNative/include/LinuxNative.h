#ifndef STILLEPOST_LINUX_NATIVE_H
#define STILLEPOST_LINUX_NATIVE_H
#include <stddef.h>
#include <stdint.h>
typedef struct sp_tls_context sp_tls_context;
typedef struct sp_tls_connection sp_tls_connection;
typedef struct sp_silero sp_silero;
sp_silero *sp_silero_new(const char *model);
void sp_silero_free(sp_silero *context);
int sp_silero_probability(sp_silero *context, const float samples[4096],
                          float *probability);
int sp_random(unsigned char *bytes, size_t count);
int sp_sha256(const unsigned char *bytes, size_t count,
              unsigned char result[32]);
int sp_identity_create(char **certificate, char **private_key);
int sp_identity_renew(const char *certificate, const char *private_key,
                      char **renewed);
int sp_certificate_fingerprint(const char *certificate,
                               unsigned char result[32]);
void sp_free(void *value);
sp_tls_context *sp_tls_context_new(const char *certificate, const char *key);
void sp_tls_context_free(sp_tls_context *context);
sp_tls_connection *sp_tls_connection_new(sp_tls_context *context, int fd);
/* 1 = Erfolg, 0 = WANT_READ, -2 = WANT_WRITE, -1 = geschlossen/Fehler. */
int sp_tls_accept(sp_tls_connection *connection);
int sp_tls_read(sp_tls_connection *connection, void *bytes, int capacity);
int sp_tls_write(sp_tls_connection *connection, const void *bytes, int count);
int sp_tls_pending(sp_tls_connection *connection);
void sp_tls_connection_free(sp_tls_connection *connection);
#endif
