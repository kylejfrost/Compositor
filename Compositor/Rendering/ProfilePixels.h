#ifndef ProfilePixels_h
#define ProfilePixels_h
#include <stdint.h>
#include <stddef.h>
// Lightroom and Camera Raw profiles on 8-bit sRGB pixels. One straight colour goes: exact sRGB decode →
// linear ProPhoto (clamped) → LookTable → point curves → grayscale → RGBTable → sRGB encode. Each table stage
// follows the DNG SDK 1.7.1 reference (RefBaselineHueSatMap, RefRGBtoRGBTable3D/1D); transfer functions are
// 4097-entry tables over [0, 1], as the SDK's are.
#define PROFILE_CURVE_SAMPLES 4097
typedef struct {
    double sRGBToProPhoto[9], proPhotoToSRGB[9];           // row-major
    uint32_t hueDivisions, saturationDivisions, valueDivisions; // hueDivisions == 0: no look stage
    int32_t lookEncoding;                                  // 0 linear V, 1 sRGB-encoded V
    const float *look;                                     // ((v*H+h)*S+s)*3, deltas ALREADY scaled by the look amount
    int32_t curveMask;                                     // bit 0 master, 1 red, 2 green, 3 blue; 0: no curve stage
    const float *curves;                                   // 4 * PROFILE_CURVE_SAMPLES (master, red, green, blue); sample i = f(i/4096)
    int32_t grayscale;                                     // nonzero: Y = dot(grayWeights, rgb) clamped, output (Y,Y,Y)
    double grayWeights[3];
    uint32_t rgbDimensions, rgbDivisions;                  // rgbDivisions == 0: no RGB stage
    int32_t rgbPrimaries, rgbGamma, rgbGamut;              // RGBTable raw values; primaries 2 = ProPhoto (no matrix)
    const float *rgb;                                      // samples / 65535; 3D ((r*D+g)*D+b)*3, 1D i*3
    double rgbAmount;
    double proPhotoToTable[9], tableToProPhoto[9];
} profile_program;
// Encoded sRGB 0–1 in (decoded exactly) → encoded sRGB 0–1 out, clamped, unrounded.
void profile_evaluate(const profile_program *program, const double srgb[3], double out[3]);
// One sRGB byte triple through the pipeline; the result is rounded to the nearest byte.
void profile_evaluate_byte(const profile_program *program, const uint8_t in[3], uint8_t out[3]);
// Fills red planes [firstRed, firstRed + redCount) of a 256³ × 3 table: lut[((r*256+g)*256+b)*3+c].
void profile_bake_lut(const profile_program *program, int firstRed, int redCount, uint8_t *lut);
// Premultiplied RGBA pixels (4 bytes each, `stride` bytes per row) in place, through a baked table or by evaluating
// each pixel. Transparent pixels are skipped, opaque ones are used as they are, and the others are unpremultiplied
// to bytes and premultiplied again, so both give identical bytes. Alpha is kept.
void profile_apply_lut(uint8_t *rgba, size_t width, size_t height, size_t stride, const uint8_t *lut);
void profile_apply_direct(uint8_t *rgba, size_t width, size_t height, size_t stride, const profile_program *program);
// Single stages on linear ProPhoto in place, for tests; a stage the program doesn't run leaves rgb alone.
void profile_hue_sat_map(const profile_program *program, double rgb[3]);
void profile_rgb_table(const profile_program *program, double rgb[3]);
// Transfer functions: 0 linear, 1 sRGB, 2 γ1.8, 3 γ2.2, 4 Rec. 709; table-interpolated, input clamped to [0, 1].
double profile_transfer_encode(int32_t gamma, double x);
double profile_transfer_decode(int32_t gamma, double y);
#endif
