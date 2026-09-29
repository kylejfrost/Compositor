"""Tests for scripts/photoshop-verify.sh and scripts/photoshop-verify.jsx that never talk to Photoshop.

Run from the repository root:
    python3 -m unittest discover -s scripts/tests -p 'test_photoshop_verify.py'
"""

import hashlib
import json
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
SHELL = SCRIPTS / "photoshop-verify.sh"
JSX = SCRIPTS / "photoshop-verify.jsx"

# Loads the harness outside Photoshop (no `app`, so it does not run) and prints jsonString(value) for a
# value read from stdin.
NODE_SERIALIZE = """
const fs = require('fs');
const vm = require('vm');
const sandbox = {};
vm.runInNewContext(fs.readFileSync(process.argv[1], 'utf8'), sandbox);
const value = JSON.parse(fs.readFileSync(0, 'utf8'));
process.stdout.write(sandbox.jsonString(value));
"""

# Prints sha256Hex(text) for each string in a JSON list read from stdin.
NODE_SHA256 = """
const fs = require('fs');
const vm = require('vm');
const sandbox = {};
vm.runInNewContext(fs.readFileSync(process.argv[1], 'utf8'), sandbox);
const texts = JSON.parse(fs.readFileSync(0, 'utf8'));
process.stdout.write(JSON.stringify(texts.map((text) => sandbox.sha256Hex(text))));
"""

# Runs photoshopVerify against a stand-in for the Photoshop DOM. The scenario (stdin) gives the arguments and
# the layers of the document `app.open` returns; the owner already has a document of their own open and active,
# with non-default preferences. A layer with `fail` throws, on re-typeset, the kind of error Photoshop raises,
# which names the layer. Prints the result plus the state the harness left Photoshop in.
NODE_FAKE_PHOTOSHOP = """
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const sandbox = {};
vm.runInNewContext(fs.readFileSync(process.argv[1], 'utf8'), sandbox);
const scenario = JSON.parse(fs.readFileSync(0, 'utf8'));

const unit = (value) => ({ as: () => value });
const layersById = {};
const closed = [];
let nextId = 1;

class File {
  constructor(name) {
    this.fsName = path.resolve(String(name));
    this.name = encodeURIComponent(path.basename(this.fsName));
    this.fullName = encodeURI(this.fsName);
    this.error = '';
  }
  get exists() { return fs.existsSync(this.fsName); }
  open() { this.buffer = ''; return true; }
  write(text) { this.buffer += text; }
  close() { fs.writeFileSync(this.fsName, this.buffer, 'utf8'); }
}

class Folder {
  constructor(name) { this.fsName = path.resolve(String(name)); }
  get exists() { return fs.existsSync(this.fsName); }
  create() { fs.mkdirSync(this.fsName, { recursive: true }); return true; }
}

function makeLayer(spec) {
  const group = Array.isArray(spec.layers);
  const layer = {
    id: nextId++,
    typename: group ? 'LayerSet' : 'ArtLayer',
    name: spec.name,
    bounds: [unit(1), unit(2), unit(11), unit(12)],
    boundsNoEffects: [unit(1), unit(2), unit(11), unit(12)],
    blendMode: 'BlendMode.NORMAL',
    opacity: 100,
    fillOpacity: 100,
    grouped: false,
    visible: true,
    isBackgroundLayer: false,
    allLocked: false,
    pixelsLocked: false,
    positionLocked: false,
    transparentPixelsLocked: false,
    fail: !!spec.fail,
  };
  if (group) {
    layer.layers = spec.layers.map(makeLayer);
  } else {
    layer.kind = spec.text === undefined ? 'LayerKind.NORMAL' : 'LayerKind.TEXT';
  }
  if (spec.text !== undefined) {
    layer.textItem = {
      contents: spec.text,
      font: 'ArialMT',
      size: unit(24),
      kind: 'TextType.POINTTEXT',
      justification: 'Justification.LEFT',
    };
  }
  layersById[layer.id] = layer;
  return layer;
}

const owner = { name: 'Owner work.psd', fullName: { fsName: '/Users/owner/Owner work.psd' } };
const app = {
  version: '27.8.0',
  documents: [owner],
  activeDocument: owner,
  displayDialogs: 'DialogModes.ALL',
  preferences: { rulerUnits: 'Units.CM', typeUnits: 'TypeUnits.MM' },
  open(file) {
    const doc = {
      name: path.basename(file.fsName),
      fullName: new File(file.fsName),
      width: unit(100),
      height: unit(80),
      resolution: 72,
      mode: 'DocumentMode.RGB',
      bitsPerChannel: 'BitsPerChannelType.EIGHT',
      guides: [{ direction: 'Direction.VERTICAL', coordinate: unit(64) }],
      layers: scenario.layers.map(makeLayer),
      saveAs(target) { fs.writeFileSync(target.fsName, 'png'); },
      close(option) {
        closed.push({ name: this.name, option });
        app.documents.splice(app.documents.indexOf(this), 1);
      },
    };
    app.documents.push(doc);
    return doc;
  },
};

class ActionReference { putIdentifier(type, id) { this.id = id; } }
class ActionDescriptor {
  putReference(key, ref) { this.ref = ref; }
  putObject() {}
}

Object.assign(sandbox, {
  app, File, Folder, ActionReference, ActionDescriptor,
  PNGSaveOptions: function PNGSaveOptions() {},
  DialogModes: { NO: 'DialogModes.NO' },
  Units: { PIXELS: 'Units.PIXELS' },
  TypeUnits: { POINTS: 'TypeUnits.POINTS' },
  SaveOptions: { DONOTSAVECHANGES: 'SaveOptions.DONOTSAVECHANGES' },
  Extension: { LOWERCASE: 'Extension.LOWERCASE' },
  LayerKind: { TEXT: 'LayerKind.TEXT' },
  DescValueType: { OBJECTTYPE: 'object', LISTTYPE: 'list' },
  charIDToTypeID: (id) => id,
  stringIDToTypeID: (id) => id,
  typeIDToStringID: (id) => id,
  executeActionGet: () => ({ hasKey: () => false, getObjectValue: () => ({}) }),
  executeAction: (event, descriptor) => {
    const layer = layersById[descriptor.ref.id];
    if (layer.fail) {
      throw new Error('General Photoshop error occurred.\\n- The object \\u201clayer \\u201c' + layer.name +
        '\\u201d\\u201d is not currently available.');
    }
  },
});

const result = sandbox.photoshopVerify(scenario.args);
process.stdout.write(JSON.stringify({
  result,
  closed,
  documents: app.documents.map((doc) => doc.name),
  active: app.activeDocument.name,
  displayDialogs: app.displayDialogs,
  preferences: app.preferences,
}));
"""

# Distinctive stand-ins for client strings: none of them may reach a default report.
CLIENT_FILE = "Northwind Quarterly Brief.psd"
CLIENT_LAYERS = [
    {"name": "Confidential Folder", "layers": [{"name": "Northwind Hero Image"}]},
    {"name": "Unreleased Offer Headline", "text": "Launch price $19\rsecond line \u2014 caf\u00e9"},
    {"name": "Embargoed Legal Line", "text": "Offer ends Friday", "fail": True},
]
CLIENT_STRINGS = [
    "Northwind",
    "Confidential Folder",
    "Unreleased Offer Headline",
    "Embargoed Legal Line",
    "Launch price",
    "second line",
    "Offer ends Friday",
]


def sha(text):
    return hashlib.sha256(text.encode("utf-8", "surrogatepass")).hexdigest()


class PhotoshopVerifyShellTests(unittest.TestCase):
    def run_shell(self, *args):
        return subprocess.run([str(SHELL), *map(str, args)], capture_output=True, text=True, timeout=30)

    def test_usage_without_arguments(self):
        result = self.run_shell()
        self.assertEqual(result.returncode, 2)
        self.assertIn("usage: photoshop-verify.sh [--raw] <file.psd> <out-dir>", result.stderr)

    def test_unknown_option_prints_usage(self):
        result = self.run_shell("--names", "a.psd", "out")
        self.assertEqual(result.returncode, 2)
        self.assertIn("usage: photoshop-verify.sh [--raw] <file.psd> <out-dir>", result.stderr)

    def test_raw_option_with_a_missing_input_is_rejected_before_photoshop_is_contacted(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self.run_shell("--raw", Path(tmp) / "missing.psd", Path(tmp) / "out")
            self.assertEqual(result.returncode, 2)
            self.assertIn("no such file", result.stderr)
            self.assertFalse((Path(tmp) / "out").exists())

    def test_missing_input_file_is_rejected_before_photoshop_is_contacted(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self.run_shell(Path(tmp) / "missing.psd", Path(tmp) / "out")
            self.assertEqual(result.returncode, 2)
            self.assertIn("no such file", result.stderr)
            self.assertFalse((Path(tmp) / "out").exists())


# Stands in for osascript: the System Events dialog check (argv ends in "list" or "cancel") and the harness run
# ("do javascript"). STUB_DIALOG is an alert that appears once the harness runs and is gone once cancelled;
# STUB_OPEN_DIALOG one that is already open. Every call is logged to STUB_DIR/calls.log.
FAKE_OSASCRIPT = """#!/usr/bin/env python3
import os, sys, time
from pathlib import Path
state = Path(os.environ["STUB_DIR"])
args = sys.argv[1:]
dialog = os.environ.get("STUB_DIALOG", "")
with open(state / "calls.log", "a") as log:
    if any("System Events" in a for a in args):
        mode = args[-1]
        log.write("dialogs " + mode + "\\n")
        if os.environ.get("STUB_OPEN_DIALOG"):
            print("dialog\\n" + os.environ["STUB_OPEN_DIALOG"])
        elif dialog and (state / "running").exists() and not (state / "cancelled").exists():
            if mode == "cancel":
                (state / "cancelled").touch()
                print("dialog\\n" + dialog + "\\n[pressed Cancel]")
            else:
                print("dialog\\n" + dialog)
    elif any("do javascript" in a for a in args):
        log.write("harness\\n")
        (state / "running").touch()
        if dialog:
            deadline = time.time() + 15
            while not (state / "cancelled").exists() and time.time() < deadline:
                time.sleep(0.1)
            print('failed {"errors": ["open was cancelled"]}: open was cancelled')
        else:
            print('ok {"errors": []}')
"""

ALERT = ("A problem was encountered reading layer \u201cDiagonal\u201d because there was a metadata error. "
         "Some Smart Shape data was lost. Continue?")


class PhotoshopVerifyAlertTests(unittest.TestCase):
    """The harness watches Photoshop for dialogs while it runs, so a file that raises one never leaves Photoshop
    blocked: the alert is cancelled, recorded in alerts.txt and fails the run."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        stub = bin_dir / "osascript"
        stub.write_text(FAKE_OSASCRIPT)
        stub.chmod(0o755)
        self.psd = self.tmp / "Client Launch.psd"
        self.psd.write_bytes(b"8BPS")
        self.out = self.tmp / "out"
        self.env = {"PATH": f"{bin_dir}:/usr/bin:/bin", "STUB_DIR": str(self.tmp), "LANG": "en_US.UTF-8"}

    def run_shell(self, *args, **env):
        return subprocess.run([str(SHELL), *map(str, args)], capture_output=True, text=True, timeout=60,
                              env={**self.env, **env})

    def calls(self):
        return (self.tmp / "calls.log").read_text().split()

    def test_a_run_without_alerts_passes_and_writes_no_alerts_file(self):
        result = self.run_shell(self.psd, self.out)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith("ok"))
        self.assertFalse((self.out / "alerts.txt").exists())
        self.assertEqual(self.calls()[:2], ["dialogs", "list"])

    def test_an_alert_is_cancelled_recorded_with_names_hashed_and_fails_the_run(self):
        (self.out).mkdir()
        (self.out / "alerts.txt").write_text("an earlier run's alert")
        result = self.run_shell(self.psd, self.out, STUB_DIALOG=ALERT)
        self.assertEqual(result.returncode, 1)
        self.assertIn("cancel", self.calls())
        alerts = (self.out / "alerts.txt").read_text()
        hashed = "#" + sha("Diagonal")[:12]
        for text in (alerts, result.stderr):
            self.assertIn(f"reading layer {hashed} because there was a metadata error", text)
            self.assertIn("[pressed Cancel]", text)
            self.assertNotIn("Diagonal", text)
        self.assertNotIn("earlier run", alerts)

    def test_raw_mode_records_the_alert_as_photoshop_wrote_it(self):
        result = self.run_shell("--raw", self.psd, self.out, STUB_DIALOG=ALERT)
        self.assertEqual(result.returncode, 1)
        self.assertIn(ALERT, (self.out / "alerts.txt").read_text())

    def test_a_dialog_already_open_stops_the_run_before_photoshop_is_asked_anything(self):
        result = self.run_shell(self.psd, self.out, STUB_OPEN_DIALOG="Save changes to \u201cKyle.psd\u201d?")
        self.assertEqual(result.returncode, 3)
        self.assertIn("already has a dialog open", result.stderr)
        self.assertNotIn("Kyle.psd", result.stderr)
        self.assertNotIn("harness", self.calls())
        self.assertNotIn("cancel", self.calls())


@unittest.skipUnless(shutil.which("node"), "node is needed to parse the ExtendScript harness")
class PhotoshopVerifyHarnessTests(unittest.TestCase):
    def test_harness_parses_as_javascript(self):
        compile_only = "new (require('vm').Script)(require('fs').readFileSync(process.argv[1], 'utf8'))"
        result = subprocess.run(["node", "-e", compile_only, str(JSX)], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_harness_avoids_syntax_newer_than_es3(self):
        code = re.sub(r"//[^\n]*|/\*.*?\*/", "", JSX.read_text(), flags=re.S)
        code = re.sub(r"'(?:\\.|[^'\\])*'|\"(?:\\.|[^\"\\])*\"", "''", code)
        for pattern in (r"\blet\b", r"\bconst\b", r"=>", r"`", r"\bclass\b", r"\.\.\.", r"\bJSON\."):
            self.assertIsNone(re.search(pattern, code), f"ExtendScript is ES3: found {pattern}")

    def test_json_serializer_round_trips_awkward_values(self):
        value = {
            "text": 'Quote " backslash \\ return \r newline \n tab \t nul \u0000 bell \u0007',
            "unicode": "Caf\u00e9 \u2014 \u201cquoted\u201d \U0001F600",
            "numbers": [0, -3, 2.5, 1e21],
            "flags": [True, False, None],
            "nested": {"empty_list": [], "empty_object": {}},
        }
        result = subprocess.run(
            ["node", "-e", NODE_SERIALIZE, str(JSX)],
            input=json.dumps(value),
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), value)

    def test_sha256_matches_python_hashlib(self):
        texts = [
            "",
            "abc",
            "Background",
            "line one\rline two\r",
            "Caf\u00e9 \u2014 \u201cquoted\u201d \U0001F600 \u4e2d\u6587",
            "lone \ud800 surrogate",
            "x" * 55,
            "x" * 56,
            "x" * 64,
            "multi-block " * 100,
        ]
        result = subprocess.run(
            ["node", "-e", NODE_SHA256, str(JSX)],
            input=json.dumps(texts),
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [sha(text) for text in texts])


@unittest.skipUnless(shutil.which("node"), "node runs the harness against a stand-in for Photoshop")
class PhotoshopVerifyFakePhotoshopTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.input = self.tmp / CLIENT_FILE
        self.input.write_bytes(b"8BPS")
        self.out = self.tmp / "out"

    def tearDown(self):
        self._tmp.cleanup()

    def run_harness(self, *mode):
        scenario = {"args": [str(self.input), str(self.out), *mode], "layers": CLIENT_LAYERS}
        result = subprocess.run(
            ["node", "-e", NODE_FAKE_PHOTOSHOP, str(JSX)],
            input=json.dumps(scenario),
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        state = json.loads(result.stdout)
        stored = (self.out / "Northwind Quarterly Brief.verify.json").read_text(encoding="utf-8")
        return state, stored, json.loads(stored)

    def test_report_stores_hashes_instead_of_names_text_and_the_file_name(self):
        state, stored, report = self.run_harness()

        for client_string in [*CLIENT_STRINGS, str(self.tmp)]:
            self.assertNotIn(client_string, stored)
        self.assertIs(report["raw"], False)
        self.assertNotIn("file", report)
        self.assertEqual(report["file_sha256"], sha(CLIENT_FILE))
        self.assertEqual(report["document"], {
            "name_sha256": sha(CLIENT_FILE),
            "width": 100,
            "height": 80,
            "resolution": 72,
            "mode": "RGB",
            "bits": "EIGHT",
        })
        self.assertEqual(
            [(layer["index"], layer["depth"], layer["name_sha256"]) for layer in report["layers"]],
            [
                (0, 0, sha("Confidential Folder")),
                (1, 1, sha("Northwind Hero Image")),
                (2, 0, sha("Unreleased Offer Headline")),
                (3, 0, sha("Embargoed Legal Line")),
            ],
        )
        for layer in report["layers"]:
            self.assertNotIn("name", layer)
        headline = report["layers"][2]["text"]
        self.assertEqual(headline["contents_sha256"], sha("Launch price $19\rsecond line \u2014 caf\u00e9"))
        self.assertNotIn("contents", headline)
        self.assertEqual(headline["size"], 24)
        self.assertEqual(report["exports"], {"opened": True, "retypeset": True})
        self.assertTrue(state["result"].startswith("failed "), state["result"])

    def test_photoshop_error_messages_are_stored_with_names_replaced_by_their_hashes(self):
        state, stored, report = self.run_harness()

        self.assertEqual(
            report["retypeset"],
            [
                {"index": 2, "ok": True, "error": None},
                {
                    "index": 3,
                    "ok": False,
                    "error": "Error: General Photoshop error occurred.\n- The object \u201clayer \u201c#"
                    + sha("Embargoed Legal Line")[:12]
                    + "\u201d\u201d is not currently available.",
                },
            ],
        )
        self.assertEqual(len(report["errors"]), 1)
        self.assertTrue(report["errors"][0].startswith("layer 3 re-typeset: Error: General Photoshop error"))
        self.assertIn("#" + sha("Embargoed Legal Line")[:12], report["errors"][0])
        self.assertNotIn("Embargoed", state["result"])

    def test_raw_mode_also_stores_names_text_and_the_path(self):
        state, stored, report = self.run_harness("raw")

        self.assertIs(report["raw"], True)
        self.assertEqual(report["file"], str(self.input))
        self.assertEqual(report["file_sha256"], sha(CLIENT_FILE))
        self.assertEqual(report["document"]["name"], CLIENT_FILE)
        self.assertEqual(
            [layer["name"] for layer in report["layers"]],
            ["Confidential Folder", "Northwind Hero Image", "Unreleased Offer Headline", "Embargoed Legal Line"],
        )
        self.assertEqual(report["layers"][2]["text"]["contents"], "Launch price $19\rsecond line \u2014 caf\u00e9")
        self.assertIn("Embargoed Legal Line", report["retypeset"][1]["error"])

    def test_closes_only_its_own_document_and_restores_photoshop(self):
        state, stored, report = self.run_harness()

        self.assertEqual(state["closed"], [{"name": CLIENT_FILE, "option": "SaveOptions.DONOTSAVECHANGES"}])
        self.assertEqual(state["documents"], ["Owner work.psd"])
        self.assertEqual(state["active"], "Owner work.psd")
        self.assertEqual(state["displayDialogs"], "DialogModes.ALL")
        self.assertEqual(state["preferences"], {"rulerUnits": "Units.CM", "typeUnits": "TypeUnits.MM"})
        self.assertTrue((self.out / "Northwind Quarterly Brief.opened.png").exists())
        self.assertTrue((self.out / "Northwind Quarterly Brief.retypeset.png").exists())


if __name__ == "__main__":
    unittest.main()
