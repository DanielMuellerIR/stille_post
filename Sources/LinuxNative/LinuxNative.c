#include "LinuxNative.h"
#include <limits.h>
#include <openssl/pem.h>
#include <openssl/rand.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>
#include <stdlib.h>
#include <string.h>
struct sp_tls_context {
  SSL_CTX *value;
};
struct sp_tls_connection {
  SSL *value;
};
int sp_random(unsigned char *bytes, size_t count) {
  return count <= INT_MAX && RAND_bytes(bytes, (int)count) == 1;
}
int sp_sha256(const unsigned char *bytes, size_t count,
              unsigned char result[32]) {
  unsigned int size = 0;
  return EVP_Digest(bytes, count, result, &size, EVP_sha256(), NULL) == 1 &&
         size == 32;
}
void sp_free(void *value) { free(value); }
int sp_certificate_fingerprint(const char *certificate,
                               unsigned char result[32]) {
  BIO *bio = BIO_new_mem_buf(certificate, -1);
  X509 *cert = bio ? PEM_read_bio_X509(bio, NULL, NULL, NULL) : NULL;
  unsigned int count = 0;
  int ok =
      cert && X509_digest(cert, EVP_sha256(), result, &count) && count == 32;
  X509_free(cert);
  BIO_free(bio);
  return ok;
}
static char *bio_string(BIO *bio) {
  char *data = NULL;
  long size = BIO_get_mem_data(bio, &data);
  if (size <= 0 || size > 65535)
    return NULL;
  char *value = malloc(size + 1);
  if (value) {
    memcpy(value, data, size);
    value[size] = 0;
  }
  return value;
}
static int certificate_for_key(EVP_PKEY *key, char **certificate) {
  *certificate = NULL;
  X509 *cert = X509_new();
  BIO *cert_bio = BIO_new(BIO_s_mem());
  int ok = 0;
  if (!key || !cert || !cert_bio)
    goto end;
  unsigned char serial[16];
  if (!sp_random(serial, sizeof(serial)))
    goto end;
  serial[0] &= 0x7f;
  BIGNUM *number = BN_bin2bn(serial, sizeof(serial), NULL);
  if (!number)
    goto end;
  ASN1_INTEGER *integer = BN_to_ASN1_INTEGER(number, NULL);
  BN_free(number);
  if (!integer)
    goto end;
  int serial_ok = X509_set_serialNumber(cert, integer);
  ASN1_INTEGER_free(integer);
  if (!serial_ok)
    goto end;
  if (!X509_set_version(cert, 2) ||
      !X509_gmtime_adj(X509_getm_notBefore(cert), -300) ||
      !X509_gmtime_adj(X509_getm_notAfter(cert), 365L * 24 * 3600) ||
      !X509_set_pubkey(cert, key))
    goto end;
  X509_NAME *name = X509_get_subject_name(cert);
  if (!X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC,
                                  (const unsigned char *)"Stille Post Bridge",
                                  -1, -1, 0) ||
      !X509_set_issuer_name(cert, name))
    goto end;
  if (!X509_sign(cert, key, EVP_sha256()) ||
      !PEM_write_bio_X509(cert_bio, cert))
    goto end;
  *certificate = bio_string(cert_bio);
  ok = *certificate != NULL;
end:
  if (!ok) {
    free(*certificate);
    *certificate = NULL;
  }
  BIO_free(cert_bio);
  X509_free(cert);
  return ok;
}
int sp_identity_create(char **certificate, char **private_key) {
  *certificate = NULL;
  *private_key = NULL;
  EVP_PKEY *key = EVP_EC_gen("prime256v1");
  BIO *bio = BIO_new(BIO_s_mem());
  int ok = key && bio && certificate_for_key(key, certificate) &&
           PEM_write_bio_PrivateKey(bio, key, NULL, NULL, 0, NULL, NULL);
  if (ok) {
    *private_key = bio_string(bio);
    ok = *private_key != NULL;
  }
  if (!ok) {
    free(*certificate);
    free(*private_key);
    *certificate = NULL;
    *private_key = NULL;
  }
  BIO_free(bio);
  EVP_PKEY_free(key);
  return ok;
}
int sp_identity_renew(const char *certificate, const char *private_key,
                      char **renewed) {
  *renewed = NULL;
  BIO *cert_bio = BIO_new_mem_buf(certificate, -1),
      *key_bio = BIO_new_mem_buf(private_key, -1);
  X509 *cert = cert_bio ? PEM_read_bio_X509(cert_bio, NULL, NULL, NULL) : NULL;
  EVP_PKEY *key =
      key_bio ? PEM_read_bio_PrivateKey(key_bio, NULL, NULL, NULL) : NULL;
  int ok = cert && key && X509_check_private_key(cert, key) &&
           certificate_for_key(key, renewed);
  X509_free(cert);
  EVP_PKEY_free(key);
  BIO_free(cert_bio);
  BIO_free(key_bio);
  return ok;
}
sp_tls_context *sp_tls_context_new(const char *certificate, const char *key) {
  BIO *a = BIO_new_mem_buf(certificate, -1), *b = BIO_new_mem_buf(key, -1);
  X509 *cert = a ? PEM_read_bio_X509(a, NULL, NULL, NULL) : NULL;
  EVP_PKEY *private_key =
      b ? PEM_read_bio_PrivateKey(b, NULL, NULL, NULL) : NULL;
  SSL_CTX *ctx = SSL_CTX_new(TLS_server_method());
  int ok = ctx && cert && private_key;
  if (ok)
    ok = SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION) &&
         SSL_CTX_use_certificate(ctx, cert) &&
         SSL_CTX_use_PrivateKey(ctx, private_key) &&
         SSL_CTX_check_private_key(ctx) &&
         X509_cmp_current_time(X509_get0_notAfter(cert)) > 0 &&
         X509_cmp_current_time(X509_get0_notBefore(cert)) < 0;
  BIO_free(a);
  BIO_free(b);
  X509_free(cert);
  EVP_PKEY_free(private_key);
  if (!ok) {
    SSL_CTX_free(ctx);
    return NULL;
  }
  SSL_CTX_set_options(ctx, SSL_OP_NO_COMPRESSION | SSL_OP_NO_RENEGOTIATION);
  SSL_CTX_set_session_cache_mode(ctx, SSL_SESS_CACHE_OFF);
  sp_tls_context *result = malloc(sizeof(*result));
  if (!result) {
    SSL_CTX_free(ctx);
    return NULL;
  }
  result->value = ctx;
  return result;
}
void sp_tls_context_free(sp_tls_context *ctx) {
  if (ctx) {
    SSL_CTX_free(ctx->value);
    free(ctx);
  }
}
sp_tls_connection *sp_tls_connection_new(sp_tls_context *ctx, int fd) {
  sp_tls_connection *value = calloc(1, sizeof(*value));
  if (!value)
    return NULL;
  value->value = SSL_new(ctx->value);
  if (!value->value || !SSL_set_fd(value->value, fd)) {
    sp_tls_connection_free(value);
    return NULL;
  }
  return value;
}
static int result(SSL *ssl, int status) {
  if (status > 0)
    return status;
  int error = SSL_get_error(ssl, status);
  return error == SSL_ERROR_WANT_READ    ? 0
         : error == SSL_ERROR_WANT_WRITE ? -2
                                         : -1;
}
int sp_tls_accept(sp_tls_connection *c) {
  return result(c->value, SSL_accept(c->value));
}
int sp_tls_read(sp_tls_connection *c, void *bytes, int capacity) {
  return result(c->value, SSL_read(c->value, bytes, capacity));
}
int sp_tls_write(sp_tls_connection *c, const void *bytes, int count) {
  return result(c->value, SSL_write(c->value, bytes, count));
}
int sp_tls_pending(sp_tls_connection *c) { return SSL_pending(c->value); }
void sp_tls_connection_free(sp_tls_connection *c) {
  if (c) {
    if (c->value && SSL_is_init_finished(c->value))
      SSL_shutdown(c->value);
    SSL_free(c->value);
    free(c);
  }
}
