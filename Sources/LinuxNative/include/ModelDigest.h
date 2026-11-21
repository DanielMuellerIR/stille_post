#ifndef STILLEPOST_MODEL_DIGEST_H
#define STILLEPOST_MODEL_DIGEST_H

#include <stdint.h>

int sp_model_sha256(int fd, uint64_t remaining, unsigned char digest[32], int (*cancelled)(void));

#endif
