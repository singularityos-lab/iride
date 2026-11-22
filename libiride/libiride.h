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

int iride_motion(const uint8_t *data, size_t len, uint32_t pixels,
                 uint32_t *duration, uint32_t *size, size_t *work_len);
int iride_prepare(const uint8_t *data, size_t len, uint32_t pixels,
                  uint8_t *work, size_t work_len);
int iride_frame(const uint8_t *data, size_t len, uint32_t pixels, double msec,
                const uint8_t *work, size_t work_len,
                uint8_t *out, size_t out_len);

#ifdef __cplusplus
}
#endif

#endif
