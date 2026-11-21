#include "ModelDigest.h"
#include <errno.h>
#include <openssl/evp.h>
#include <unistd.h>

int sp_model_sha256(int fd, uint64_t remaining, unsigned char digest[32]) {
  EVP_MD_CTX *context = EVP_MD_CTX_new();
  if (!context)
    return 0;

  int ok = EVP_DigestInit_ex(context, EVP_sha256(), NULL) == 1;
  unsigned char buffer[65536];
  while (ok && remaining > 0) {
    size_t length = remaining < sizeof(buffer) ? (size_t)remaining : sizeof(buffer);
    ssize_t count = read(fd, buffer, length);
    if (count < 0 && errno == EINTR)
      continue;
    if (count <= 0) {
      ok = 0;
      break;
    }
    ok = EVP_DigestUpdate(context, buffer, (size_t)count) == 1;
    remaining -= (uint64_t)count;
  }

  unsigned int length = 0;
  ok = ok && EVP_DigestFinal_ex(context, digest, &length) == 1 && length == 32;
  EVP_MD_CTX_free(context);
  return ok;
}
