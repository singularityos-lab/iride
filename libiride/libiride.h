#ifndef LIBIRIDE_H
#define LIBIRIDE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int iride_check(const uint8_t *data, size_t len);
int iride_pick(const uint8_t *data, size_t len, uint32_t pixels,
               const uint8_t **png, size_t *png_len, uint32_t *size);

#ifdef __cplusplus
}
#endif

#endif
