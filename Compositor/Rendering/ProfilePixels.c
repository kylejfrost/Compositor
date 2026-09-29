#include "ProfilePixels.h"
#include <dispatch/dispatch.h>
#include <math.h>

// Code coverage would put counters in these loops that every thread of a parallel bake increments, which makes a
// 256³ bake about 100 times slower in test builds, so the kernel is left out of coverage.
#pragma clang attribute push (__attribute__((no_profile_instrument_function)), apply_to = function)

// Transfer tables span [0, 1] in 4096 cells, as the SDK's dng_1d_table does.
#define TABLE_CELLS 4096
enum { GAMMA_LINEAR, GAMMA_SRGB, GAMMA_18, GAMMA_22, GAMMA_REC709, GAMMA_COUNT };
enum { PRIMARIES_PROPHOTO = 2 };
enum { GAMUT_EXTEND = 1 };

static double encodeTables[GAMMA_COUNT][TABLE_CELLS + 1];
static double decodeTables[GAMMA_COUNT][TABLE_CELLS + 1];
static double sRGBByteDecode[256];
static dispatch_once_t tablesOnce;

static inline double clamp01(double x) { return x > 0 ? (x < 1 ? x : 1) : 0; }

// MARK: Exact transfer functions (dng_function_GammaEncode_*), used to fill the tables

// The cubic Hermite segment from (x0, y0) with slope s0 to (x1, y1) with slope s1 (dng_spline_solver's).
static inline double hermite(double x, double x0, double y0, double s0, double x1, double y1, double s1) {
    double a = x1 - x0, b = (x - x0) / a, c = (x1 - x) / a;
    return (y0 * (2 - c + b) + s0 * a * b) * c * c + (y1 * (2 - b + c) - s1 * a * c) * b * b;
}

// γ1.8 and γ2.2: a pure power above x1, with a cubic toe of slope 32 at black below it.
typedef struct { double gamma, x1, y1, s1; } toe_gamma;
static const toe_gamma gamma18 = { 1.8, 8.2118790552e-4, 0.019310851, 13.064306598 };
static const toe_gamma gamma22 = { 2.2, 0.0034800731, 0.0763027458, 9.9661890075 };

static double toe_encode(const toe_gamma *curve, double x) {
    return x <= curve->x1 ? hermite(x, 0, 0, 32, curve->x1, curve->y1, curve->s1) : pow(x, 1 / curve->gamma);
}

static double toe_decode(const toe_gamma *curve, double y) {
    if (y >= curve->y1) return pow(y, curve->gamma);
    // The toe is monotone, so bisect it.
    double low = 0, high = curve->x1;
    for (int step = 0; step < 60; ++step) {
        double middle = (low + high) / 2;
        if (toe_encode(curve, middle) < y) low = middle; else high = middle;
    }
    return (low + high) / 2;
}

static const double rec709Alpha = 1.0992968268094429, rec709Beta = 0.0180539685108078;

static double exact_encode(int gamma, double x) {
    switch (gamma) {
        case GAMMA_SRGB: return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055;
        case GAMMA_18: return toe_encode(&gamma18, x);
        case GAMMA_22: return toe_encode(&gamma22, x);
        case GAMMA_REC709: return x < rec709Beta ? 4.5 * x : rec709Alpha * pow(x, 0.45) - (rec709Alpha - 1);
        default: return x;
    }
}

static double exact_decode(int gamma, double y) {
    switch (gamma) {
        case GAMMA_SRGB: return y <= 0.04045 ? y / 12.92 : pow((y + 0.055) / 1.055, 2.4);
        case GAMMA_18: return toe_decode(&gamma18, y);
        case GAMMA_22: return toe_decode(&gamma22, y);
        case GAMMA_REC709: return y < 4.5 * rec709Beta ? y / 4.5 : pow((y + rec709Alpha - 1) / rec709Alpha, 1 / 0.45);
        default: return y;
    }
}

static void build_tables(void *context) {
    (void)context;
    for (int gamma = 0; gamma < GAMMA_COUNT; ++gamma) {
        for (int i = 0; i <= TABLE_CELLS; ++i) {
            double x = i * (1.0 / TABLE_CELLS);
            encodeTables[gamma][i] = exact_encode(gamma, x);
            decodeTables[gamma][i] = exact_decode(gamma, x);
        }
    }
    for (int i = 0; i < 256; ++i) sRGBByteDecode[i] = exact_decode(GAMMA_SRGB, i / 255.0);
}

static inline void ensure_tables(void) { dispatch_once_f(&tablesOnce, NULL, build_tables); }

static inline int gamma_index(int32_t gamma) { return gamma >= 0 && gamma < GAMMA_COUNT ? (int)gamma : GAMMA_LINEAR; }

// dng_1d_table::Interpolate over 4097 samples, the input clamped to [0, 1].
static inline double interpolate(const double *table, double x) {
    double scaled = clamp01(x) * TABLE_CELLS;
    int i = (int)scaled;
    return i >= TABLE_CELLS ? table[TABLE_CELLS] : table[i] + (table[i + 1] - table[i]) * (scaled - i);
}

static inline double interpolate_curve(const float *curve, double x) {
    double scaled = clamp01(x) * (PROFILE_CURVE_SAMPLES - 1);
    int i = (int)scaled;
    if (i >= PROFILE_CURVE_SAMPLES - 1) return curve[PROFILE_CURVE_SAMPLES - 1];
    return curve[i] + ((double)curve[i + 1] - curve[i]) * (scaled - i);
}

static inline double encode(int gamma, double x) { return interpolate(encodeTables[gamma], x); }
static inline double decode(int gamma, double y) { return interpolate(decodeTables[gamma], y); }

static inline void multiply(const double m[9], const double v[3], double out[3]) {
    double r = m[0] * v[0] + m[1] * v[1] + m[2] * v[2];
    double g = m[3] * v[0] + m[4] * v[1] + m[5] * v[2];
    double b = m[6] * v[0] + m[7] * v[1] + m[8] * v[2];
    out[0] = r;
    out[1] = g;
    out[2] = b;
}

// MARK: LookTable (RefBaselineHueSatMap, SDR)

static inline void hsv_to_rgb(double h, double s, double v, double rgb[3]) {
    if (s <= 0) {
        rgb[0] = rgb[1] = rgb[2] = v;
        return;
    }
    h = fmod(h, 6);
    if (h < 0) h += 6;
    int sector = (int)h;
    double f = h - sector;
    if (sector >= 6) sector = 0;
    double p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f));
    switch (sector) {
        case 0: rgb[0] = v; rgb[1] = t; rgb[2] = p; break;
        case 1: rgb[0] = q; rgb[1] = v; rgb[2] = p; break;
        case 2: rgb[0] = p; rgb[1] = v; rgb[2] = t; break;
        case 3: rgb[0] = p; rgb[1] = q; rgb[2] = v; break;
        case 4: rgb[0] = t; rgb[1] = p; rgb[2] = v; break;
        default: rgb[0] = v; rgb[1] = p; rgb[2] = q; break;
    }
}

static inline void hue_sat_map(const profile_program *program, double rgb[3]) {
    const int hues = (int)program->hueDivisions, saturations = (int)program->saturationDivisions;
    const int values = (int)program->valueDivisions;
    const double r = rgb[0], g = rgb[1], b = rgb[2];
    double v = fmax(r, fmax(g, b)), gap = v - fmin(r, fmin(g, b)), h = 0, s = 0;
    if (gap > 0) {
        if (r == v) {
            h = (g - b) / gap;
            if (h < 0) h += 6;
        } else if (g == v) {
            h = 2 + (b - r) / gap;
        } else {
            h = 4 + (r - g) / gap;
        }
        s = gap / v;
    }

    double hueScaled = h * (hues < 2 ? 0 : hues / 6.0);
    int h0 = (int)hueScaled, h1 = h0 + 1;
    if (h0 >= hues - 1) {
        h0 = hues - 1;
        h1 = 0;
    }
    double hf1 = hueScaled - h0, hf0 = 1 - hf1;
    double satScaled = s * (saturations - 1);
    int s0 = (int)satScaled;
    if (s0 > saturations - 2) s0 = saturations - 2;
    double sf1 = satScaled - s0, sf0 = 1 - sf1;

    const float *look = program->look;
    const size_t hueStride = (size_t)saturations * 3, valueStride = (size_t)hues * hueStride;
    const int encoded = program->lookEncoding == 1 && values >= 2;
    double vEncoded, modify[2][3];
    if (values < 2) {
        vEncoded = v;
        for (int side = 0; side < 2; ++side) {
            const float *a = look + (size_t)h0 * hueStride + (size_t)(s0 + side) * 3;
            const float *c = look + (size_t)h1 * hueStride + (size_t)(s0 + side) * 3;
            for (int k = 0; k < 3; ++k) modify[side][k] = hf0 * a[k] + hf1 * c[k];
        }
    } else {
        vEncoded = program->lookEncoding == 1 ? encode(GAMMA_SRGB, v) : v;
        double valueScaled = vEncoded * (values - 1);
        int v0 = (int)valueScaled;
        if (v0 > values - 2) v0 = values - 2;
        double vf1 = valueScaled - v0, vf0 = 1 - vf1;
        for (int side = 0; side < 2; ++side) {
            const float *plane = look + (size_t)v0 * valueStride + (size_t)(s0 + side) * 3;
            const float *a = plane + (size_t)h0 * hueStride, *c = plane + (size_t)h1 * hueStride;
            const float *d = a + valueStride, *e = c + valueStride;
            for (int k = 0; k < 3; ++k) {
                modify[side][k] = vf0 * (hf0 * a[k] + hf1 * c[k]) + vf1 * (hf0 * d[k] + hf1 * e[k]);
            }
        }
    }
    double hueShift = sf0 * modify[0][0] + sf1 * modify[1][0];
    double satScale = sf0 * modify[0][1] + sf1 * modify[1][1];
    double valScale = sf0 * modify[0][2] + sf1 * modify[1][2];

    h += hueShift * (6.0 / 360.0);
    s = fmin(s * satScale, 1);
    vEncoded = clamp01(vEncoded * valScale);
    v = encoded ? decode(GAMMA_SRGB, vEncoded) : vEncoded;
    hsv_to_rgb(h, s, v, rgb);
}

// MARK: RGBTable (RefRGBtoRGBTable3D / 1D, SDR)

static inline void tetrahedral(const float *table, int divisions, const double x[3], double y[3]) {
    int index[3];
    double f[3];
    for (int c = 0; c < 3; ++c) {
        double scaled = x[c] * (divisions - 1);
        index[c] = (int)scaled;
        if (index[c] > divisions - 2) index[c] = divisions - 2;
        f[c] = scaled - index[c];
    }
    const size_t stepB = 3, stepG = (size_t)divisions * 3, stepR = (size_t)divisions * stepG;
    const float *base = table + (size_t)index[0] * stepR + (size_t)index[1] * stepG + (size_t)index[2] * stepB;
    const double fr = f[0], fg = f[1], fb = f[2];
    size_t o1, o2;
    double f1, f2, f3;
    if (fg >= fr) {
        if (fb >= fg) {
            o1 = stepB; o2 = stepG + stepB; f1 = fb; f2 = fg; f3 = fr;
        } else if (fb >= fr) {
            o1 = stepG; o2 = stepG + stepB; f1 = fg; f2 = fb; f3 = fr;
        } else {
            o1 = stepG; o2 = stepR + stepG; f1 = fg; f2 = fr; f3 = fb;
        }
    } else {
        if (fb >= fr) {
            o1 = stepB; o2 = stepR + stepB; f1 = fb; f2 = fr; f3 = fg;
        } else if (fb >= fg) {
            o1 = stepR; o2 = stepR + stepB; f1 = fr; f2 = fb; f3 = fg;
        } else {
            o1 = stepR; o2 = stepR + stepG; f1 = fr; f2 = fg; f3 = fb;
        }
    }
    const size_t o3 = stepR + stepG + stepB;
    const double w0 = 1 - f1, w1 = f1 - f2, w2 = f2 - f3, w3 = f3;
    for (int c = 0; c < 3; ++c) y[c] = w0 * base[c] + w1 * base[o1 + (size_t)c] + w2 * base[o2 + (size_t)c] + w3 * base[o3 + (size_t)c];
}

static inline void rgb_table(const profile_program *program, double rgb[3]) {
    double x[3], delta[3] = { 0, 0, 0 }, y[3];
    const int convert = program->rgbPrimaries != PRIMARIES_PROPHOTO;
    if (convert) {
        double table[3];
        multiply(program->proPhotoToTable, rgb, table);
        for (int c = 0; c < 3; ++c) {
            x[c] = clamp01(table[c]);
            if (program->rgbGamut == GAMUT_EXTEND) delta[c] = table[c] - x[c];
        }
    } else {
        for (int c = 0; c < 3; ++c) x[c] = clamp01(rgb[c]);
    }
    const int gamma = gamma_index(program->rgbGamma);
    if (gamma != GAMMA_LINEAR) {
        for (int c = 0; c < 3; ++c) x[c] = encode(gamma, x[c]);
    }
    const int divisions = (int)program->rgbDivisions;
    const double amount = program->rgbAmount;
    if (program->rgbDimensions == 3) {
        tetrahedral(program->rgb, divisions, x, y);
        // The amount blends in the table's own encoding.
        if (amount != 1) {
            for (int c = 0; c < 3; ++c) y[c] = clamp01(x[c] + amount * (y[c] - x[c]));
        }
    } else {
        for (int c = 0; c < 3; ++c) {
            double scaled = x[c] * (divisions - 1);
            int i = (int)scaled;
            if (i > divisions - 2) i = divisions - 2;
            if (i < 0) i = 0;
            const float *node = program->rgb + (size_t)i * 3 + (size_t)c;
            double value = node[0] + (scaled - i) * ((double)node[3] - node[0]);
            y[c] = x[c] + amount * (value - x[c]);
        }
    }
    if (gamma != GAMMA_LINEAR) {
        for (int c = 0; c < 3; ++c) y[c] = decode(gamma, y[c]);
    }
    for (int c = 0; c < 3; ++c) y[c] += delta[c];
    if (convert) multiply(program->tableToProPhoto, y, y);
    for (int c = 0; c < 3; ++c) rgb[c] = clamp01(y[c]);
}

// MARK: Pipeline

static inline void curves(const profile_program *program, double rgb[3]) {
    double e[3];
    for (int c = 0; c < 3; ++c) e[c] = encode(GAMMA_SRGB, rgb[c]);
    if (program->curveMask & 1) {
        for (int c = 0; c < 3; ++c) e[c] = interpolate_curve(program->curves, e[c]);
    }
    for (int c = 0; c < 3; ++c) {
        if (program->curveMask & (2 << c)) e[c] = interpolate_curve(program->curves + (size_t)(c + 1) * PROFILE_CURVE_SAMPLES, e[c]);
    }
    for (int c = 0; c < 3; ++c) rgb[c] = decode(GAMMA_SRGB, e[c]);
}

// Linear sRGB in → encoded sRGB 0–1 out.
static inline void evaluate_linear(const profile_program *program, const double linear[3], double out[3]) {
    double rgb[3], srgb[3];
    multiply(program->sRGBToProPhoto, linear, rgb);
    for (int c = 0; c < 3; ++c) rgb[c] = clamp01(rgb[c]);
    if (program->hueDivisions > 0) hue_sat_map(program, rgb);
    if (program->curveMask != 0) curves(program, rgb);
    if (program->grayscale) {
        const double *w = program->grayWeights;
        rgb[0] = rgb[1] = rgb[2] = clamp01(w[0] * rgb[0] + w[1] * rgb[1] + w[2] * rgb[2]);
    }
    if (program->rgbDivisions > 0) rgb_table(program, rgb);
    multiply(program->proPhotoToSRGB, rgb, srgb);
    for (int c = 0; c < 3; ++c) out[c] = encode(GAMMA_SRGB, srgb[c]);
}

static inline void evaluate_byte(const profile_program *program, const uint8_t in[3], uint8_t out[3]) {
    const double linear[3] = { sRGBByteDecode[in[0]], sRGBByteDecode[in[1]], sRGBByteDecode[in[2]] };
    double encoded[3];
    evaluate_linear(program, linear, encoded);
    for (int c = 0; c < 3; ++c) out[c] = (uint8_t)floor(encoded[c] * 255 + 0.5);
}

void profile_evaluate(const profile_program *program, const double srgb[3], double out[3]) {
    ensure_tables();
    const double linear[3] = { exact_decode(GAMMA_SRGB, clamp01(srgb[0])), exact_decode(GAMMA_SRGB, clamp01(srgb[1])),
                               exact_decode(GAMMA_SRGB, clamp01(srgb[2])) };
    evaluate_linear(program, linear, out);
}

void profile_evaluate_byte(const profile_program *program, const uint8_t in[3], uint8_t out[3]) {
    ensure_tables();
    evaluate_byte(program, in, out);
}

void profile_hue_sat_map(const profile_program *program, double rgb[3]) {
    ensure_tables();
    if (program->hueDivisions > 0) hue_sat_map(program, rgb);
}

void profile_rgb_table(const profile_program *program, double rgb[3]) {
    ensure_tables();
    if (program->rgbDivisions > 0) rgb_table(program, rgb);
}

double profile_transfer_encode(int32_t gamma, double x) {
    ensure_tables();
    return encode(gamma_index(gamma), x);
}

double profile_transfer_decode(int32_t gamma, double y) {
    ensure_tables();
    return decode(gamma_index(gamma), y);
}

// MARK: Tables and pixels

void profile_bake_lut(const profile_program *program, int firstRed, int redCount, uint8_t *lut) {
    ensure_tables();
    for (int red = firstRed; red < firstRed + redCount; ++red) {
        uint8_t *plane = lut + (size_t)red * 256 * 256 * 3;
        uint8_t in[3] = { (uint8_t)red, 0, 0 };
        for (int green = 0; green < 256; ++green) {
            in[1] = (uint8_t)green;
            for (int blue = 0; blue < 256; ++blue) {
                in[2] = (uint8_t)blue;
                evaluate_byte(program, in, plane + ((size_t)green * 256 + (size_t)blue) * 3);
            }
        }
    }
}

// Straight colour bytes for a premultiplied pixel whose alpha is neither 0 nor 255.
static inline void unpremultiply(const uint8_t *pixel, uint8_t colour[3]) {
    const unsigned alpha = pixel[3];
    for (int c = 0; c < 3; ++c) {
        unsigned value = (pixel[c] * 255u + alpha / 2) / alpha;
        colour[c] = (uint8_t)(value < 255 ? value : 255);
    }
}

static inline void premultiply(uint8_t *pixel, const uint8_t colour[3]) {
    const unsigned alpha = pixel[3];
    for (int c = 0; c < 3; ++c) pixel[c] = (uint8_t)((colour[c] * alpha + 127) / 255);
}

static inline const uint8_t *lut_entry(const uint8_t *lut, const uint8_t colour[3]) {
    return lut + (((size_t)colour[0] << 16) | ((size_t)colour[1] << 8) | colour[2]) * 3;
}

void profile_apply_lut(uint8_t *rgba, size_t width, size_t height, size_t stride, const uint8_t *lut) {
    for (size_t y = 0; y < height; ++y) {
        uint8_t *pixel = rgba + y * stride;
        for (size_t x = 0; x < width; ++x, pixel += 4) {
            if (pixel[3] == 0) continue;
            if (pixel[3] == 255) {
                const uint8_t *out = lut_entry(lut, pixel);
                pixel[0] = out[0];
                pixel[1] = out[1];
                pixel[2] = out[2];
            } else {
                uint8_t colour[3];
                unpremultiply(pixel, colour);
                premultiply(pixel, lut_entry(lut, colour));
            }
        }
    }
}

void profile_apply_direct(uint8_t *rgba, size_t width, size_t height, size_t stride, const profile_program *program) {
    ensure_tables();
    for (size_t y = 0; y < height; ++y) {
        uint8_t *pixel = rgba + y * stride;
        for (size_t x = 0; x < width; ++x, pixel += 4) {
            if (pixel[3] == 0) continue;
            uint8_t colour[3], out[3];
            if (pixel[3] == 255) {
                evaluate_byte(program, pixel, out);
                pixel[0] = out[0];
                pixel[1] = out[1];
                pixel[2] = out[2];
            } else {
                unpremultiply(pixel, colour);
                evaluate_byte(program, colour, out);
                premultiply(pixel, out);
            }
        }
    }
}

#pragma clang attribute pop
