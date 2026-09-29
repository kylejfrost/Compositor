# Compositor's reference implementation, used to generate test fixtures and goldens.
# The table math follows the Adobe DNG SDK 1.7.1 (dng_big_table, dng_reference, dng_color_space,
# dng_spline); it is our own Python, checked against the compiled SDK kernels.
"""Reference decoder for Adobe Camera Raw / Lightroom profile (.xmp "Look") files.

Stdlib-only for parsing/decoding. Rendering helpers live in lrapply.py (numpy).

Ground truth: Adobe DNG SDK 1.7.1, dng_big_table.cpp / dng_big_table.h
(ASCIItoBinary, DecodeFromBinary, dng_look_table::GetStream,
dng_rgb_table::GetStream, ComputeFingerprint).
"""
from __future__ import annotations

import hashlib
import struct
import xml.etree.ElementTree as ET
import zlib
from dataclasses import dataclass, field
from typing import Any

NS = {
    "x": "adobe:ns:meta/",
    "rdf": "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
    "crs": "http://ns.adobe.com/camera-raw-settings/1.0/",
    "xml": "http://www.w3.org/XML/1998/namespace",
}
RDF = "{%s}" % NS["rdf"]
CRS = "{%s}" % NS["crs"]
XML_LANG = "{%s}lang" % NS["xml"]

# --------------------------------------------------------------------------
# ASCII-85 variant (dng_big_table::EncodeAsString / ASCIItoBinary)
# --------------------------------------------------------------------------

ENCODE_ALPHABET = (
    "0123456789"
    "abcdefghij"
    "klmnopqrst"
    "uvwxyzABCD"
    "EFGHIJKLMN"
    "OPQRSTUVWX"
    "YZ.-:+=^!/"
    "*?`'|()[]{"
    "}@%$#"
)
assert len(ENCODE_ALPHABET) == 85 and len(set(ENCODE_ALPHABET)) == 85
DECODE_MAP = {c: i for i, c in enumerate(ENCODE_ALPHABET)}


def a85_decode(s: str) -> bytes:
    """Decode Adobe's big-table text encoding.

    * Characters not in the alphabet (whitespace, newlines, anything else) are skipped.
    * Each group of 5 digits d0..d4 forms v = d0 + d1*85 + d2*85^2 + d3*85^3 + d4*85^4
      (first char is least significant) and is written as 4 bytes little endian.
    * A trailing partial group of k digits (k = 2..4) yields k-1 bytes (the low bytes of v).
      A trailing single digit yields nothing.
    """
    out = bytearray()
    phase = 0
    value = 0
    mul = (1, 85, 85 ** 2, 85 ** 3, 85 ** 4)
    for ch in s:
        d = DECODE_MAP.get(ch)
        if d is None:
            continue
        value += d * mul[phase]
        phase += 1
        if phase == 5:
            out += struct.pack("<I", value & 0xFFFFFFFF)
            phase = 0
            value = 0
    if phase > 1:
        out += struct.pack("<I", value & 0xFFFFFFFF)[: phase - 1]
    return bytes(out)


def a85_encode(b: bytes) -> str:
    """Inverse of a85_decode, byte-exact with dng_big_table::EncodeAsString."""
    out = []
    n = len(b)
    padded = b + b"\0\0\0"
    i = 0
    while n:
        x0 = struct.unpack_from("<I", padded, i)[0]
        i += 4
        x1 = x0 // 85
        out.append(ENCODE_ALPHABET[x0 - x1 * 85])
        x2 = x1 // 85
        out.append(ENCODE_ALPHABET[x1 - x2 * 85])
        n -= 1
        if not n:
            break
        x3 = x2 // 85
        out.append(ENCODE_ALPHABET[x2 - x3 * 85])
        n -= 1
        if not n:
            break
        x4 = x3 // 85
        out.append(ENCODE_ALPHABET[x3 - x4 * 85])
        n -= 1
        if not n:
            break
        out.append(ENCODE_ALPHABET[x4])
        n -= 1
    return "".join(out)


def decompress_block(blob: bytes) -> bytes:
    """[u32 LE uncompressedSize][zlib stream (RFC1950, compress2 Z_DEFAULT_COMPRESSION)]"""
    if len(blob) < 5:
        raise ValueError("compressed block too short")
    (usize,) = struct.unpack_from("<I", blob, 0)
    raw = zlib.decompress(blob[4:])
    if len(raw) != usize:
        raise ValueError(f"uncompressed size mismatch: header {usize} != {len(raw)}")
    return raw


# --------------------------------------------------------------------------
# Big table payloads
# --------------------------------------------------------------------------

BTT_LOOK = 0
BTT_RGB = 1
BTT_NAMES = {0: "LookTable", 1: "RGBTable", 2: "ImageTable", 3: "CompressedSettingsTable",
             4: "UncompressedSettingsTable", 5: "PackedImageTable"}

ENCODING_NAMES = {0: "Linear", 1: "sRGB"}
PRIMARIES_NAMES = {0: "sRGB", 1: "AdobeRGB", 2: "ProPhoto", 3: "DisplayP3", 4: "Rec2020"}
GAMMA_NAMES = {0: "Linear", 1: "sRGB", 2: "Gamma1.8", 3: "Gamma2.2", 4: "Rec2020(Rec709 OETF)"}
GAMUT_NAMES = {0: "clip", 1: "extend"}


@dataclass
class LookTable:
    version: int
    hue_divisions: int
    sat_divisions: int
    val_divisions: int
    # deltas[v][h][s] = (hueShiftDegrees, satScale, valScale)
    deltas: list  # flat list of (h,s,v) tuples in file order: v outer, h, s inner
    encoding: int
    min_amount: float
    max_amount: float
    flags: int | None
    monochrome: bool

    def entry(self, v: int, h: int, s: int):
        return self.deltas[(v * self.hue_divisions + h) * self.sat_divisions + s]


@dataclass
class RGBTable:
    version: int
    dimensions: int
    divisions: int
    # samples: flat list of (r,g,b) uint16 absolute values (delta + nop) in file order
    # 3D: r outer, g, b inner.  1D: index.
    samples: list
    primaries: int
    gamma: int
    gamut: int
    min_amount: float
    max_amount: float
    flags: int | None
    monochrome: bool


def nop_values(divisions: int) -> list[int]:
    return [((i * 0xFFFF + (divisions >> 1)) // (divisions - 1)) & 0xFFFF for i in range(divisions)]


def parse_look_table(raw: bytes) -> LookTable:
    off = 0

    def u32():
        nonlocal off
        v = struct.unpack_from("<I", raw, off)[0]
        off += 4
        return v

    btt = u32()
    if btt != BTT_LOOK:
        raise ValueError(f"not a look table (type {btt})")
    version = u32()
    if version not in (1, 2):
        raise ValueError(f"unknown look table version {version}")
    hd, sd, vd = u32(), u32(), u32()
    if not (1 <= hd <= 360 and 1 <= sd <= 256 and 1 <= vd <= 256 and hd * sd * vd <= 36 * 32 * 16):
        raise ValueError("bad divisions")
    n = hd * sd * vd
    vals = struct.unpack_from("<%df" % (3 * n), raw, off)
    off += 12 * n
    deltas = [tuple(vals[3 * i: 3 * i + 3]) for i in range(n)]
    encoding = u32()
    if encoding not in (0, 1):
        raise ValueError(f"unknown encoding {encoding}")
    if version != 1:
        mn, mx = struct.unpack_from("<dd", raw, off)
        off += 16
    else:
        mn = mx = 1.0
    flags = None
    if off + 4 <= len(raw):
        flags = u32()
    if off != len(raw):
        raise ValueError(f"trailing bytes in look table: {len(raw) - off}")
    mono = all(d[1] == 0.0 for d in deltas)
    return LookTable(version, hd, sd, vd, deltas, encoding, mn, mx, flags, mono)


def parse_rgb_table(raw: bytes) -> RGBTable:
    off = 0

    def u32():
        nonlocal off
        v = struct.unpack_from("<I", raw, off)[0]
        off += 4
        return v

    btt = u32()
    if btt != BTT_RGB:
        raise ValueError(f"not an RGB table (type {btt})")
    version = u32()
    if version != 1:
        raise ValueError(f"unknown RGB table version {version}")
    dims = u32()
    div = u32()
    if dims == 1:
        if not (2 <= div <= 4096):
            raise ValueError("bad 1D divisions")
        count = div
    elif dims == 3:
        if not (2 <= div <= 32):
            raise ValueError("bad 3D divisions")
        count = div ** 3
    else:
        raise ValueError(f"bad dimensions {dims}")
    nop = nop_values(div)
    raw16 = struct.unpack_from("<%dH" % (3 * count), raw, off)
    off += 6 * count
    samples = []
    if dims == 1:
        for i in range(div):
            samples.append(tuple((raw16[3 * i + c] + nop[i]) & 0xFFFF for c in range(3)))
    else:
        i = 0
        for ri in range(div):
            for gi in range(div):
                for bi in range(div):
                    samples.append(((raw16[i] + nop[ri]) & 0xFFFF,
                                    (raw16[i + 1] + nop[gi]) & 0xFFFF,
                                    (raw16[i + 2] + nop[bi]) & 0xFFFF))
                    i += 3
    primaries, gamma, gamut = u32(), u32(), u32()
    if primaries > 4 or gamma > 4 or gamut > 1:
        raise ValueError("bad enum")
    mn, mx = struct.unpack_from("<dd", raw, off)
    off += 16
    flags = None
    if off + 4 <= len(raw):
        flags = u32()
    if off != len(raw):
        raise ValueError(f"trailing bytes in RGB table: {len(raw) - off}")
    mono = (primaries == 2 or gamut == 0) and dims == 3 and all(a == b == c for a, b, c in samples)
    # NB: SDK ComputeMonochrome: returns false if (primaries != ProPhoto && gamut != clip)
    return RGBTable(version, dims, div, samples, primaries, gamma, gamut, mn, mx, flags, mono)


def serialize_look_table(t: LookTable) -> bytes:
    """dng_look_table::PutStream (little endian)."""
    version = 1 if (t.min_amount == 1.0 and t.max_amount == 1.0) else 2
    out = struct.pack("<5I", BTT_LOOK, version, t.hue_divisions, t.sat_divisions, t.val_divisions)
    for d in t.deltas:
        out += struct.pack("<3f", *d)
    out += struct.pack("<I", t.encoding)
    if version != 1:
        out += struct.pack("<dd", t.min_amount, t.max_amount)
    if t.flags:
        out += struct.pack("<I", t.flags)
    return out


def serialize_rgb_table(t: RGBTable) -> bytes:
    """dng_rgb_table::PutStream (little endian)."""
    out = struct.pack("<4I", BTT_RGB, 1, t.dimensions, t.divisions)
    nop = nop_values(t.divisions)
    parts = []
    if t.dimensions == 1:
        for i, (r, g, b) in enumerate(t.samples):
            parts.append(struct.pack("<3H", (r - nop[i]) & 0xFFFF, (g - nop[i]) & 0xFFFF, (b - nop[i]) & 0xFFFF))
    else:
        d = t.divisions
        i = 0
        for ri in range(d):
            for gi in range(d):
                for bi in range(d):
                    r, g, b = t.samples[i]
                    parts.append(struct.pack("<3H", (r - nop[ri]) & 0xFFFF, (g - nop[gi]) & 0xFFFF,
                                             (b - nop[bi]) & 0xFFFF))
                    i += 1
    out += b"".join(parts)
    out += struct.pack("<3I", t.primaries, t.gamma, t.gamut)
    out += struct.pack("<dd", t.min_amount, t.max_amount)
    if t.flags:
        out += struct.pack("<I", t.flags)
    return out


@dataclass
class DecodedTable:
    md5_attr: str
    encoded_len: int
    compressed: bytes
    raw: bytes
    kind: int
    table: Any
    md5_raw: str
    md5_reserialized: str

    @property
    def md5_ok(self) -> bool:
        return self.md5_attr.upper() == self.md5_raw.upper()


def decode_table_string(md5_attr: str, text: str) -> DecodedTable:
    comp = a85_decode(text)
    raw = decompress_block(comp)
    (kind,) = struct.unpack_from("<I", raw, 0)
    if kind == BTT_LOOK:
        t = parse_look_table(raw)
        re = serialize_look_table(t)
    elif kind == BTT_RGB:
        t = parse_rgb_table(raw)
        re = serialize_rgb_table(t)
    else:
        t = None
        re = raw
    return DecodedTable(md5_attr, len(text), comp, raw, kind, t,
                        hashlib.md5(raw).hexdigest().upper(), hashlib.md5(re).hexdigest().upper())


# --------------------------------------------------------------------------
# XMP parsing (generic rdf -> python)
# --------------------------------------------------------------------------

def _qname(tag: str) -> str:
    for p, uri in NS.items():
        pre = "{%s}" % uri
        if tag.startswith(pre):
            return f"{p}:{tag[len(pre):]}"
    return tag


def _node_value(el: ET.Element):
    """Convert a property element to a python value."""
    # attributes-as-struct fields (rdf:parseType Resource or shorthand)
    children = list(el)
    if el.get(RDF + "parseType") == "Resource":
        return _struct_from(el)
    if not children:
        attrs = {_qname(k): v for k, v in el.attrib.items() if not k.startswith(RDF) and k != XML_LANG}
        if attrs:
            return attrs
        return el.text or ""
    c = children[0]
    tag = _qname(c.tag)
    if tag == "rdf:Alt":
        return {"__alt__": {li.get(XML_LANG, ""): (li.text or "") for li in c.findall(RDF + "li")}}
    if tag in ("rdf:Seq", "rdf:Bag"):
        items = []
        for li in c.findall(RDF + "li"):
            if len(li) or li.get(RDF + "parseType") == "Resource":
                if li.get(RDF + "parseType") == "Resource":
                    items.append(_struct_from(li))
                else:
                    items.append(_node_value(li) if _qname(li[0].tag) != "rdf:Description" else _struct_from(li[0]))
            else:
                items.append(li.text or "")
        return {"__" + tag[4:].lower() + "__": items}
    if tag == "rdf:Description":
        return _struct_from(c)
    return _struct_from(el)


def _struct_from(el: ET.Element) -> dict:
    d = {}
    for k, v in el.attrib.items():
        q = _qname(k)
        if q.startswith("rdf:") or k == XML_LANG:
            continue
        d[q] = v
    for c in el:
        d[_qname(c.tag)] = _node_value(c)
    return d


def parse_xmp(path_or_text: str, is_text: bool = False) -> dict:
    """Returns the crs properties of the (first) top-level rdf:Description as a flat dict
    keyed by 'crs:Name' etc. Simple values are strings; rdf:Alt -> {'__alt__': {lang: text}};
    rdf:Seq -> {'__seq__': [...]}; structs -> nested dict."""
    if is_text:
        root = ET.fromstring(path_or_text)
    else:
        root = ET.parse(path_or_text).getroot()
    out: dict = {}
    for desc in root.iter(RDF + "Description"):
        # Only top-level descriptions (children of rdf:RDF)
        out.update(_struct_from(desc))
        break
    return out


@dataclass
class Profile:
    path: str
    props: dict
    look_table: DecodedTable | None = None
    rgb_table: DecodedTable | None = None
    other_tables: dict = field(default_factory=dict)

    def get(self, key, default=None):
        return self.props.get("crs:" + key, default)

    def name(self, lang: str = "x-default") -> str:
        n = self.props.get("crs:Name")
        if isinstance(n, dict) and "__alt__" in n:
            return n["__alt__"].get(lang) or n["__alt__"].get("x-default", "")
        return n or ""


def load_profile(path: str) -> Profile:
    props = parse_xmp(path)
    p = Profile(path, props)
    lt = props.get("crs:LookTable")
    if isinstance(lt, str) and lt:
        p.look_table = decode_table_string(lt, props["crs:Table_" + lt])
    rt = props.get("crs:RGBTable")
    if isinstance(rt, str) and rt:
        p.rgb_table = decode_table_string(rt, props["crs:Table_" + rt])
    return p


def tone_curve_points(props: dict, key: str = "crs:ToneCurvePV2012"):
    v = props.get(key)
    if not isinstance(v, dict) or "__seq__" not in v:
        return None
    pts = []
    for s in v["__seq__"]:
        a, b = s.split(",")
        pts.append((int(a.strip()), int(b.strip())))
    return pts
