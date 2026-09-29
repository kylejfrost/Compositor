# Compositor's reference implementation, used to generate test fixtures and goldens.
# The table math follows the Adobe DNG SDK 1.7.1 (dng_big_table, dng_reference, dng_color_space,
# dng_spline); it is our own Python, checked against the compiled SDK kernels.
"""Reference application of Camera Raw profile tables (numpy, float64).

Table math is a transliteration of the Adobe DNG SDK 1.7.1 reference code:
  * RefBaselineHueSatMap      (dng_reference.cpp)  -> apply_hue_sat_map
  * RefRGBtoRGBTable3D/1D     (dng_reference.cpp)  -> apply_rgb_table
  * dng_rgb_to_rgb_table_data (dng_big_table.cpp)  -> matrices + gamma choice
  * dng_function_GammaEncode_* / dng_space_*      (dng_color_space.cpp)
  * dng_spline_solver         (dng_spline.cpp)     -> Spline (PV2012 point curves)
Everything the SDK does with 4096-entry 1D tables is done here with the exact
function (difference < 1e-5).

Pipeline composition (order, amount mapping, grayscale, curve space) is NOT in
the SDK; see PIPELINE_NOTES and the spec's "uncertainties" section.
"""
from __future__ import annotations

import math

import numpy as np

import lrprofile as L

# ---------------------------------------------------------------------------
# Color spaces (dng_color_space.cpp). PCS = XYZ D50, xy (0.3457, 0.3585).
# ---------------------------------------------------------------------------

_D50_xy = (0.3457, 0.3585)
PCS_XYZ = np.array([_D50_xy[0] / _D50_xy[1], 1.0, (1 - _D50_xy[0] - _D50_xy[1]) / _D50_xy[1]])

_RAW_TO_PCS = {
    "sRGB": [[0.4361, 0.3851, 0.1431], [0.2225, 0.7169, 0.0606], [0.0139, 0.0971, 0.7141]],
    "AdobeRGB": [[0.6097, 0.2053, 0.1492], [0.3111, 0.6257, 0.0632], [0.0195, 0.0609, 0.7446]],
    "ProPhoto": [[0.7977, 0.1352, 0.0313], [0.2880, 0.7119, 0.0001], [0.0000, 0.0000, 0.8249]],
    "DisplayP3": [[0.5151, 0.2920, 0.1571], [0.2412, 0.6922, 0.0666], [-0.0010, 0.0419, 0.7843]],
    "Rec2020": [[0.6735, 0.1657, 0.1251], [0.2791, 0.6753, 0.0456], [-0.0019, 0.0300, 0.7971]],
}


def matrix_to_pcs(name: str) -> np.ndarray:
    """dng_color_space::SetMatrixToPCS: rows rescaled so RGB white (1,1,1) maps exactly to PCS white."""
    m = np.array(_RAW_TO_PCS[name], dtype=np.float64)
    w1 = m @ np.ones(3)
    s = PCS_XYZ / w1
    return np.diag(s) @ m


def matrix_from_pcs(name: str) -> np.ndarray:
    return np.linalg.inv(matrix_to_pcs(name))


def rgb_to_rgb(src: str, dst: str) -> np.ndarray:
    return matrix_from_pcs(dst) @ matrix_to_pcs(src)


PRIMARIES_SPACE = {0: "sRGB", 1: "AdobeRGB", 2: "ProPhoto", 3: "DisplayP3", 4: "Rec2020"}

# ---------------------------------------------------------------------------
# Transfer functions (dng_color_space.cpp / dng_color_space.h)
# ---------------------------------------------------------------------------


def _spline_segment(x, x0, y0, s0, x1, y1, s1):
    A = x1 - x0
    B = (x - x0) / A
    C = (x1 - x) / A
    return ((y0 * (2.0 - C + B) + (s0 * A * B)) * (C * C)) + ((y1 * (2.0 - B + C) - (s1 * A * C)) * (B * B))


def srgb_encode(x):
    x = np.asarray(x, dtype=np.float64)
    return np.where(x <= 0.0031308, x * 12.92, 1.055 * np.power(np.maximum(x, 0.0031308), 1 / 2.4) - 0.055)


def srgb_decode(y):
    y = np.asarray(y, dtype=np.float64)
    return np.where(y <= 0.0031308 * 12.92, y / 12.92, np.power((np.maximum(y, 0.04045) + 0.055) / 1.055, 2.4))


def _make_toe_gamma(gamma_denom: float, x1: float, y1: float, slope1: float):
    """dng_function_GammaEncode_1_8 / _2_2: pure power with a cubic toe (slope 32 at 0) below x1."""
    g = 1.0 / gamma_denom

    def enc(x):
        x = np.asarray(x, dtype=np.float64)
        toe = _spline_segment(x, 0.0, 0.0, 32.0, x1, y1, slope1)
        return np.where(x <= x1, toe, np.power(np.maximum(x, x1), g))

    # Inverse: exact power above y1; numeric (bisection) inside the toe.
    xs = np.linspace(0.0, x1, 20001)
    ys = _spline_segment(xs, 0.0, 0.0, 32.0, x1, y1, slope1)

    def dec(y):
        y = np.asarray(y, dtype=np.float64)
        toe = np.interp(y, ys, xs)
        return np.where(y < y1, toe, np.power(np.maximum(y, y1), gamma_denom))

    return enc, dec


gamma18_encode, gamma18_decode = _make_toe_gamma(1.8, 8.2118790552e-4, 0.019310851, 13.064306598)
gamma22_encode, gamma22_decode = _make_toe_gamma(2.2, 0.0034800731, 0.0763027458, 9.9661890075)

_R709 = dict(alpha=1.0992968268094429, beta=0.0180539685108078, slope=4.5, gamma=0.45)


def rec709_encode(x):
    x = np.asarray(x, dtype=np.float64)
    a, b, s, g = _R709["alpha"], _R709["beta"], _R709["slope"], _R709["gamma"]
    return np.where(x < b, x * s, a * np.power(np.maximum(x, b), g) - (a - 1))


def rec709_decode(y):
    y = np.asarray(y, dtype=np.float64)
    a, b, s, g = _R709["alpha"], _R709["beta"], _R709["slope"], _R709["gamma"]
    return np.where(y < b * s, y / s, np.power((np.maximum(y, b * s) + (a - 1)) / a, 1 / g))


GAMMA_FUNCS = {
    0: (None, None),
    1: (srgb_encode, srgb_decode),
    2: (gamma18_encode, gamma18_decode),
    3: (gamma22_encode, gamma22_decode),
    4: (rec709_encode, rec709_decode),
}

# ---------------------------------------------------------------------------
# HSV (dng_utils.h DNG_RGBtoHSV / DNG_HSVtoRGB); hue in [0,6)
# ---------------------------------------------------------------------------


def rgb_to_hsv(rgb):
    r, g, b = rgb[:, 0], rgb[:, 1], rgb[:, 2]
    v = np.maximum(r, np.maximum(g, b))
    gap = v - np.minimum(r, np.minimum(g, b))
    h = np.zeros_like(v)
    s = np.zeros_like(v)
    pos = gap > 0
    safe_gap = np.where(pos, gap, 1.0)
    rmax = pos & (r == v)
    gmax = pos & ~rmax & (g == v)
    bmax = pos & ~rmax & ~gmax
    hr = (g - b) / safe_gap
    hr = np.where(hr < 0, hr + 6.0, hr)
    h = np.where(rmax, hr, h)
    h = np.where(gmax, 2.0 + (b - r) / safe_gap, h)
    h = np.where(bmax, 4.0 + (r - g) / safe_gap, h)
    s = np.where(pos, gap / np.where(v > 0, v, 1.0), 0.0)
    return h, s, v


def hsv_to_rgb(h, s, v):
    h = np.fmod(h, 6.0)
    h = np.where(h < 0, h + 6.0, h)
    i = h.astype(np.int64)
    i = np.where(i == 6, 0, i)
    f = h - np.floor(h)  # (h - (real32) i), identical for i in 0..5; i==6 case has f==0
    p = v * (1 - s)
    q = v * (1 - s * f)
    t = v * (1 - s * (1 - f))
    r = np.select([i == 0, i == 1, i == 2, i == 3, i == 4, i == 5], [v, q, p, p, t, v])
    g = np.select([i == 0, i == 1, i == 2, i == 3, i == 4, i == 5], [t, v, v, q, p, p])
    b = np.select([i == 0, i == 1, i == 2, i == 3, i == 4, i == 5], [p, p, t, v, v, q])
    gray = s <= 0
    r = np.where(gray, v, r)
    g = np.where(gray, v, g)
    b = np.where(gray, v, b)
    return np.stack([r, g, b], axis=1)


# ---------------------------------------------------------------------------
# HueSatMap / LookTable
# ---------------------------------------------------------------------------


def look_table_array(t: L.LookTable, amount: float = 1.0) -> np.ndarray:
    """deltas as array [val][hue][sat][3]. Amount scaling (NOT from the SDK, hypothesis H-LA):
    hue*amount, 1+(sat-1)*amount, 1+(val-1)*amount."""
    a = np.array(t.deltas, dtype=np.float64).reshape(t.val_divisions, t.hue_divisions, t.sat_divisions, 3)
    if amount != 1.0:
        a = a.copy()
        a[..., 0] *= amount
        a[..., 1] = 1.0 + (a[..., 1] - 1.0) * amount
        a[..., 2] = 1.0 + (a[..., 2] - 1.0) * amount
    return a


def apply_hue_sat_map(rgb: np.ndarray, t: L.LookTable, amount: float = 1.0) -> np.ndarray:
    """RefBaselineHueSatMap, SDR path (supportOverrange=false). rgb: (N,3) linear ProPhoto in [0,1]."""
    tab = look_table_array(t, amount)
    hd, sd, vd = t.hue_divisions, t.sat_divisions, t.val_divisions
    h, s, v = rgb_to_hsv(rgb)
    has_enc = (t.encoding == 1)
    hScale = 0.0 if hd < 2 else hd / 6.0
    sScale = float(sd - 1)
    vScale = float(vd - 1)
    maxH0, maxS0, maxV0 = hd - 1, sd - 2, vd - 2

    hS = h * hScale
    sS = s * sScale
    h0 = hS.astype(np.int64)
    s0 = np.minimum(sS.astype(np.int64), maxS0)
    h1 = h0 + 1
    wrap = h0 >= maxH0
    h0 = np.where(wrap, maxH0, h0)
    h1 = np.where(wrap, 0, h1)
    hf1 = hS - h0
    sf1 = sS - s0
    hf0 = 1 - hf1
    sf0 = 1 - sf1

    if vd < 2:
        vEnc = v
        e00 = tab[0, h0, s0]
        e01 = tab[0, h1, s0]
        e00b = tab[0, h0, s0 + 1]
        e01b = tab[0, h1, s0 + 1]
        m0 = hf0[:, None] * e00 + hf1[:, None] * e01
        m1 = hf0[:, None] * e00b + hf1[:, None] * e01b
    else:
        vEnc = srgb_encode(np.clip(v, 0, 1)) if has_enc else v
        vS = vEnc * vScale
        v0 = np.minimum(vS.astype(np.int64), maxV0)
        vf1 = vS - v0
        vf0 = 1 - vf1

        def blend(si):
            e00 = tab[v0, h0, si]
            e01 = tab[v0, h1, si]
            e10 = tab[v0 + 1, h0, si]
            e11 = tab[v0 + 1, h1, si]
            return (vf0[:, None] * (hf0[:, None] * e00 + hf1[:, None] * e01) +
                    vf1[:, None] * (hf0[:, None] * e10 + hf1[:, None] * e11))

        m0 = blend(s0)
        m1 = blend(s0 + 1)
    m = sf0[:, None] * m0 + sf1[:, None] * m1
    hueShift, satScale, valScale = m[:, 0], m[:, 1], m[:, 2]
    h = h + hueShift * (6.0 / 360.0)
    s = np.minimum(s * satScale, 1.0)
    vEnc = np.clip(vEnc * valScale, 0.0, 1.0)
    v = srgb_decode(vEnc) if (has_enc and vd >= 2) else vEnc
    return hsv_to_rgb(h, s, v)


# ---------------------------------------------------------------------------
# RGB table
# ---------------------------------------------------------------------------


def rgb_table_array(t: L.RGBTable) -> np.ndarray:
    """samples as float array [r][g][b][3] in 0..1 (uint16/65535)."""
    d = t.divisions
    a = np.array(t.samples, dtype=np.float64) / 65535.0
    if t.dimensions == 3:
        return a.reshape(d, d, d, 3)
    return a.reshape(d, 3)


def tetrahedral(table: np.ndarray, rgb: np.ndarray) -> np.ndarray:
    """RefRGBtoRGBTable3D interpolation (identical tetrahedron selection and weights)."""
    d = table.shape[0]
    scale = d - 1
    maxI = d - 2
    S = rgb * scale
    idx = np.minimum(S.astype(np.int64), maxI)
    f = S - idx
    rF, gF, bF = f[:, 0], f[:, 1], f[:, 2]
    ri, gi, bi = idx[:, 0], idx[:, 1], idx[:, 2]
    O001 = np.array([0, 0, 1])
    O010 = np.array([0, 1, 0])
    O100 = np.array([1, 0, 0])
    O011, O101, O110 = O010 + O001, O100 + O001, O100 + O010
    n = rgb.shape[0]
    off1 = np.zeros((n, 3), np.int64)
    off2 = np.zeros((n, 3), np.int64)
    f1 = np.zeros(n)
    f2 = np.zeros(n)
    f3 = np.zeros(n)
    c_g_ge_r = gF >= rF
    cases = [
        (c_g_ge_r & (bF >= gF), O001, O011, bF, gF, rF),
        (c_g_ge_r & ~(bF >= gF) & (bF >= rF), O010, O011, gF, bF, rF),
        (c_g_ge_r & ~(bF >= gF) & ~(bF >= rF), O010, O110, gF, rF, bF),
        (~c_g_ge_r & (bF >= rF), O001, O101, bF, rF, gF),
        (~c_g_ge_r & ~(bF >= rF) & (bF >= gF), O100, O101, rF, bF, gF),
        (~c_g_ge_r & ~(bF >= rF) & ~(bF >= gF), O100, O110, rF, gF, bF),
    ]
    for mask, o1, o2, a, b, c in cases:
        off1[mask] = o1
        off2[mask] = o2
        f1[mask] = a[mask]
        f2[mask] = b[mask]
        f3[mask] = c[mask]
    w0 = 1 - f1
    w1 = f1 - f2
    w2 = f2 - f3
    base = np.stack([ri, gi, bi], 1)
    T = lambda o: table[base[:, 0] + o[:, 0], base[:, 1] + o[:, 1], base[:, 2] + o[:, 2]]
    ones = np.ones((n, 3), np.int64)
    return (w0[:, None] * T(np.zeros((n, 3), np.int64)) + w1[:, None] * T(off1) +
            w2[:, None] * T(off2) + f3[:, None] * T(ones))


def apply_rgb_table(rgb_pp: np.ndarray, t: L.RGBTable, amount: float = 1.0) -> np.ndarray:
    """RefRGBtoRGBTable3D/1D, SDR path (supportOverrange=false). rgb_pp: (N,3) linear ProPhoto."""
    space = PRIMARIES_SPACE[t.primaries]
    has_matrix = space != "ProPhoto"
    enc, dec = GAMMA_FUNCS[t.gamma]
    x = rgb_pp
    src = rgb_pp.copy()
    delta = np.zeros_like(x)
    if has_matrix:
        E = rgb_to_rgb("ProPhoto", space)
        xx = x @ E.T
        x = np.clip(xx, 0, 1)
        if t.gamut == 1:
            delta = xx - x
    else:
        x = np.clip(x, 0, 1)  # SDK assumes [0,1] here (1D table lookup would throw otherwise)
    if t.dimensions == 3:
        if enc is not None:
            x = enc(x)
        y = tetrahedral(rgb_table_array(t), x)
        if amount != 1.0:
            y = np.clip(x + amount * (y - x), 0, 1)
        if dec is not None:
            y = dec(y)
    else:
        # 1D: per-plane dng_1d_table of  inverse(gamma) o (x + amount*(table(x)-x)) o gamma
        tab = rgb_table_array(t)
        d = t.divisions
        xe = enc(x) if enc is not None else x
        sc = xe * (d - 1)
        i = np.clip(sc.astype(np.int64), 0, d - 2)
        fr = sc - i
        cols = np.arange(3)[None, :]
        yv = (1 - fr) * tab[i, cols] + fr * tab[i + 1, cols]
        yv = xe + amount * (yv - xe)
        y = dec(yv) if dec is not None else yv
    if has_matrix:
        y = y + delta
        D = rgb_to_rgb(space, "ProPhoto")
        y = np.clip(y @ D.T, 0, 1)
    return y


# ---------------------------------------------------------------------------
# PV2012 point curve (dng_spline_solver) -- applied per channel in ProPhoto primaries
# with sRGB TRC ("Melissa RGB") encoding (hypothesis H-TC).
# ---------------------------------------------------------------------------


class Spline:
    def __init__(self, pts):
        self.X = [p[0] for p in pts]
        self.Y = [p[1] for p in pts]
        self.S = self._solve()

    def _solve(self):
        X, Y = self.X, self.Y
        count = len(X)
        start, end = 0, count
        A = X[start + 1] - X[start]
        B = (Y[start + 1] - Y[start]) / A
        S = [0.0] * count
        S[start] = B
        for j in range(start + 2, end):
            C = X[j] - X[j - 1]
            D = (Y[j] - Y[j - 1]) / C
            S[j - 1] = (B * C + D * A) / (A + C)
            A, B = C, D
        S[end - 1] = 2.0 * B - S[end - 2]
        S[start] = 2.0 * S[start] - S[start + 1]
        if end - start > 2:
            E = [0.0] * count
            F = [0.0] * count
            G = [0.0] * count
            F[start] = 0.5
            E[end - 1] = 0.5
            G[start] = 0.75 * (S[start] + S[start + 1])
            G[end - 1] = 0.75 * (S[end - 2] + S[end - 1])
            for j in range(start + 1, end - 1):
                A = (X[j + 1] - X[j - 1]) * 2.0
                E[j] = (X[j + 1] - X[j]) / A
                F[j] = (X[j] - X[j - 1]) / A
                G[j] = 1.5 * S[j]
            for j in range(start + 1, end):
                A = 1.0 - F[j - 1] * E[j]
                if j != end - 1:
                    F[j] /= A
                G[j] = (G[j] - G[j - 1] * E[j]) / A
            for j in range(end - 2, start - 1, -1):
                G[j] = G[j] - F[j] * G[j + 1]
            S = G[:]
        return S

    def __call__(self, x):
        x = np.asarray(x, dtype=np.float64)
        X, Y, S = np.array(self.X), np.array(self.Y), np.array(self.S)
        j = np.clip(np.searchsorted(X, x, side="left"), 1, len(X) - 1)
        y = _spline_segment(x, X[j - 1], Y[j - 1], S[j - 1], X[j], Y[j], S[j])
        y = np.where(x <= X[0], Y[0], y)
        y = np.where(x >= X[-1], Y[-1], y)
        return y


def curve_from_points(pts):
    if pts is None:
        return None
    pts = [(a / 255.0, b / 255.0) for a, b in pts]
    if pts == [(0.0, 0.0), (1.0, 1.0)]:
        return None
    return Spline(pts)


def apply_point_curves(rgb_pp: np.ndarray, props: dict) -> np.ndarray:
    master = curve_from_points(L.tone_curve_points(props, "crs:ToneCurvePV2012"))
    chans = [curve_from_points(L.tone_curve_points(props, "crs:ToneCurvePV2012" + c)) for c in ("Red", "Green", "Blue")]
    if master is None and all(c is None for c in chans):
        return rgb_pp
    e = srgb_encode(np.clip(rgb_pp, 0, 1))
    if master is not None:
        e = master(e)
    for i, c in enumerate(chans):
        if c is not None:
            e[:, i] = c(e[:, i])
    return srgb_decode(np.clip(e, 0, 1))


# ---------------------------------------------------------------------------
# Full reference pipeline (v1)
# ---------------------------------------------------------------------------

PROPHOTO_Y = matrix_to_pcs("ProPhoto")[1]

IMPLEMENTED_SETTINGS = {
    "crs:ToneCurvePV2012", "crs:ToneCurvePV2012Red", "crs:ToneCurvePV2012Green", "crs:ToneCurvePV2012Blue",
    "crs:ConvertToGrayscale", "crs:RGBTableAmount",
}
METADATA_KEYS = {
    "crs:PresetType", "crs:Cluster", "crs:UUID", "crs:SupportsAmount", "crs:SupportsColor", "crs:SupportsMonochrome",
    "crs:SupportsHighDynamicRange", "crs:SupportsNormalDynamicRange", "crs:SupportsSceneReferred",
    "crs:SupportsOutputReferred", "crs:RequiresRGBTables", "crs:CameraModelRestriction", "crs:Copyright",
    "crs:ContactInfo", "crs:Version", "crs:ProcessVersion", "crs:HasSettings", "crs:Name", "crs:ShortName",
    "crs:SortName", "crs:Group", "crs:Description", "crs:LookTable", "crs:RGBTable", "crs:ShowInPresets",
    "crs:ShowInQuickActions", "crs:CameraProfile", "crs:CompatibleVersion",
}


def neutral_value(key: str, value) -> bool:
    """True if a develop setting present in the profile has no effect (so ignoring it is exact)."""
    if not isinstance(value, str):
        return False
    if key.startswith("crs:GrayMixer") or key.startswith(("crs:HueAdjustment", "crs:SaturationAdjustment",
                                                          "crs:LuminanceAdjustment")):
        return float(value) == 0
    if key in ("crs:ParametricShadowSplit", "crs:ParametricMidtoneSplit", "crs:ParametricHighlightSplit",
               "crs:ColorGradeBlending", "crs:SplitToningBalance", "crs:CurveRefineSaturation",
               "crs:PostCropVignetteMidpoint", "crs:PostCropVignetteFeather", "crs:PostCropVignetteRoundness",
               "crs:PostCropVignetteStyle", "crs:PostCropVignetteHighlightContrast"):
        return True  # only meaningful together with a non-zero companion setting
    if key.startswith("crs:SplitToning") and key.endswith("Hue"):
        return True
    if key.startswith("crs:ColorGrade") and key.endswith("Hue"):
        return True
    try:
        return float(value) == 0
    except ValueError:
        return False


def unapplied_settings(props: dict) -> list[str]:
    out = []
    for k, v in props.items():
        if k in METADATA_KEYS or k in IMPLEMENTED_SETTINGS or k.startswith("crs:Table_"):
            continue
        if neutral_value(k, v):
            continue
        out.append(f"{k[4:]}={v if isinstance(v, str) else '<struct>'}")
    return out


def is_true(value) -> bool:
    """XMP booleans, compared without regard to case ("True", "true")."""
    return isinstance(value, str) and value.lower() == "true"


def pin_amount(a, lo, hi):
    """dng_*_table::SetAmount: Round_int32(a*100) * 0.01, pinned to [lo, hi]."""
    y = a * 100.0
    r = math.trunc(y + 0.5) if y > 0 else math.trunc(y - 0.5)
    return min(max(r * 0.01, lo), hi)


def profile_amounts(p, amount, fixed_look="full"):          # amount: 1.0 == 100 %
    """Map the UI Amount (1.0 == 100 %) to per-table amounts. Hypothesis H-AM:
    look = pin(A, look.min, look.max); rgb = pin(RGBTableAmount * A, rgb.min, rgb.max);
    SupportsAmount == False forces A = 1. A fixed look table (min == max == 1) follows `fixed_look`
    (hypothesis U1): "full" -> 1, "scaled" -> pin(A, 0, 1), "skipped" -> None (stage not run)."""
    if not is_true(p.get("SupportsAmount", "False")):
        amount = 1.0
    look_amt = rgb_amt = None
    if p.look_table:
        t = p.look_table.table
        if t.min_amount == 1.0 and t.max_amount == 1.0:
            look_amt = {"full": 1.0, "scaled": pin_amount(amount, 0.0, 1.0), "skipped": None}[fixed_look]
        else:
            look_amt = pin_amount(amount, t.min_amount, t.max_amount)
    if p.rgb_table:
        t = p.rgb_table.table
        k = float(p.get("RGBTableAmount", "1") or 1)
        rgb_amt = pin_amount(k * amount, t.min_amount, t.max_amount)
    return look_amt, rgb_amt


def render_srgb8(img8: np.ndarray, p: L.Profile, amount: float = 1.0, *, use_look=True, use_rgb=True,
                 use_curves=True, use_gray=True, fixed_look="full"):
    """img8: (H,W,3) uint8 sRGB. Returns (float sRGB-encoded (H,W,3) in [0,1], uint8, info)."""
    Hh, Ww, _ = img8.shape
    x = img8.reshape(-1, 3).astype(np.float64) / 255.0
    lin = srgb_decode(x)
    pp = np.clip(lin @ rgb_to_rgb("sRGB", "ProPhoto").T, 0, 1)
    look_amt, rgb_amt = profile_amounts(p, amount, fixed_look)
    if use_look and p.look_table is not None and look_amt is not None:
        pp = apply_hue_sat_map(pp, p.look_table.table, look_amt)
    if use_curves:
        pp = apply_point_curves(pp, p.props)
    if use_gray and is_true(p.get("ConvertToGrayscale")):
        y = np.clip(pp @ PROPHOTO_Y, 0, 1)
        pp = np.stack([y, y, y], 1)
    if use_rgb and p.rgb_table is not None:
        pp = apply_rgb_table(pp, p.rgb_table.table, rgb_amt)
    out_lin = np.clip(pp @ rgb_to_rgb("ProPhoto", "sRGB").T, 0, 1)
    out = srgb_encode(out_lin)
    out8 = np.clip(np.floor(out * 255.0 + 0.5), 0, 255).astype(np.uint8)
    info = dict(look_amount=look_amt if (use_look and p.look_table is not None) else None,
                rgb_amount=rgb_amt if (use_rgb and p.rgb_table is not None) else None,
                unapplied=unapplied_settings(p.props))
    return out.reshape(Hh, Ww, 3), out8.reshape(Hh, Ww, 3), info
