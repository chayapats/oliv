#ifndef OLIV_TOKENIZER_H
#define OLIV_TOKENIZER_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Private owning ABI. Each returned allocation must use its matching free.
void *oliv_tokenizer_open(const char *filename);
void oliv_tokenizer_close(void *handle);
uint32_t *oliv_tokenizer_encode(const void *handle, const uint8_t *text,
                               size_t length, bool add_special, size_t *count);
uint8_t *oliv_tokenizer_decode(const void *handle, const uint32_t *tokens,
                              size_t length, bool skip_special, size_t *count);
void oliv_tokenizer_free_tokens(uint32_t *tokens, size_t count);
void oliv_tokenizer_free_bytes(uint8_t *bytes, size_t count);
#endif
