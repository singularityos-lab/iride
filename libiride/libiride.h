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

enum { IRIDE_LIGHT, IRIDE_DARK };
enum { IRIDE_ACCENT_NONE, IRIDE_ACCENT_BLACK, IRIDE_ACCENT_WHITE };

int iride_variant(const uint8_t *data, size_t len, uint32_t scheme, uint32_t accent,
                  const uint8_t **out, size_t *out_len);
#define IRIDE_NO_ACCENT 0xffffffffu

int iride_look(const uint8_t *data, size_t len, uint32_t scheme, int accented,
               const uint8_t **black, size_t *black_len,
               const uint8_t **white, size_t *white_len);
int iride_still(const uint8_t *data, size_t len, uint32_t pixels, uint32_t scheme,
                uint32_t accent, uint8_t *out, size_t out_len, uint32_t *size);
int iride_tint(const uint8_t *black, const uint8_t *white, size_t len, uint32_t rgb,
               uint8_t *out, size_t out_len);

#ifdef __cplusplus
}
#endif

#endif
