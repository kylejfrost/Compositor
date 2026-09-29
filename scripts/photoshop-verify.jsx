// Photoshop verification harness (ExtendScript, ES3). Run through scripts/photoshop-verify.sh:
//   do javascript file "…/photoshop-verify.jsx" with arguments {"<in.psd>", "<out-dir>", "hashed" | "raw"}
//
// Opens <in.psd>, walks every layer (kind, name, bounds, text, locks, blend, opacity, fill opacity, clipping,
// visibility, effects) and the guides, exports <out-dir>/<name>.opened.png, re-typesets every text layer and
// exports <name>.retypeset.png, closes the document without saving and writes <out-dir>/<name>.verify.json.
// Returns "ok <json>" or "failed <json>: <first error>".
//
// Privacy: layer names, text, the document name and the file's name are client data, so the report holds their
// SHA-256 (`name_sha256`, `contents_sha256`, `file_sha256`), hashed exactly as scripts/psd-verify.py does, and
// error messages have them replaced by "#" and the hash's first 12 hex digits. "raw" also stores the strings.
//
// Safety: it never saves or closes a document it did not open (an input that is already open is refused), and
// it restores the active document, displayDialogs, rulerUnits and typeUnits when it finishes.

var SHA256_K = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
];

// UTF-8 bytes of a UTF-16 string; a lone surrogate becomes its 3-byte form (Python's "surrogatepass").
function utf8Bytes(text) {
    var bytes = [];
    for (var i = 0; i < text.length; i++) {
        var code = text.charCodeAt(i);
        if (code >= 0xD800 && code <= 0xDBFF && i + 1 < text.length) {
            var low = text.charCodeAt(i + 1);
            if (low >= 0xDC00 && low <= 0xDFFF) {
                code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00);
                i++;
            }
        }
        if (code < 0x80) {
            bytes.push(code);
        } else if (code < 0x800) {
            bytes.push(0xC0 | (code >> 6), 0x80 | (code & 0x3F));
        } else if (code < 0x10000) {
            bytes.push(0xE0 | (code >> 12), 0x80 | ((code >> 6) & 0x3F), 0x80 | (code & 0x3F));
        } else {
            bytes.push(0xF0 | (code >> 18), 0x80 | ((code >> 12) & 0x3F), 0x80 | ((code >> 6) & 0x3F),
                0x80 | (code & 0x3F));
        }
    }
    return bytes;
}

function rotateRight(value, count) {
    return (value >>> count) | (value << (32 - count));
}

// SHA-256 (FIPS 180-4) of the string's UTF-8 bytes, as 64 lowercase hex digits.
function sha256Hex(text) {
    var bytes = utf8Bytes(String(text));
    var bitLength = bytes.length * 8;
    bytes.push(0x80);
    while (bytes.length % 64 != 56) {
        bytes.push(0);
    }
    var high = Math.floor(bitLength / 0x100000000);
    var low = bitLength >>> 0;
    bytes.push((high >>> 24) & 0xFF, (high >>> 16) & 0xFF, (high >>> 8) & 0xFF, high & 0xFF,
        (low >>> 24) & 0xFF, (low >>> 16) & 0xFF, (low >>> 8) & 0xFF, low & 0xFF);
    var hash = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    var w = [];
    for (var block = 0; block < bytes.length; block += 64) {
        var t;
        for (t = 0; t < 16; t++) {
            var at = block + t * 4;
            w[t] = (bytes[at] << 24) | (bytes[at + 1] << 16) | (bytes[at + 2] << 8) | bytes[at + 3];
        }
        for (t = 16; t < 64; t++) {
            var s0 = rotateRight(w[t - 15], 7) ^ rotateRight(w[t - 15], 18) ^ (w[t - 15] >>> 3);
            var s1 = rotateRight(w[t - 2], 17) ^ rotateRight(w[t - 2], 19) ^ (w[t - 2] >>> 10);
            w[t] = (w[t - 16] + s0 + w[t - 7] + s1) | 0;
        }
        var a = hash[0], b = hash[1], c = hash[2], d = hash[3], e = hash[4], f = hash[5], g = hash[6], h = hash[7];
        for (t = 0; t < 64; t++) {
            var sum1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25);
            var choice = (e & f) ^ (~e & g);
            var temp1 = (h + sum1 + choice + SHA256_K[t] + w[t]) | 0;
            var sum0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22);
            var majority = (a & b) ^ (a & c) ^ (b & c);
            var temp2 = (sum0 + majority) | 0;
            h = g;
            g = f;
            f = e;
            e = (d + temp1) | 0;
            d = c;
            c = b;
            b = a;
            a = (temp1 + temp2) | 0;
        }
        hash[0] = (hash[0] + a) | 0;
        hash[1] = (hash[1] + b) | 0;
        hash[2] = (hash[2] + c) | 0;
        hash[3] = (hash[3] + d) | 0;
        hash[4] = (hash[4] + e) | 0;
        hash[5] = (hash[5] + f) | 0;
        hash[6] = (hash[6] + g) | 0;
        hash[7] = (hash[7] + h) | 0;
    }
    var hex = '';
    for (var i = 0; i < 8; i++) {
        hex += ('0000000' + (hash[i] >>> 0).toString(16)).slice(-8);
    }
    return hex;
}

// Keeps client strings out of the report unless raw: see the header comment.
function newPrivacy(raw) {
    return { raw: raw, secrets: [] };
}

function remember(privacy, value) {
    if (typeof value == 'string' && value.length) {
        privacy.secrets.push(value);
    }
}

// Stores value as entry[key + '_sha256'], and as entry[key] too when raw.
function conceal(privacy, entry, key, value) {
    if (value === null || value === undefined) {
        entry[key + '_sha256'] = null;
    } else {
        value = String(value);
        remember(privacy, value);
        entry[key + '_sha256'] = sha256Hex(value);
    }
    if (privacy.raw) {
        entry[key] = value === undefined ? null : value;
    }
}

// Replaces every remembered string in message with "#" and the first 12 hex digits of its hash.
function scrub(privacy, message) {
    message = String(message);
    if (privacy.raw || !privacy.secrets.length) {
        return message;
    }
    var secrets = privacy.secrets.slice(0).sort(function (x, y) { return y.length - x.length; });
    var alternatives = [];
    for (var i = 0; i < secrets.length; i++) {
        alternatives.push(secrets[i].replace(/[\\^$.*+?()\[\]{}|\/]/g, function (c) { return '\\' + c; }));
    }
    return message.replace(new RegExp(alternatives.join('|'), 'g'), function (match) {
        return '#' + sha256Hex(match).substring(0, 12);
    });
}

function jsonString(value) {
    if (value === null || value === undefined) {
        return 'null';
    }
    if (typeof value === 'number') {
        return isFinite(value) ? String(value) : 'null';
    }
    if (typeof value === 'boolean') {
        return value ? 'true' : 'false';
    }
    if (typeof value === 'string') {
        return jsonQuote(value);
    }
    var parts = [];
    var i;
    if (Object.prototype.toString.call(value) == '[object Array]') {
        for (i = 0; i < value.length; i++) {
            parts.push(jsonString(value[i]));
        }
        return '[' + parts.join(',') + ']';
    }
    for (i in value) {
        if (value.hasOwnProperty(i)) {
            parts.push(jsonQuote(i) + ':' + jsonString(value[i]));
        }
    }
    return '{' + parts.join(',') + '}';
}

function jsonQuote(text) {
    var escapes = { '"': '\\"', '\\': '\\\\', '\b': '\\b', '\f': '\\f', '\n': '\\n', '\r': '\\r', '\t': '\\t' };
    var out = '';
    for (var i = 0; i < text.length; i++) {
        var c = text.charAt(i);
        var code = text.charCodeAt(i);
        if (escapes.hasOwnProperty(c)) {
            out += escapes[c];
        } else if (code < 0x20) {
            out += '\\u' + ('000' + code.toString(16)).slice(-4);
        } else {
            out += c;
        }
    }
    return '"' + out + '"';
}

function enumName(value) {
    // "LayerKind.TEXT" -> "TEXT"
    var text = String(value);
    return text.substring(text.lastIndexOf('.') + 1);
}

function attempt(read) {
    try {
        return read();
    } catch (e) {
        return null;
    }
}

function pixels(bounds) {
    return [bounds[0].as('px'), bounds[1].as('px'), bounds[2].as('px'), bounds[3].as('px')];
}

function layerReference(layer) {
    var ref = new ActionReference();
    ref.putIdentifier(charIDToTypeID('Lyr '), layer.id);
    return ref;
}

function layerEffects(layer) {
    var desc = executeActionGet(layerReference(layer));
    var fxKey = stringIDToTypeID('layerEffects');
    if (!desc.hasKey(fxKey)) {
        return null;
    }
    var visibleKey = stringIDToTypeID('layerFXVisible');
    var enabledKey = stringIDToTypeID('enabled');
    var presentKey = stringIDToTypeID('present');
    var fx = desc.getObjectValue(fxKey);
    var result = { visible: desc.hasKey(visibleKey) ? desc.getBoolean(visibleKey) : null, items: [] };
    function add(name, effect) {
        result.items.push({
            name: name,
            enabled: effect.hasKey(enabledKey) ? effect.getBoolean(enabledKey) : null,
            present: effect.hasKey(presentKey) ? effect.getBoolean(presentKey) : null
        });
    }
    for (var i = 0; i < fx.count; i++) {
        var key = fx.getKey(i);
        var type = fx.getType(key);
        if (type == DescValueType.OBJECTTYPE) {
            add(typeIDToStringID(key), fx.getObjectValue(key));
        } else if (type == DescValueType.LISTTYPE) {
            var list = fx.getList(key);
            for (var j = 0; j < list.count; j++) {
                if (list.getType(j) == DescValueType.OBJECTTYPE) {
                    add(typeIDToStringID(key), list.getObjectValue(j));
                }
            }
        }
    }
    return result;
}

function textDetails(layer, privacy) {
    var item = layer.textItem;
    var details = {};
    conceal(privacy, details, 'contents', item.contents);
    details.font = attempt(function () { return item.font; });
    details.size = attempt(function () { return item.size.as('pt'); });
    details.kind = attempt(function () { return enumName(item.kind); });
    details.justification = attempt(function () { return enumName(item.justification); });
    return details;
}

function describeLayer(layer, index, depth, errors, privacy) {
    var isGroup = layer.typename == 'LayerSet';
    var entry = {
        index: index,
        depth: depth,
        typename: layer.typename,
        kind: isGroup ? null : enumName(layer.kind)
    };
    conceal(privacy, entry, 'name', layer.name);
    entry.bounds = pixels(layer.bounds);
    entry.bounds_no_effects = attempt(function () { return pixels(layer.boundsNoEffects); });
    entry.blend_mode = enumName(layer.blendMode);
    entry.opacity = layer.opacity;
    entry.fill_opacity = attempt(function () { return layer.fillOpacity; });
    entry.grouped = attempt(function () { return layer.grouped; });
    entry.visible = layer.visible;
    entry.is_background = attempt(function () { return layer.isBackgroundLayer; });
    entry.locks = {
        all: layer.allLocked,
        pixels: attempt(function () { return layer.pixelsLocked; }),
        position: attempt(function () { return layer.positionLocked; }),
        transparent_pixels: attempt(function () { return layer.transparentPixelsLocked; })
    };
    if (!isGroup && layer.kind == LayerKind.TEXT) {
        try {
            entry.text = textDetails(layer, privacy);
        } catch (e) {
            errors.push('layer ' + index + ' text: ' + e);
        }
    }
    try {
        entry.effects = layerEffects(layer);
    } catch (e) {
        errors.push('layer ' + index + ' effects: ' + e);
    }
    return entry;
}

function walk(layers, depth, entries, textLayers, errors, privacy) {
    for (var i = 0; i < layers.length; i++) {
        var layer = layers[i];
        entries.push(describeLayer(layer, entries.length, depth, errors, privacy));
        if (layer.typename == 'LayerSet') {
            walk(layer.layers, depth + 1, entries, textLayers, errors, privacy);
        } else if (layer.kind == LayerKind.TEXT) {
            textLayers.push({ index: entries.length - 1, layer: layer });
        }
    }
}

// Sets a text layer's own text descriptor back on it, so Photoshop lays the text out again from the
// stored engine data (keeping every style run) instead of showing the pixels saved in the file.
function retypeset(layer) {
    var locked = layer.allLocked;
    if (locked) {
        layer.allLocked = false;
    }
    try {
        var ref = layerReference(layer);
        var textKey = executeActionGet(ref).getObjectValue(stringIDToTypeID('textKey'));
        var set = new ActionDescriptor();
        set.putReference(charIDToTypeID('null'), ref);
        set.putObject(charIDToTypeID('T   '), charIDToTypeID('TxLr'), textKey);
        executeAction(charIDToTypeID('setd'), set, DialogModes.NO);
    } finally {
        if (locked) {
            layer.allLocked = true;
        }
    }
}

function exportPNG(doc, file) {
    var options = new PNGSaveOptions();
    options.interlaced = false;
    doc.saveAs(file, options, true, Extension.LOWERCASE);
}

function writeText(file, text) {
    file.encoding = 'UTF-8';
    file.lineFeed = 'Unix';
    if (!file.open('w')) {
        throw new Error('cannot write ' + file.fsName + ': ' + file.error);
    }
    file.write(text);
    file.close();
}

function openPath(doc) {
    try {
        return doc.fullName.fsName;
    } catch (e) {
        return null; // never saved
    }
}

function photoshopVerify(args) {
    var privacy = newPrivacy(args.length > 2 && args[2] == 'raw');
    var input = new File(args[0]);
    var outDir = new Folder(args[1]);
    var fileName = input.fsName.replace(/^.*\//, '');
    var name = fileName.replace(/\.[^.]*$/, '');
    var jsonFile = new File(outDir.fsName + '/' + name + '.verify.json');
    remember(privacy, input.fsName);
    remember(privacy, fileName);
    remember(privacy, name);
    remember(privacy, attempt(function () { return input.fullName; })); // URI-encoded forms
    remember(privacy, attempt(function () { return input.name; }));
    var report = {};
    if (privacy.raw) {
        report.file = input.fsName;
    }
    report.file_sha256 = sha256Hex(fileName);
    report.raw = privacy.raw;
    report.photoshop = app.version;
    report.document = null;
    report.guides = [];
    report.layers = [];
    report.retypeset = [];
    report.exports = { opened: false, retypeset: false };
    report.errors = [];
    var previous = app.documents.length ? app.activeDocument : null;
    var saved = {
        displayDialogs: app.displayDialogs,
        rulerUnits: app.preferences.rulerUnits,
        typeUnits: app.preferences.typeUnits
    };
    var doc = null;
    try {
        if (!input.exists) {
            throw new Error('no such file: ' + input.fsName); // scrubbed below unless raw
        }
        for (var d = 0; d < app.documents.length; d++) {
            if (openPath(app.documents[d]) == input.fsName) {
                throw new Error('already open in Photoshop; verify a copy');
            }
        }
        if (!outDir.exists && !outDir.create()) {
            throw new Error('cannot create ' + outDir.fsName);
        }
        app.displayDialogs = DialogModes.NO;
        app.preferences.rulerUnits = Units.PIXELS;
        app.preferences.typeUnits = TypeUnits.POINTS;

        var countBefore = app.documents.length;
        var opened = app.open(input);
        if (app.documents.length != countBefore + 1) {
            throw new Error('Photoshop did not open a new document');
        }
        doc = opened;
        app.activeDocument = doc;
        report.document = {};
        conceal(privacy, report.document, 'name', doc.name);
        report.document.width = doc.width.as('px');
        report.document.height = doc.height.as('px');
        report.document.resolution = doc.resolution;
        report.document.mode = enumName(doc.mode);
        report.document.bits = enumName(doc.bitsPerChannel);
        for (var g = 0; g < doc.guides.length; g++) {
            report.guides.push({
                direction: enumName(doc.guides[g].direction),
                coordinate: doc.guides[g].coordinate.as('px')
            });
        }
        var textLayers = [];
        walk(doc.layers, 0, report.layers, textLayers, report.errors, privacy);
        exportPNG(doc, new File(outDir.fsName + '/' + name + '.opened.png'));
        report.exports.opened = true;
        for (var t = 0; t < textLayers.length; t++) {
            var outcome = { index: textLayers[t].index, ok: true, error: null };
            try {
                retypeset(textLayers[t].layer);
            } catch (e) {
                outcome.ok = false;
                outcome.error = String(e);
                report.errors.push('layer ' + textLayers[t].index + ' re-typeset: ' + e);
            }
            report.retypeset.push(outcome);
        }
        exportPNG(doc, new File(outDir.fsName + '/' + name + '.retypeset.png'));
        report.exports.retypeset = true;
    } catch (e) {
        report.errors.push(String(e) + (e.line ? ' (line ' + e.line + ')' : ''));
    } finally {
        if (doc) {
            try {
                doc.close(SaveOptions.DONOTSAVECHANGES);
            } catch (e) {
                report.errors.push('close: ' + e);
            }
        }
        app.preferences.rulerUnits = saved.rulerUnits;
        app.preferences.typeUnits = saved.typeUnits;
        app.displayDialogs = saved.displayDialogs;
        if (previous) {
            try {
                app.activeDocument = previous;
            } catch (e) {
                report.errors.push('restore active document: ' + e);
            }
        }
    }
    // Photoshop's messages name layers and files; every string remembered above is known by now.
    for (var r = 0; r < report.retypeset.length; r++) {
        if (report.retypeset[r].error !== null) {
            report.retypeset[r].error = scrub(privacy, report.retypeset[r].error);
        }
    }
    for (var m = 0; m < report.errors.length; m++) {
        report.errors[m] = scrub(privacy, report.errors[m]);
    }
    try {
        writeText(jsonFile, jsonString(report) + '\n');
    } catch (e) {
        return 'failed ' + e;
    }
    return (report.errors.length ? 'failed ' : 'ok ') + jsonFile.fsName +
        (report.errors.length ? ': ' + report.errors[0] : '');
}

var verifyResult = typeof app == 'undefined' ? 'not running in Photoshop' : photoshopVerify(arguments);
verifyResult;
