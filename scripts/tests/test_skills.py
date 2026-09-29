"""Tests for the agent skills in skills/, the scripts they bundle, and scripts/install-skills.sh.

Run from the repository root with the system python3 (no packages needed):
    python3 -m unittest discover -s scripts/tests -p test_skills.py
or together with the other script tests:
    uv run --with psd-tools python3 -m unittest discover -s scripts/tests

Nothing here touches the real ~/.agents, ~/.claude, ~/.codex or Compositor's real endpoint
file: every script runs with HOME pointed at a temporary folder (the install script's real
install and uninstall too), and check-compositor.sh only against a fake endpoint on an
ephemeral port.
"""

import hashlib
import http.server
import importlib.util
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SKILLS = REPO / "skills"
INSTALL = REPO / "scripts" / "install-skills.sh"
CHECK = SKILLS / "compositor-setup" / "scripts" / "check-compositor.sh"
ATLAS = SKILLS / "compositor" / "references" / "tool-atlas.md"

REQUIRED_SKILLS = {
    "compositor", "compositor-setup", "compositor-psd-templates", "compositor-layout-and-type",
    "compositor-image-editing", "compositor-variants-and-delivery", "compositor-development",
}

MAX_DESCRIPTION = 1024
MAX_SKILL_LINES = 500
TOC_THRESHOLD = 300
ALLOWED_FRONTMATTER = {"name", "description", "license", "allowed-tools", "metadata", "compatibility"}
# Files the structure tests read as markdown or data; the client-data scan reads every file (see skill_files).
TEXT_SUFFIXES = {".md", ".json", ".yaml", ".yml", ".sh", ".py", ".txt"}


def skill_dirs():
    return sorted(path.parent for path in SKILLS.glob("*/SKILL.md"))


def skill_text_files(skill):
    return sorted(path for path in skill.rglob("*") if path.is_file() and path.suffix in TEXT_SUFFIXES)


def skill_files(skill):
    """Every file in a skill, whatever its type; `__pycache__` and `.DS_Store` are left out."""
    return sorted(path for path in skill.rglob("*")
                  if path.is_file() and "__pycache__" not in path.parts and path.name != ".DS_Store")


def readable_text(path):
    """A file's contents as text, or None for a binary file (an image, say) that isn't UTF-8."""
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return None


# MARK: - Frontmatter

FRONTMATTER = re.compile(r"\A---\n(.*?)\n---\n", re.S)
PLAIN_UNSAFE_START = set("-?:,[]{}#&*!|>'\"%@`")
NON_STRING_PLAIN = re.compile(r"(?i)(true|false|yes|no|on|off|null|~|[-+]?(\d[\d_]*(\.\d*)?|\.\d+)([eE][-+]?\d+)?)")


def parse_scalar(value, where):
    """A YAML scalar in the subset skills use: a double-quoted string (JSON escapes, which YAML 1.2
    shares) or a plain scalar that YAML reads back as the same string."""
    if value.startswith('"'):
        try:
            parsed = json.loads(value)
        except ValueError as error:
            raise ValueError(f"{where}: bad double-quoted string ({error})") from None
        if not isinstance(parsed, str):
            raise ValueError(f"{where}: expected a string")
        return parsed
    if not value:
        raise ValueError(f"{where}: empty value")
    if value[0] in PLAIN_UNSAFE_START or ": " in value or " #" in value or value.endswith(":"):
        raise ValueError(f"{where}: this plain value is not valid YAML as written; quote it")
    if NON_STRING_PLAIN.fullmatch(value):
        raise ValueError(f"{where}: YAML reads {value!r} as a non-string; quote it")
    return value


def parse_frontmatter(text):
    """The YAML frontmatter of a SKILL.md as a dict, in a strict subset of YAML: one `key: value`
    per line, each value a single-line scalar (see `parse_scalar`). Anything outside the subset is
    rejected rather than guessed at, so a file that passes is valid YAML with the same meaning."""
    match = FRONTMATTER.match(text)
    if not match:
        raise ValueError("no YAML frontmatter: the file must start with '---' and close it with '---'")
    fields = {}
    for number, line in enumerate(match.group(1).split("\n"), start=2):
        key, separator, rest = line.partition(":")
        if not separator or not re.fullmatch(r"[a-z][a-z0-9-]*", key) or not rest.startswith(" "):
            raise ValueError(f"line {number}: expected 'key: value', got {line!r}")
        if key in fields:
            raise ValueError(f"line {number}: duplicate key {key!r}")
        fields[key] = parse_scalar(rest.strip(), f"line {number} ({key})")
    try:
        import yaml  # optional cross-check when PyYAML happens to be installed
    except ImportError:
        return fields
    if yaml.safe_load(match.group(1)) != fields:
        raise ValueError("PyYAML reads the frontmatter differently")
    return fields


def parse_openai_yaml(text):
    """agents/openai.yaml in the house style: an `interface:` mapping of single-line scalars."""
    lines = [line for line in text.splitlines() if line.strip() and not line.lstrip().startswith("#")]
    if not lines or lines[0] != "interface:":
        raise ValueError("expected 'interface:' as the first key")
    fields = {}
    for line in lines[1:]:
        match = re.fullmatch(r"  ([a-z_]+): (.+)", line)
        if not match:
            raise ValueError(f"expected '  key: value' under interface, got {line!r}")
        fields[match.group(1)] = parse_scalar(match.group(2), match.group(1))
    return fields


# MARK: - Client data deny-list

# Client-identifying terms, stored only as SHA-256 hex digests of the term's words (lowercase letters and
# digits, joined by single spaces; see deny_term_hash), so this repository never carries client data in
# plain text. Current entries: the typefaces the plan records as used across the owner's client PSD
# corpus. Add a term (at most MAX_TERM_WORDS words; punctuation separates words) with, from the repo root:
#   python3 -c 'import sys; sys.path.insert(0, "scripts/tests"); from test_skills import deny_term_hash; print(deny_term_hash(sys.argv[1]))' "term"
DENIED_TERM_HASHES = frozenset({
    "6f0fb8e8d3cd7720cb03276b646d81c6ce8beb3b757177da973e8ebbce839470",
    "34fb5dccbe78ddfd6f2fb9a7ed56e47c9ac6fd27723bcf4d0e9948fc7ce3906d",
})
MAX_TERM_WORDS = 4

ALLOWED_HOSTS = {"127.0.0.1", "localhost", "example.com", "example.org", "example.net", "modelcontextprotocol.io"}
# RFC 5737 documentation networks, for examples that need a network address.
DOCUMENTATION_IP = re.compile(r"(192\.0\.2|198\.51\.100|203\.0\.113)\.\d{1,3}")
EMAIL = re.compile(r"[\w.+-]+@([\w-]+(?:\.[\w-]+)+)")
URL_HOST = re.compile(r"\bhttps?://([A-Za-z0-9.-]+)")
BARE_DOMAIN = re.compile(r"(?<![\w.@/-])((?:[a-z0-9-]+\.)+(?:com|net|org|us|gov|edu|biz|info|io|co))\b", re.I)
USER_HOME = re.compile(r"/(?:Users|home)/(?!Shared\b)[A-Za-z0-9._-]+")
CLOUD_ACCOUNT = re.compile(r"GoogleDrive-[^/\s]+|OneDrive-[^/\s]+|Dropbox-[^/\s]+")
PHONE = re.compile(r"\(?\b(\d{3})\)?[-. ](\d{3})[-.](\d{4})\b")


def sha256(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def term_words(text):
    """The words matching compares: runs of lowercase letters and digits; everything else separates them."""
    return re.findall(r"[a-z0-9]+", text.lower())


def deny_term_hash(term):
    """The digest to add to DENIED_TERM_HASHES for `term`, normalized exactly as denied_terms_in reads text, so
    "O'Brien Dental" or "Smith & Sons" match wherever their words appear in a row."""
    words = term_words(term)
    if not words:
        raise ValueError("the term has no letters or digits")
    if len(words) > MAX_TERM_WORDS:
        raise ValueError(f"the term has {len(words)} words; matching looks at most {MAX_TERM_WORDS} in a row")
    return sha256(" ".join(words))


def denied_terms_in(text, hashes=DENIED_TERM_HASHES):
    """Hashes of the denied terms that appear in `text` as whole words (any case)."""
    words = term_words(text)
    found = set()
    for size in range(1, MAX_TERM_WORDS + 1):
        for start in range(len(words) - size + 1):
            digest = sha256(" ".join(words[start:start + size]))
            if digest in hashes:
                found.add(digest)
    return found


def host_allowed(host):
    host = host.lower()
    return (host in ALLOWED_HOSTS or any(host.endswith("." + allowed) for allowed in ALLOWED_HOSTS)
            or DOCUMENTATION_IP.fullmatch(host) is not None)


def client_data_findings(text, hashes=DENIED_TERM_HASHES):
    """What in `text` looks like client or personal data: a list of short descriptions.
    Denied terms are reported by hash prefix, so a failure never prints the term itself."""
    findings = []
    for match in EMAIL.finditer(text):
        if not host_allowed(match.group(1)):
            findings.append(f"email address {match.group(0)!r}")
    for match in URL_HOST.finditer(text):
        if not host_allowed(match.group(1)):
            findings.append(f"URL host {match.group(1)!r}")
    for match in BARE_DOMAIN.finditer(text):
        if not host_allowed(match.group(1)):
            findings.append(f"domain {match.group(1)!r}")
    findings += [f"home folder path {m.group(0)!r} (write ~ instead)" for m in USER_HOME.finditer(text)]
    findings += [f"cloud storage account folder {m.group(0)!r}" for m in CLOUD_ACCOUNT.finditer(text)]
    findings += [f"phone number {m.group(0)!r}" for m in PHONE.finditer(text) if m.group(2) != "555"]
    findings += [f"denied term #{digest[:12]}" for digest in sorted(denied_terms_in(text, hashes))]
    return findings


def skill_findings(skill, path, hashes=DENIED_TERM_HASHES):
    """client_data_findings for a skill file's path within the skill and, when it is text, its contents."""
    findings = [f"in the file name: {finding}" for finding in client_data_findings(str(path.relative_to(skill)), hashes)]
    text = readable_text(path)
    if text is not None:
        findings += client_data_findings(text, hashes)
    return findings


class DenyListMechanismTests(unittest.TestCase):
    def test_denied_terms_are_stored_as_sha256_digests(self):
        for digest in DENIED_TERM_HASHES:
            self.assertRegex(digest, r"\A[0-9a-f]{64}\Z")

    def test_a_hashed_term_is_found_in_any_case_and_across_punctuation(self):
        hashes = {sha256("northwind traders")}
        self.assertEqual(denied_terms_in("Made for NORTHWIND-Traders, 2026.", hashes), hashes)
        self.assertEqual(denied_terms_in("northwind and traders", hashes), set())
        self.assertEqual(denied_terms_in("Northwindtraders", hashes), set())

    def test_a_term_added_with_the_helper_matches_across_punctuation(self):
        for term, text in [("O'Brien Dental", "Signage for o’brien DENTAL, spring"), ("Smith & Sons", "smith and sons"),
                           ("Smith & Sons", "SMITH & SONS HARDWARE")]:
            with self.subTest(term=term, text=text):
                found = denied_terms_in(text, {deny_term_hash(term)})
                self.assertEqual(bool(found), "and" not in text)

    def test_the_helper_refuses_terms_matching_can_never_find(self):
        with self.assertRaises(ValueError):
            deny_term_hash("one two three four five")
        with self.assertRaises(ValueError):
            deny_term_hash("—")

    def test_every_file_and_file_name_is_scanned(self):
        with tempfile.TemporaryDirectory() as folder:
            skill = Path(folder) / "sample-skill"
            (skill / "assets").mkdir(parents=True)
            (skill / "assets" / "notes.toml").write_text("url = 'https://brief.widgets.invalid/q3'\n")
            (skill / "assets" / "export.jsx").write_text("// mail jane@widgets.invalid\n")
            (skill / "assets" / "jane@widgets.invalid.csv").write_text("a,b\n")
            (skill / "assets" / "swatch.png").write_bytes(b"\x89PNG\r\n\x1a\n\xff\xfe\x00")
            findings = {str(path.relative_to(skill)): skill_findings(skill, path) for path in skill_files(skill)}
        self.assertTrue(findings["assets/notes.toml"])
        self.assertTrue(findings["assets/export.jsx"])
        self.assertTrue(findings["assets/jane@widgets.invalid.csv"], "file names are scanned too")
        self.assertEqual(findings["assets/swatch.png"], [], "binary contents are skipped, not misread")

    def test_findings_name_the_hash_prefix_not_the_term(self):
        findings = client_data_findings("Northwind Traders flyer", {sha256("northwind traders")})
        self.assertEqual(findings, [f"denied term #{sha256('northwind traders')[:12]}"])

    def test_personal_data_patterns_are_flagged(self):
        samples = [
            "mail jane@widgets.invalid",
            "see https://brief.widgets.invalid/q3",
            "reach it at http://192.168.1.40:2667/mcp",
            "hosted at widgets-co.com today",
            "open /Users/jane/Desktop/hero.png",
            "~/Library/CloudStorage/GoogleDrive-jane@widgets.invalid/My Drive",
            "call (850) 321-4567",
        ]
        for sample in samples:
            with self.subTest(sample=sample):
                self.assertTrue(client_data_findings(sample, set()))

    def test_synthetic_and_product_strings_are_allowed(self):
        samples = [
            "http://127.0.0.1:2667/mcp",
            "http://192.0.2.40:2667/mcp and http://… or http://<port>",
            "~/Library/Application Support/Compositor/mcp/endpoint.json",
            "com.wonderassembly.compositor.mcp.start",
            "Compositor.app/Contents/MacOS/compositor-mcp",
            "Replace 'Endorser Name' and 'Headline' in sample-template.psd",
            "https://modelcontextprotocol.io/specification",
            "jane@example.com",
            "call 555-0100 or (850) 555-0123",
            "/Users/Shared/Compositor",
            "docs/mcp.md, Imported.comp, config.toml",
        ]
        for sample in samples:
            with self.subTest(sample=sample):
                self.assertEqual(client_data_findings(sample, set()), [])


# MARK: - Skill structure

MARKDOWN_LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
SKILL_PATH = re.compile(r"`((?:references|scripts|agents|evals|assets)/[^`\s]+)`")
REPO_PATH = re.compile(r"`((?:docs|Compositor|CompositorTests|CompositorUITests|Tools|scripts|Config)/[^`\s]*)`")


def referenced_paths(skill, path, text):
    """(reference, candidate locations) for every relative file a skill file points at."""
    references = []
    for target in MARKDOWN_LINK.findall(text):
        if re.match(r"[a-z]+:", target) or target.startswith("#"):
            continue
        target = target.split("#", 1)[0]
        references.append((target, [path.parent / target]))
    for target in SKILL_PATH.findall(text):
        references.append((target, [skill / target, REPO / target]))
    for target in REPO_PATH.findall(text):
        references.append((target, [REPO / target, skill / target]))
    # Placeholders (`MCPTools+<Domain>.swift`) and patterns name no single file.
    return [(target, places) for target, places in references if not re.search(r"[<>*{}$]", target)]


# MARK: - Shell blocks

SHELL_FENCE = re.compile(r"(?ms)^([ \t]*)```(?:bash|sh|shell|zsh)[ \t]*\n(.*?)^\1```")
# Set by the shell or the login environment, so a fresh shell has them too.
SHELL_ENVIRONMENT = {"HOME", "PATH", "PWD", "OLDPWD", "USER", "LOGNAME", "SHELL", "TMPDIR"}
SHELL_ASSIGNMENT = re.compile(r"(?m)(?:^|[\s;&|(])(?:(?:export|local|readonly|declare)\s+)?([A-Za-z_]\w*)=")
SHELL_BINDING = re.compile(r"\b(?:for|read(?:\s+-\w+)*)\s+([A-Za-z_]\w*)")
SHELL_REFERENCE = re.compile(r"\$(?:\{([A-Za-z_]\w*)(:?[-=?+])?|([A-Za-z_]\w*))")


def shell_blocks(text):
    """The bodies of the bash/sh/zsh fenced code blocks in a markdown text, indented ones included."""
    return [match.group(2) for match in SHELL_FENCE.finditer(text)]


def shell_code(block):
    """A shell block with its comments removed and the insides of single quotes emptied (nothing expands there),
    read left to right as the shell does, so an apostrophe in a comment starts no quote and a # inside quotes starts
    no comment."""
    code, quote, index = [], None, 0
    while index < len(block):
        char = block[index]
        if quote == "'":
            if char == "'":
                quote = None
                code.append(char)
        elif quote == '"':
            code.append(char)
            if char == "\\" and index + 1 < len(block):
                code.append(block[index + 1])
                index += 1
            elif char == '"':
                quote = None
        elif char == "#" and (index == 0 or block[index - 1].isspace()):
            while index < len(block) and block[index] != "\n":
                index += 1
            continue
        else:
            code.append(char)
            if char in "'\"":
                quote = char
            elif char == "\\" and index + 1 < len(block):
                code.append(block[index + 1])
                index += 1
        index += 1
    return "".join(code)


def unset_shell_variables(block):
    """Variables a shell block reads without setting itself. Agents run each block in a fresh shell
    (Claude Code, Codex and `claude -p` keep no variables between commands), so a block that leans
    on an earlier block's variables runs with them empty."""
    code = shell_code(block)
    defined = set(SHELL_ASSIGNMENT.findall(code)) | set(SHELL_BINDING.findall(code)) | SHELL_ENVIRONMENT
    used = set()
    for braced, operator, plain in SHELL_REFERENCE.findall(code):
        if braced and operator in ("-", ":-", "=", ":="):
            continue  # ${NAME:-default} is fine unset
        used.add(braced or plain)
    return sorted(used - defined)


class ShellBlockMechanismTests(unittest.TestCase):
    def test_a_block_using_another_blocks_variables_is_flagged(self):
        text = '```bash\nDD=/private/tmp/dd\n```\n\n```bash\nxcodebuild -derivedDataPath "$DD" > "${DD}-build.log"\n```\n'
        self.assertEqual([unset_shell_variables(block) for block in shell_blocks(text)], [[], ["DD"]])

    def test_indented_blocks_in_lists_are_checked(self):
        text = '- the result bundle:\n\n  ```bash\n  ls -td "$DD"/Logs/Test/*.xcresult\n  ```\n'
        self.assertEqual([unset_shell_variables(block) for block in shell_blocks(text)], [["DD"]])

    def test_an_apostrophe_in_a_comment_hides_nothing(self):
        block = "# this checkout's own DerivedData\nls \"$REPO2\" '$NOT_EXPANDED'\necho \"$DD\"  # it's here\n"
        self.assertEqual(unset_shell_variables(block), ["DD", "REPO2"])

    def test_a_hash_inside_quotes_starts_no_comment(self):
        self.assertEqual(unset_shell_variables('echo "#rrggbb $COLOR" \'#$QUOTED\' $TAIL'), ["COLOR", "TAIL"])

    def test_variables_set_in_the_block_or_by_the_environment_are_fine(self):
        blocks = [
            'REPO=$(git rev-parse --show-toplevel)\nDD=/private/tmp/dd-$(basename "$REPO")\nls "$DD" "$HOME"',
            'for name in a b; do echo "$name"; done',
            "awk '{ print $NF }' file  # $NOT_CODE in a comment",
            'echo "${PORT:-2667}"',
            'export URL=http://127.0.0.1:2667/mcp; curl "$URL"',
        ]
        for block in blocks:
            with self.subTest(block=block):
                self.assertEqual(unset_shell_variables(block), [])


class SkillStructureTests(unittest.TestCase):
    def test_the_required_skills_exist(self):
        self.assertTrue(SKILLS.is_dir(), f"no skills folder at {SKILLS}")
        names = {path.name for path in skill_dirs()}
        self.assertEqual(REQUIRED_SKILLS - names, set(), "missing skills")

    def test_every_skill_folder_has_a_skill_md(self):
        for folder in sorted(path for path in SKILLS.iterdir() if path.is_dir()):
            with self.subTest(skill=folder.name):
                self.assertTrue((folder / "SKILL.md").is_file(), f"{folder.name} has no SKILL.md")

    def test_frontmatter_is_valid(self):
        for skill in skill_dirs():
            with self.subTest(skill=skill.name):
                fields = parse_frontmatter((skill / "SKILL.md").read_text(encoding="utf-8"))
                self.assertEqual(set(fields) - ALLOWED_FRONTMATTER, set(), "unexpected frontmatter keys")
                self.assertEqual(fields.get("name"), skill.name, "name must match the folder")
                self.assertRegex(fields["name"], r"\A[a-z0-9]+(-[a-z0-9]+)*\Z")
                self.assertLessEqual(len(fields["name"]), 64)
                description = fields.get("description", "")
                self.assertTrue(description.strip(), "description is empty")
                self.assertLessEqual(len(description), MAX_DESCRIPTION, "description is too long")
                self.assertNotRegex(description, r"[<>]", "descriptions cannot contain angle brackets")

    def test_skill_md_stays_under_500_lines(self):
        for skill in skill_dirs():
            with self.subTest(skill=skill.name):
                lines = (skill / "SKILL.md").read_text(encoding="utf-8").count("\n")
                self.assertLess(lines, MAX_SKILL_LINES)

    def test_long_references_open_with_a_table_of_contents(self):
        for skill in skill_dirs():
            for path in sorted((skill / "references").glob("*.md")):
                text = path.read_text(encoding="utf-8")
                if text.count("\n") <= TOC_THRESHOLD:
                    continue
                with self.subTest(file=str(path.relative_to(SKILLS))):
                    head = "\n".join(text.splitlines()[:40])
                    self.assertRegex(head, r"(?im)^#+ (table of )?contents\s*$")

    def test_referenced_files_exist(self):
        for skill in skill_dirs():
            for path in skill_text_files(skill):
                if path.suffix != ".md":
                    continue
                text = path.read_text(encoding="utf-8")
                for target, places in referenced_paths(skill, path, text):
                    with self.subTest(file=str(path.relative_to(SKILLS)), reference=target):
                        self.assertTrue(any(place.exists() for place in places), f"{target} does not exist")

    def test_every_shell_block_sets_the_variables_it_uses(self):
        # An agent runs each block as its own command in a fresh shell; a variable from an earlier
        # block would expand to nothing (`-derivedDataPath ""`, logs named `-build.log`).
        for skill in skill_dirs():
            for path in sorted(skill.rglob("*.md")):
                for block in shell_blocks(path.read_text(encoding="utf-8")):
                    with self.subTest(file=str(path.relative_to(SKILLS)), block=block.strip().splitlines()[0]):
                        self.assertEqual(unset_shell_variables(block), [], "set these in the block itself")

    def test_bundled_shell_scripts_are_executable(self):
        for script in sorted(SKILLS.glob("*/scripts/*.sh")):
            with self.subTest(script=str(script.relative_to(SKILLS))):
                self.assertTrue(os.access(script, os.X_OK))

    def test_evals_are_well_formed(self):
        for skill in skill_dirs():
            with self.subTest(skill=skill.name):
                path = skill / "evals" / "evals.json"
                self.assertTrue(path.is_file(), "no evals/evals.json")
                data = json.loads(path.read_text(encoding="utf-8"))
                self.assertEqual(data.get("skill_name"), skill.name)
                evals = data.get("evals")
                self.assertIsInstance(evals, list)
                self.assertGreaterEqual(len(evals), 2)
                ids = [case.get("id") for case in evals]
                self.assertTrue(all(isinstance(value, int) for value in ids), "ids must be integers")
                self.assertEqual(len(ids), len(set(ids)), "ids must be unique")
                for case in evals:
                    self.assertTrue(isinstance(case.get("prompt"), str) and case["prompt"].strip())
                    self.assertTrue(isinstance(case.get("expected_output"), str) and case["expected_output"].strip())
                    for name in case.get("files", []):
                        self.assertTrue((skill / name).exists(), f"eval {case['id']}: {name} does not exist")
                    expectations = case.get("expectations", [])
                    self.assertTrue(all(isinstance(item, str) and item.strip() for item in expectations))

    def test_codex_interface_metadata(self):
        for skill in skill_dirs():
            with self.subTest(skill=skill.name):
                path = skill / "agents" / "openai.yaml"
                self.assertTrue(path.is_file(), "no agents/openai.yaml")
                fields = parse_openai_yaml(path.read_text(encoding="utf-8"))
                for key in ("display_name", "short_description", "default_prompt"):
                    self.assertTrue(fields.get(key, "").strip(), f"interface.{key} is missing")

    def test_skills_hold_no_client_or_personal_data(self):
        for skill in skill_dirs():
            for path in skill_files(skill):
                with self.subTest(file=str(path.relative_to(SKILLS))):
                    self.assertEqual(skill_findings(skill, path), [])

    def test_setup_snippets_match_what_the_app_generates(self):
        # MCPClientSnippetsTests pins the exact text Compositor > Settings… offers for the default port. The Codex
        # over HTTP setup's export line names the token file by its absolute path there, so only its add line is
        # compared.
        tests = (REPO / "CompositorTests" / "MCPClientSnippetsTests.swift").read_text(encoding="utf-8")
        claude_code = re.search(r'claudeCodeRunsTheBridgeWhichNeedsNoToken.*?== "(claude mcp add [^"]+)"', tests, re.S).group(1)
        claude_code_http = re.search(r'claudeCodeOverHTTPSendsTheTokenAsAHeader.*?== #"(claude mcp add [^\n]*?)"#', tests, re.S).group(1)
        codex = re.search(r'codexRunsTheBridgeWhichNeedsNoToken.*?== "(codex mcp add [^"]+)"', tests, re.S).group(1)
        codex_http = re.search(r'codexOverHTTPReadsTheTokenFromTheEnvironment.*?\n\s*(codex mcp add [^\n]+)\n', tests, re.S).group(1)
        desktop = re.search(r'claudeDesktopRunsTheBridge.*?== #"(.*?)"#', tests, re.S).group(1)
        setup = SKILLS / "compositor-setup"
        text = "\n".join(path.read_text(encoding="utf-8") for path in [setup / "SKILL.md", *sorted(setup.glob("references/*.md"))])
        for snippet in (claude_code, claude_code_http, codex, codex_http, desktop):
            with self.subTest(snippet=snippet):
                self.assertIn(snippet, text)
        self.assertIn("-- /Applications/Compositor.app/Contents/MacOS/compositor-mcp", claude_code)
        self.assertIn('--header "Authorization: Bearer <token>"', claude_code_http)
        self.assertIn("--bearer-token-env-var COMPOSITOR_MCP_TOKEN", codex_http)


# MARK: - Tool names

# Tools and names a skill may mention before the running app lists them (while a track that adds them is still in
# progress). Both are empty once the atlas is regenerated from the app that has them; test_pending_names_are_not_in_
# the_atlas fails for any name the atlas has gained, so a stale entry can't linger.
PENDING_TOOLS = frozenset()
PENDING_NAMES = frozenset()

# Result fields, guard names and error codes the skills quote that start with a tool's verb but are not tools.
NOT_TOOLS = frozenset({
    "undo_names", "redo_names", "layer_id", "layer_ids", "layer_name", "layer_locked", "layer_count",
    "content_bounds", "effects_bounds", "pixel_content_bounds", "set_as_current", "select_all_layers",
    "list_files_recursive", "get_document_full",
    # compositor-development's testing reference invents this tool to show how a tool test reads.
    "set_layer_note",
})
TOOL_LIKE = re.compile(r"`([a-z][a-z0-9]*(?:_[a-z0-9]+)+)(?:\([^`]*\))?`")
TOOL_FIELD = re.compile(r'"tool"\s*:\s*"([^"]+)"')


def atlas_tools():
    return set(re.findall(r"(?m)^### `([a-z0-9_]+)`", ATLAS.read_text(encoding="utf-8")))


def atlas_parameters():
    """Every parameter and member name the atlas lists (`region.x` gives region and x), and every other name it
    quotes, such as enum values (`reveal_all`, `add_noise`)."""
    text = ATLAS.read_text(encoding="utf-8")
    rows = re.findall(r"(?m)^\| `([a-z0-9_.\[\]]+)` \|", text)
    names = {part for row in rows for part in re.split(r"\.|\[\]\.?", row) if part}
    return names | set(re.findall(r"`([a-z0-9_]+)`", text))


def tool_verbs(tools):
    return {name.split("_")[0] for name in tools}


def unknown_tool_mentions(text, tools, parameters):
    """Backticked snake_case names that read like a tool (they start with a tool's verb: set_, add_, render_…) but
    are neither a tool, a name the atlas quotes (parameters, enum values), a pending name nor a known result field;
    and any `"tool": "…"` value that isn't a tool."""
    verbs = tool_verbs(tools)
    unknown = set()
    for name in TOOL_LIKE.findall(text):
        if name.split("_")[0] in verbs and name not in tools | parameters | PENDING_NAMES | NOT_TOOLS:
            unknown.add(name)
    unknown |= {name for name in TOOL_FIELD.findall(text) if name not in tools}
    return sorted(unknown)


def atlas_rows():
    """{tool: the parameter rows its atlas table lists}: `layer`, `style.font_name`, `steps[].tool`."""
    rows, tool = {}, None
    for line in ATLAS.read_text(encoding="utf-8").splitlines():
        heading = re.match(r"^### `([a-z0-9_]+)`", line)
        if heading:
            tool = heading.group(1)
            rows[tool] = set()
        elif tool and line.startswith("| `"):
            rows[tool].add(re.match(r"^\| `([^`]+)` \|", line).group(1))
    return rows


def unknown_arguments(arguments, rows, prefix=""):
    """Argument names (dotted, as the atlas writes them) that the tool's schema doesn't have. An object's members are
    checked when the atlas lists members for it; small value objects (a color, a point) have none and pass."""
    unknown = []
    for key, value in arguments.items():
        path = prefix + key
        if path not in rows:
            unknown.append(path)
        elif isinstance(value, dict) and any(row.startswith(path + ".") for row in rows):
            unknown += unknown_arguments(value, rows, path + ".")
        elif isinstance(value, list) and any(row.startswith(path + "[].") for row in rows):
            for item in value:
                if isinstance(item, dict):
                    unknown += unknown_arguments(item, rows, path + "[].")
    return unknown


def documented_calls(text):
    """Every {"tool": …, "arguments": {…}} object a document spells out (run_batch steps, recipes)."""
    decoder, calls = json.JSONDecoder(), []
    for match in re.finditer(r'\{\s*"tool"\s*:', text):
        try:
            value, _ = decoder.raw_decode(text[match.start():])
        except ValueError:
            continue
        if isinstance(value, dict) and isinstance(value.get("arguments"), dict):
            calls.append(value)
    return calls


# Words that mark text as waiting on work in progress; none may stay once PENDING_TOOLS and PENDING_NAMES are empty.
PROVISIONAL = re.compile(r"<!-- PENDING|\bprovisional\b|\b5\.5b|\bTrack [A-Z][0-9]?\b|writer in progress", re.I)


class ArgumentMechanismTests(unittest.TestCase):
    ROWS = {"layer", "style", "style.font_name", "style.color", "steps", "steps[].tool", "steps[].arguments", "fill"}

    def test_unknown_names_are_flagged_at_every_level(self):
        arguments = {"layer": "A", "style": {"font_name": "X", "font": "Y"}, "fil": "#fff",
                     "steps": [{"tool": "t", "args": {}}]}
        self.assertEqual(unknown_arguments(arguments, self.ROWS), ["style.font", "fil", "steps[].args"])

    def test_value_objects_without_member_rows_pass(self):
        self.assertEqual(unknown_arguments({"fill": {"r": 1, "g": 0, "b": 0}, "style": {"color": {"r": 1}}},
                                           self.ROWS), [])

    def test_documented_calls_are_found_in_prose(self):
        text = 'Batch: `{"tool": "move_layer", "arguments": {"layer": "A", "dx": 4}}` and {"tool": "undo"}.'
        self.assertEqual(documented_calls(text), [{"tool": "move_layer", "arguments": {"layer": "A", "dx": 4}}])


class ToolNameMechanismTests(unittest.TestCase):
    TOOLS = {"delete_layers", "reveal_in_finder", "render_document", "set_layer_opacity"}
    PARAMETERS = {"set_as_current", "opacity"}

    def test_a_renamed_or_invented_tool_is_flagged(self):
        text = "Call `delete_layer` then `reveal_folder(path)` and `render_documents`."
        self.assertEqual(unknown_tool_mentions(text, self.TOOLS, self.PARAMETERS),
                         ["delete_layer", "render_documents", "reveal_folder"])

    def test_tools_parameters_and_other_words_pass(self):
        text = ("`delete_layers`, `set_layer_opacity(layer, opacity)`, `set_as_current`, `opacity`, `can_edit_layers`,"
                " `file_exists`, `mcp__compositor__render_document`, `layer_id`")
        self.assertEqual(unknown_tool_mentions(text, self.TOOLS, self.PARAMETERS), [])

    def test_tool_fields_in_json_must_be_tools(self):
        text = '[{"tool": "render_document", "arguments": {}}, {"tool": "set_as_current"}]'
        self.assertEqual(unknown_tool_mentions(text, self.TOOLS, self.PARAMETERS), ["set_as_current"])


class ToolAtlasTests(unittest.TestCase):
    def test_the_atlas_is_generated_and_every_tool_has_a_domain(self):
        text = ATLAS.read_text(encoding="utf-8")
        self.assertTrue(text.startswith("# Compositor tool atlas\n"))
        self.assertIn("by `scripts/tool-atlas.py`", "\n".join(text.splitlines()[:8]))
        count = int(re.search(r"\b(\d+) tools in \d+ groups", text).group(1))
        self.assertEqual(count, len(atlas_tools()))
        self.assertGreaterEqual(count, 100)
        self.assertNotRegex(text, r"(?m)^## Other$", "add the new tools to DOMAINS in tool-atlas.py")

    def test_the_contents_list_follows_the_generators_domains(self):
        spec = importlib.util.spec_from_file_location("tool_atlas", SKILLS / "compositor" / "scripts" / "tool-atlas.py")
        module = importlib.util.module_from_spec(spec)
        # No __pycache__ inside the skill: it would be installed and packaged with it.
        previous, sys.dont_write_bytecode = sys.dont_write_bytecode, True
        try:
            spec.loader.exec_module(module)
        finally:
            sys.dont_write_bytecode = previous
        text, tools = ATLAS.read_text(encoding="utf-8"), atlas_tools()
        for domain, names in module.DOMAINS:
            listed = [name for name in names if name in tools]
            if listed:
                with self.subTest(domain=domain):
                    self.assertIn(f"- [{domain}](#{module.anchor(domain)}) ({len(listed)}):", text)

    def test_pending_names_are_not_in_the_atlas(self):
        tools, parameters = atlas_tools(), atlas_parameters()
        self.assertEqual(sorted(PENDING_TOOLS & tools), [], "these tools are in the atlas now: drop them from PENDING_TOOLS")
        self.assertEqual(sorted(PENDING_NAMES & (tools | parameters)), [], "drop these from PENDING_NAMES")

    def test_every_tool_a_skill_mentions_exists(self):
        tools = atlas_tools() | PENDING_TOOLS
        parameters = atlas_parameters()
        for skill in skill_dirs():
            for path in skill_text_files(skill):
                if path == ATLAS:
                    continue
                with self.subTest(file=str(path.relative_to(SKILLS))):
                    self.assertEqual(unknown_tool_mentions(path.read_text(encoding="utf-8"), tools, parameters), [])

    def test_calls_the_skills_spell_out_use_only_their_tools_parameters(self):
        # Fixture recipes and run_batch examples are copied by agents and replayed by the eval harness: every argument
        # name must be one tools/list gives that tool (nested members included).
        rows = atlas_rows()
        for skill in skill_dirs():
            for path in skill_text_files(skill):
                if path == ATLAS:
                    continue
                text = path.read_text(encoding="utf-8")
                calls = documented_calls(text)
                if path.name == "fixtures.json":
                    calls += [call for fixture in json.loads(text).get("fixtures", []) for call in fixture["calls"]]
                for call in calls:
                    if call["tool"] in rows:
                        with self.subTest(file=str(path.relative_to(SKILLS)), tool=call["tool"]):
                            self.assertEqual(unknown_arguments(call.get("arguments") or {}, rows[call["tool"]]), [])

    def test_no_skill_is_marked_provisional_once_nothing_is_pending(self):
        if PENDING_TOOLS or PENDING_NAMES:
            self.skipTest("names are still pending")
        for skill in skill_dirs():
            for path in skill_text_files(skill):
                with self.subTest(file=str(path.relative_to(SKILLS))):
                    lines = [line.strip()[:120] for line in path.read_text(encoding="utf-8").splitlines()
                             if PROVISIONAL.search(line)]
                    self.assertEqual(lines, [], "verify the item against the running app, then drop the marker")

    def test_a_reference_using_pending_tools_says_so(self):
        # A provisional parameter list must be marked, so 5.5b-2 knows what to check against tools/list.
        for skill in skill_dirs():
            for path in sorted(skill.rglob("*.md")):
                text = path.read_text(encoding="utf-8")
                mentioned = {name for name in TOOL_LIKE.findall(text) if name in PENDING_TOOLS}
                if not mentioned or path.name == "SKILL.md":
                    continue
                with self.subTest(file=str(path.relative_to(SKILLS)), tools=sorted(mentioned)):
                    self.assertRegex("\n".join(text.splitlines()[:6]), r"<!-- PENDING")


# MARK: - Eval fixtures

class EvalFixtureTests(unittest.TestCase):
    def fixture_files(self):
        return sorted(SKILLS.glob("*/evals/fixtures.json"))

    def test_fixture_recipes_are_tool_calls_and_image_specs(self):
        tools = atlas_tools() | PENDING_TOOLS
        self.assertTrue(self.fixture_files(), "no evals/fixtures.json in any skill")
        for path in self.fixture_files():
            with self.subTest(file=str(path.relative_to(SKILLS))):
                data = json.loads(path.read_text(encoding="utf-8"))
                self.assertEqual(data.get("skill_name"), path.parents[1].name)
                for image in data.get("images", []):
                    self.assertRegex(image.get("path", ""), r"\A[\w./-]+\.png\Z", "images are PNGs at relative paths")
                    self.assertTrue(isinstance(image.get("width"), int) and isinstance(image.get("height"), int))
                    self.assertIn(image.get("kind"), {"solid", "linear_gradient", "radial_gradient", "checker", "disc"})
                fixtures = data.get("fixtures")
                self.assertIsInstance(fixtures, list)
                self.assertTrue(fixtures or data.get("images"), "a recipe builds at least one image or fixture")
                for fixture in fixtures:
                    self.assertRegex(fixture.get("id", ""), r"\A[a-z0-9-]+\Z")
                    self.assertTrue(fixture.get("description", "").strip())
                    calls = fixture.get("calls")
                    self.assertTrue(isinstance(calls, list) and calls)
                    for call in calls:
                        self.assertEqual(set(call) - {"tool", "arguments", "note"}, set())
                        self.assertIn(call.get("tool"), tools)
                        self.assertIsInstance(call.get("arguments", {}), dict)

    def test_recipe_images_have_paths_of_their_own_across_skills(self):
        # Two recipes writing different images to one path would overwrite each other in a shared fixture folder.
        seen = {}
        for path in self.fixture_files():
            for image in json.loads(path.read_text(encoding="utf-8")).get("images", []):
                with self.subTest(image=image["path"], file=str(path.relative_to(SKILLS))):
                    self.assertNotIn(image["path"], seen, f"also written by {seen.get(image['path'])}")
                    seen[image["path"]] = path.parents[1].name

    def test_evals_name_only_fixtures_that_exist(self):
        for skill in skill_dirs():
            evals = json.loads((skill / "evals" / "evals.json").read_text(encoding="utf-8"))["evals"]
            wanted = {name for case in evals for name in case.get("fixtures", [])}
            if not wanted:
                continue
            with self.subTest(skill=skill.name):
                path = skill / "evals" / "fixtures.json"
                self.assertTrue(path.is_file(), "evals name fixtures but there is no evals/fixtures.json")
                data = json.loads(path.read_text(encoding="utf-8"))
                known = {fixture["id"] for fixture in data["fixtures"]} | {image["path"] for image in data.get("images", [])}
                self.assertEqual(wanted - known, set())

    def test_workflow_skills_have_two_to_four_evals_with_expectations(self):
        for name in REQUIRED_SKILLS - {"compositor-setup", "compositor-development"}:
            with self.subTest(skill=name):
                evals = json.loads((SKILLS / name / "evals" / "evals.json").read_text(encoding="utf-8"))["evals"]
                self.assertTrue(2 <= len(evals) <= 4)
                for case in evals:
                    self.assertGreaterEqual(len(case.get("expectations", [])), 3)


# MARK: - What eval expectations measure

# Where a layer's pixels lie is not its transform or its bounds: a layer made with add_blank_layer stays canvas-sized
# however little of it is filled, a folder's transform is canvas-sized, and a text layer's box (its transform, `bounds`,
# get_text_metrics `bounds` and `box`) adds 12 px of padding on every side. An expectation that pins where a layer's
# pixels are must say it measures what shows, or a correct run fails it.
EXTENT_CLAIM = re.compile(r"(?<![\w.])bounds\b|\bpx (?:tall|wide)\b|\bspans?\b|\btop at y\b|\btransform x \+ width\b", re.I)
WHAT_SHOWS = re.compile(r"\bcontent_bounds\b|\bsample_colors\b|\bget_pixel_color\b|\bget_text_metrics width\b")


def measures_a_layer_by_its_box(expectation):
    """True when an expectation pins a layer's extent without naming a measure of the pixels that show."""
    return bool(EXTENT_CLAIM.search(expectation)) and not WHAT_SHOWS.search(expectation)


class EvalMeasureMechanismTests(unittest.TestCase):
    def test_extents_read_from_a_layers_box_are_flagged(self):
        for claim in [
            "The band layer spans the full 1080 px width, is 160 px tall with its top at y 460, and has opacity 0.4",
            "Before export, get_layer_bounds or get_text_metrics for the Name layer shows its bounds within x 60 to 1020",
            "Every text layer's bounds lies between y 250 and y 1580",
            "the Headline layer's horizontal center (transform x + width / 2) is within 1 px of 540",
        ]:
            with self.subTest(claim=claim):
                self.assertTrue(measures_a_layer_by_its_box(claim))

    def test_extents_measured_by_what_shows_and_other_checks_pass(self):
        for claim in [
            "get_layer_bounds on the band layer reports content_bounds x 0, y 460, width 1080, height 160",
            "sample_colors at (20, 462) is lighter than the navy background; its bounds are not the measure",
            "get_text_metrics width times scale.x is at most 960",
            "out/quote-story.png exists and is 1080 x 1920 pixels",
            "In the new PSD's psd-verify --json report, the Accent Bar layer's bbox top is 24 px lower",
            "The top-level Logo layer's transform is identical in both files",
        ]:
            with self.subTest(claim=claim):
                self.assertFalse(measures_a_layer_by_its_box(claim))


class EvalMeasureTests(unittest.TestCase):
    def test_expectations_place_layers_by_the_pixels_that_show(self):
        for skill in skill_dirs():
            evals = json.loads((skill / "evals" / "evals.json").read_text(encoding="utf-8"))["evals"]
            for case in evals:
                for expectation in case.get("expectations", []):
                    if measures_a_layer_by_its_box(expectation):
                        with self.subTest(skill=skill.name, eval=case.get("id")):
                            self.fail("measure with content_bounds or pixel samples, not the layer's box: " + expectation)


# A width limit doesn't say where a layer sits. set_text and fit_text keep a text layer's top-left corner, so centered
# text shrunk to fit but never re-centered is narrow enough and still off the side of the canvas. Every alternative in
# an expectation that limits a layer's width (the parts joined by "or" outside parentheses) must also pin its position:
# centered on a point, or within an x range.
WIDTH_LIMIT = re.compile(
    r"(?<![\w.])width\b(?: times scale\.x)?(?: \([^()]*\))?(?: is)? (?:at most|no more than|under|below|≤|<=) \d"
    r"|\bat most \d+ px wide\b|\bno wider than \d", re.I)
POSITION = re.compile(r"\bcent(?:er|re)(?:ed|d)?\b|\bcenter_x\b|\bwithin x -?\d+ to -?\d+\b", re.I)


def alternatives(expectation):
    """The parts of an expectation joined by "or" outside parentheses, each with its parenthesized text kept."""
    parts, depth, start = [], 0, 0
    for match in re.finditer(r"[()]|\bor\b", expectation):
        token = match.group(0)
        if token == "(":
            depth += 1
        elif token == ")":
            depth = max(0, depth - 1)
        elif depth == 0:
            parts.append(expectation[start:match.start()])
            start = match.end()
    parts.append(expectation[start:])
    return parts


def width_limits_without_a_position(expectation):
    """The alternatives of an expectation that limit a layer's width without saying where the layer sits."""
    return [part.strip() for part in alternatives(" ".join(expectation.split()))
            if WIDTH_LIMIT.search(part) and not POSITION.search(part)]


class EvalPlacementMechanismTests(unittest.TestCase):
    def test_a_width_limit_alone_is_flagged(self):
        for claim in [
            "Before export, the Name layer is a single line whose text is at most 960 px wide, measured without the "
            "text box's 12 px padding: get_text_metrics (or the fit_text result's metrics) shows line_count 1 and width "
            "times scale.x at most 960, or get_layer_bounds shows content_bounds within x 60 to 1020",
            "get_text_metrics width times scale.x is at most 1000",
            "its text width (get_text_metrics width times scale.x) at most 1000",
            "the Subhead's content_bounds lie within x 40 to 1040, or its text is no wider than 1000",
        ]:
            with self.subTest(claim=claim):
                self.assertNotEqual(width_limits_without_a_position(claim), [])

    def test_a_width_limit_with_a_position_and_other_checks_pass(self):
        for claim in [
            "get_text_metrics (or the fit_text result's metrics) shows width times scale.x at most 960 and the Name is "
            "centered within 2 px of x 540 (its transform center_x, or the center of its content_bounds); or "
            "get_layer_bounds shows content_bounds within x 60 to 1020",
            "the Subhead's letters lie within x 40 to 1040: its content_bounds (get_layer_bounds in the transcript), or "
            "its text width (get_text_metrics width times scale.x) at most 1000 when centered at 540",
            "The transcript shows fit_text on the Name layer with max_width at most 960, or set_text_style lowering its "
            "font_size",
            "A PNG in out/ is 1080 x 1350 (sips -g pixelWidth -g pixelHeight)",
        ]:
            with self.subTest(claim=claim):
                self.assertEqual(width_limits_without_a_position(claim), [])

    def test_or_inside_parentheses_does_not_split(self):
        self.assertEqual(alternatives("a (b or c) d or e"), ["a (b or c) d ", " e"])


class EvalPlacementTests(unittest.TestCase):
    def test_width_limits_also_pin_where_the_layer_sits(self):
        for skill in skill_dirs():
            evals = json.loads((skill / "evals" / "evals.json").read_text(encoding="utf-8"))["evals"]
            for case in evals:
                for expectation in case.get("expectations", []):
                    unplaced = width_limits_without_a_position(expectation)
                    if unplaced:
                        with self.subTest(skill=skill.name, eval=case.get("id")):
                            self.fail("a width limit needs a position (centered, or within x A to B) in the same "
                                      f"alternative: {unplaced}")


# MARK: - Layer ids across a revert

# PSDReader gives every layer a new UUID each time it reads a file, and revert_document reads the file again, as opening
# does: after a revert or reopen of a document opened from a PSD or an image, every layer id noted before it fails as
# not_found. A skill must not promise ids for the whole session, and a loop that reverts between rows must re-read the
# layers after each revert.
SESSION_LONG_IDS = re.compile(r"(?i)\bids? (?:last|lasts|stay|stays|hold|holds)(?: the same)? for the (?:whole )?session\b")
ROW_LOOP = re.compile(r"(?i)\b(?:each|per|every|next) row\b|\bfor each (?:person|row)\b")
NEW_IDS = re.compile(r"(?i)\bnew (?:layer )?ids?\b")


def row_loops_without_a_fresh_layer_map(text):
    """First lines of the Markdown sections that revert a document between rows but don't re-read its layers after."""
    missing = []
    for section in re.split(r"(?m)^#{1,6} ", text):
        flat = " ".join(section.split())
        at = flat.find("`revert_document`")
        if at < 0 or not ROW_LOOP.search(flat):
            continue
        if "`get_document`" not in flat[at:] or not NEW_IDS.search(flat):
            missing.append(section.splitlines()[0] if section.strip() else "")
    return missing


class LayerIdMechanismTests(unittest.TestCase):
    def test_a_row_loop_reusing_ids_after_a_revert_is_flagged(self):
        text = ("## Many people, one template\n\nRepeat per row from the pristine template: save the row, then "
                "`revert_document` with `discard_changes: true` reloads the template for the next one.\n")
        self.assertEqual(row_loops_without_a_fresh_layer_map(text), ["Many people, one template"])

    def test_a_row_loop_that_re_reads_the_layers_passes(self):
        text = ("## Rows\n\nRepeat per row. After `revert_document` every layer has a new id: run `get_document` "
                "again and rebuild the slot map.\n\n## Other\n\n`revert_document` once, with no rows.\n")
        self.assertEqual(row_loops_without_a_fresh_layer_map(text), [])

    def test_a_session_long_promise_is_flagged(self):
        self.assertRegex("Layer ids last\nfor the session;".replace("\n", " "), SESSION_LONG_IDS)
        self.assertNotRegex("A layer id lasts while the document stays open", SESSION_LONG_IDS)


class LayerIdTests(unittest.TestCase):
    def markdown_files(self):
        return [path for skill in skill_dirs() for path in sorted(skill.rglob("*.md")) if path != ATLAS]

    def test_no_skill_promises_layer_ids_for_the_session(self):
        for path in self.markdown_files():
            with self.subTest(file=str(path.relative_to(SKILLS))):
                found = SESSION_LONG_IDS.search(" ".join(path.read_text(encoding="utf-8").split()))
                self.assertIsNone(found, f"'{found and found.group(0)}': a revert or reopen of a PSD gives new ids")

    def test_row_loops_re_read_the_layers_after_each_revert(self):
        for path in self.markdown_files():
            with self.subTest(file=str(path.relative_to(SKILLS))):
                self.assertEqual(row_loops_without_a_fresh_layer_map(path.read_text(encoding="utf-8")), [])

    def test_addressing_says_a_revert_gives_a_psds_layers_new_ids(self):
        text = (SKILLS / "compositor" / "references" / "addressing.md").read_text(encoding="utf-8")
        layers = " ".join(text.split("\n## Layers\n", 1)[1].split("\n## ", 1)[0].split())
        for needed in ["`revert_document`", "`get_document`"]:
            self.assertTrue(needed in layers, f"the Layers section doesn't mention {needed}")
        self.assertTrue(NEW_IDS.search(layers), "the Layers section doesn't say a revert gives new ids")


# MARK: - Script paths

BARE_SCRIPT = re.compile(r"(?:^|[\s;&|(])(?:bash |sh |python3 (?:-\w+ )*)?(scripts/[\w.-]+\.(?:sh|py))")


class ScriptPathTests(unittest.TestCase):
    def test_bundled_scripts_are_run_by_a_path_through_the_skill_folder(self):
        # Agents run commands from the user's project, not the skill's folder, so `scripts/x.sh` finds nothing there;
        # a bundled script is named through the skill's base directory. Repository scripts (`scripts/psd-verify.py`
        # from a Compositor checkout) are fine.
        for skill in skill_dirs():
            for path in sorted(skill.rglob("*.md")):
                for block in shell_blocks(path.read_text(encoding="utf-8")):
                    for script in BARE_SCRIPT.findall(block):
                        with self.subTest(file=str(path.relative_to(SKILLS)), script=script):
                            bundled_only = any((other / script).exists() for other in skill_dirs()) and not (REPO / script).exists()
                            self.assertFalse(bundled_only, "write <skill folder>/" + script)


# MARK: - check-compositor.sh

class FakeEndpoint:
    """A loopback HTTP server standing in for Compositor's MCP endpoint: answers every POST with
    `status` and `body` (with a `token`, 401 to a request without `Authorization: Bearer <token>`), and
    records each request's method, headers and body."""

    def __init__(self, status=200, body=None, token=None):
        self.status = status
        self.body = body if body is not None else {"jsonrpc": "2.0", "id": "check-compositor", "result": {}}
        self.token = token
        self.requests = []
        endpoint = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers.get("Content-Length", 0))
                endpoint.requests.append({"method": "POST", "path": self.path,
                                          "headers": {k.lower(): v for k, v in self.headers.items()},
                                          "body": self.rfile.read(length)})
                payload = json.dumps(endpoint.body).encode() if not isinstance(endpoint.body, bytes) else endpoint.body
                status = endpoint.status
                if endpoint.token and self.headers.get("Authorization") != f"Bearer {endpoint.token}":
                    status, payload = 401, b'{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Unauthorized"}}'
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        self.url = f"http://127.0.0.1:{self.port}/mcp"

    def __enter__(self):
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        return self

    def __exit__(self, *exc):
        self.server.shutdown()
        self.server.server_close()


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class CheckCompositorTests(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="check-compositor-home-"))
        self.endpoint_file = self.home / "Library" / "Application Support" / "Compositor" / "mcp" / "endpoint.json"
        # A live process whose command name is "Compositor", like the app the endpoint file names.
        self.app = subprocess.Popen(["/bin/bash", "-c", "exec -a Compositor /bin/sleep 60"])
        self.addCleanup(self.stop_app)

    def stop_app(self):
        self.app.kill()
        self.app.wait()
        subprocess.run(["rm", "-rf", str(self.home)], check=False)

    def write_endpoint(self, url, port, pid=None, **extra):
        record = {"url": url, "port": port, "pid": self.app.pid if pid is None else pid, "app_version": "9.9",
                  "protocol": "2025-11-25", "transport": "streamable-http-stateless",
                  "started_at": "2026-09-23T10:00:00Z", **extra}
        self.endpoint_file.parent.mkdir(parents=True, exist_ok=True)
        self.endpoint_file.write_text(json.dumps(record, indent=2))

    def run_check(self, *args):
        env = {**os.environ, "HOME": str(self.home)}
        result = subprocess.run(["/bin/bash", str(CHECK), *args], capture_output=True, text=True, env=env, timeout=30)
        return result.returncode, result.stdout, result.stderr

    def test_a_live_endpoint_reports_ok_in_one_line(self):
        with FakeEndpoint() as endpoint:
            self.write_endpoint(endpoint.url, endpoint.port)
            code, out, err = self.run_check()
        self.assertEqual(code, 0, out + err)
        first = out.splitlines()[0]
        self.assertTrue(first.startswith("compositor: OK "), first)
        self.assertIn(endpoint.url, first)
        self.assertIn("9.9", first)
        self.assertIn(str(self.app.pid), first)

    def test_the_probe_is_a_json_rpc_ping_compositor_accepts(self):
        with FakeEndpoint() as endpoint:
            self.write_endpoint(endpoint.url, endpoint.port)
            self.run_check()
        self.assertEqual(len(endpoint.requests), 1)
        request = endpoint.requests[0]
        self.assertEqual(request["path"], "/mcp")
        headers = request["headers"]
        self.assertEqual(headers.get("content-type"), "application/json")
        self.assertIn("application/json", headers.get("accept", ""))
        self.assertIn("text/event-stream", headers.get("accept", ""))
        self.assertNotIn("origin", headers, "Compositor refuses any request with an Origin header")
        self.assertEqual(headers.get("host"), f"127.0.0.1:{endpoint.port}")
        body = json.loads(request["body"])
        self.assertEqual((body["jsonrpc"], body["method"]), ("2.0", "ping"))
        self.assertIn("id", body)

    def test_a_port_other_than_2667_is_pointed_out(self):
        with FakeEndpoint() as endpoint:
            self.write_endpoint(endpoint.url, endpoint.port)
            code, out, _ = self.run_check()
        self.assertEqual(code, 0)
        self.assertRegex(out, r"(?m)^note: .*2667")

    def test_no_endpoint_file_means_not_running_with_ways_to_start_it(self):
        code, out, _ = self.run_check()
        self.assertEqual(code, 1)
        self.assertTrue(out.startswith("compositor: NOT RUNNING"), out)
        self.assertRegex(out, r"(?m)^fix: .*--mcp")
        self.assertRegex(out, r"(?m)^fix: .*Settings")

    def test_an_unreadable_endpoint_file_is_reported(self):
        self.endpoint_file.parent.mkdir(parents=True)
        self.endpoint_file.write_text("{ not json")
        code, out, _ = self.run_check()
        self.assertEqual(code, 1)
        self.assertTrue(out.startswith("compositor: BROKEN ENDPOINT FILE"), out)

    def test_a_dead_pid_means_a_stale_endpoint_file(self):
        finished = subprocess.Popen(["/usr/bin/true"])
        finished.wait()
        with FakeEndpoint() as endpoint:
            self.write_endpoint(endpoint.url, endpoint.port, pid=finished.pid)
            code, out, _ = self.run_check()
        self.assertEqual(code, 1)
        self.assertTrue(out.startswith("compositor: STALE"), out)
        self.assertEqual(endpoint.requests, [], "a stale endpoint must not be probed")
        self.assertRegex(out, r"(?m)^fix: ")

    def test_a_pid_reused_by_another_program_means_a_stale_endpoint_file(self):
        with FakeEndpoint() as endpoint:
            self.write_endpoint(endpoint.url, endpoint.port, pid=os.getpid())
            code, out, _ = self.run_check()
        self.assertEqual(code, 1)
        self.assertTrue(out.startswith("compositor: STALE"), out)

    def test_nothing_listening_is_reported_with_a_fix(self):
        port = free_port()
        self.write_endpoint(f"http://127.0.0.1:{port}/mcp", port)
        code, out, _ = self.run_check()
        self.assertEqual(code, 1)
        self.assertTrue(out.startswith("compositor: NOT LISTENING"), out)
        self.assertRegex(out, r"(?m)^fix: ")

    def test_http_refusals_explain_themselves(self):
        cases = {421: r"127\.0\.0\.1", 403: r"Origin", 405: r"POST", 503: r"(?i)start"}
        for status, fix in cases.items():
            with self.subTest(status=status), FakeEndpoint(status=status, body=b"refused") as endpoint:
                self.write_endpoint(endpoint.url, endpoint.port)
                code, out, _ = self.run_check()
                self.assertEqual(code, 1)
                self.assertIn(str(status), out.splitlines()[0])
                self.assertRegex("\n".join(line for line in out.splitlines() if line.startswith("fix: ")), fix)

    def test_an_answer_without_a_result_is_not_ok(self):
        body = {"jsonrpc": "2.0", "id": "check-compositor", "error": {"code": -32601, "message": "no"}}
        with FakeEndpoint(body=body) as endpoint:
            self.write_endpoint(endpoint.url, endpoint.port)
            code, out, _ = self.run_check()
        self.assertEqual(code, 1)
        self.assertTrue(out.startswith("compositor: UNEXPECTED"), out)

    def test_an_error_that_mentions_result_is_not_ok(self):
        # OK needs a top-level JSON-RPC `result`, as the bridge's own probe does; the word in a message isn't one.
        for body in ({"jsonrpc": "2.0", "id": "check-compositor", "error": {"code": -32603, "message": "no \"result\" yet"}},
                     {"jsonrpc": "2.0", "id": "check-compositor", "data": {"result": {}}}):
            with self.subTest(body=body), FakeEndpoint(body=body) as endpoint:
                self.write_endpoint(endpoint.url, endpoint.port)
                code, out, _ = self.run_check()
                self.assertEqual(code, 1, out)
                self.assertTrue(out.startswith("compositor: UNEXPECTED"), out)

    def test_ways_to_start_put_a_session_start_before_the_persistent_switch(self):
        # The Settings switch is the owner's standing decision; an agent asks for a session start.
        code, out, _ = self.run_check()
        fixes = [line for line in out.splitlines() if line.startswith("fix: ")]
        session = next(i for i, line in enumerate(fixes) if "compositor-mcp" in line or "--mcp" in line)
        switch = next(i for i, line in enumerate(fixes) if "Allow AI agents to control this document" in line)
        self.assertLess(session, switch)
        self.assertRegex(fixes[switch], r"(?i)owner")

    def test_the_settings_window_is_named_as_the_app_shows_it(self):
        # One Settings window (Compositor > Settings…), with no "AI Agents" tab to click.
        script = CHECK.read_text(encoding="utf-8")
        self.assertNotIn("AI Agents", script)
        self.assertIn("Settings…", script)

    def test_url_checks_one_endpoint_without_the_file(self):
        with FakeEndpoint() as endpoint:
            code, out, _ = self.run_check("--url", endpoint.url)
        self.assertEqual(code, 0, out)
        self.assertTrue(out.startswith("compositor: OK "), out)

    def test_endpoint_file_option_reads_that_file(self):
        with FakeEndpoint() as endpoint:
            self.write_endpoint(endpoint.url, endpoint.port)
            moved = self.home / "elsewhere.json"
            self.endpoint_file.rename(moved)
            code, out, _ = self.run_check("--endpoint-file", str(moved))
        self.assertEqual(code, 0, out)

    def test_bad_arguments_exit_2(self):
        code, _, err = self.run_check("--bogus")
        self.assertEqual(code, 2)
        self.assertIn("usage", err.lower())

    # The access token (on by default): read from the file endpoint.json names, sent as a Bearer header.

    TOKEN = "x" * 43  # 43 base64url characters, made up for these tests

    def write_token(self, name="token", mode=0o600, text=None):
        path = self.endpoint_file.parent / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.TOKEN if text is None else text)
        path.chmod(mode)
        return path

    def test_the_token_file_the_endpoint_file_names_is_sent(self):
        token_file = self.write_token()
        with FakeEndpoint(token=self.TOKEN) as endpoint:
            self.write_endpoint(endpoint.url, endpoint.port, auth="bearer", token_file=str(token_file))
            code, out, err = self.run_check()
        self.assertEqual(code, 0, out + err)
        self.assertTrue(out.startswith("compositor: OK "), out)
        self.assertEqual(endpoint.requests[0]["headers"].get("authorization"), f"Bearer {self.TOKEN}")
        self.assertNotIn(self.TOKEN, out + err, "the token must never be printed")

    def test_a_server_that_takes_no_token_gets_none(self):
        self.write_token()
        with FakeEndpoint() as endpoint:
            self.write_endpoint(endpoint.url, endpoint.port, auth="none")
            code, out, _ = self.run_check()
        self.assertEqual(code, 0, out)
        self.assertNotIn("authorization", endpoint.requests[0]["headers"])

    def test_a_refused_token_is_reported_as_401_with_fixes(self):
        token_file = self.write_token()
        with FakeEndpoint(token="another-token") as endpoint:
            self.write_endpoint(endpoint.url, endpoint.port, auth="bearer", token_file=str(token_file))
            code, out, _ = self.run_check()
        self.assertEqual(code, 1)
        first = out.splitlines()[0]
        self.assertTrue(first.startswith("compositor: REFUSED 401 "), first)
        self.assertIn("token", first)
        fixes = "\n".join(line for line in out.splitlines() if line.startswith("fix: "))
        self.assertIn("Settings", fixes)
        self.assertIn("compositor-mcp", fixes)
        self.assertNotIn(self.TOKEN, out)

    def test_a_401_without_a_token_says_none_was_sent(self):
        with FakeEndpoint(token=self.TOKEN) as endpoint:
            self.write_endpoint(endpoint.url, endpoint.port)
            code, out, _ = self.run_check()
        self.assertEqual(code, 1)
        self.assertTrue(out.startswith("compositor: REFUSED 401 "), out)
        self.assertIn("sent none", out.splitlines()[0])
        self.assertNotIn("authorization", endpoint.requests[0]["headers"])

    def test_a_token_file_the_bridge_would_refuse_is_never_sent(self):
        cases = {"open to other users": {"mode": 0o644}, "open to other users ": {"mode": 0o640},
                 "missing": {"missing": True}, "doesn't hold a token": {"text": "not a token"}}
        for reason, case in cases.items():
            with self.subTest(case=case), FakeEndpoint(token=self.TOKEN) as endpoint:
                token_file = self.endpoint_file.parent / "token"
                if case.get("missing"):
                    token_file.unlink(missing_ok=True)
                else:
                    self.write_token(mode=case.get("mode", 0o600), text=case.get("text"))
                self.write_endpoint(endpoint.url, endpoint.port, auth="bearer", token_file=str(token_file))
                code, out, _ = self.run_check()
                self.assertEqual(code, 1)
                self.assertTrue(out.startswith("compositor: TOKEN UNUSABLE "), out)
                self.assertIn(reason.strip(), out.splitlines()[0])
                self.assertRegex(out, r"(?m)^fix: ")
                self.assertEqual(endpoint.requests, [], "an unusable token must not be sent")

    def test_url_sends_the_token_file_given(self):
        token_file = self.write_token(name="elsewhere-token")
        with FakeEndpoint(token=self.TOKEN) as endpoint:
            code, out, _ = self.run_check("--url", endpoint.url, "--token-file", str(token_file))
        self.assertEqual(code, 0, out)
        self.assertEqual(endpoint.requests[0]["headers"].get("authorization"), f"Bearer {self.TOKEN}")

    def test_url_sends_the_token_to_the_url_the_running_compositor_published(self):
        token_file = self.write_token()
        with FakeEndpoint(token=self.TOKEN) as endpoint:
            self.write_endpoint(endpoint.url, endpoint.port, auth="bearer", token_file=str(token_file))
            code, out, err = self.run_check("--url", endpoint.url)
        self.assertEqual(code, 0, out + err)
        self.assertTrue(out.startswith(f"compositor: OK {endpoint.url} (Compositor 9.9, pid {self.app.pid})"), out)
        self.assertEqual(endpoint.requests[0]["headers"].get("authorization"), f"Bearer {self.TOKEN}")
        self.assertNotIn(self.TOKEN, out + err)

    def test_url_sends_no_token_to_a_port_compositor_did_not_publish(self):
        # Another account's program can listen on a client's port (2667 is free while Compositor's server is off, and
        # Compositor falls back to another port when it is taken) and collect whatever token arrives: the token goes
        # only to the URL a trusted endpoint file says the live Compositor serves.
        finished = subprocess.Popen(["/usr/bin/true"])
        finished.wait()
        cases = {
            "no endpoint file": None,
            "the endpoint file names another URL": {},
            "the endpoint file's pid is gone": {"pid": finished.pid},
            "the endpoint file's pid isn't Compositor": {"pid": os.getpid()},
            "others can change the endpoint file": {"mode": 0o666},
            "the group can change the endpoint file": {"mode": 0o620},
        }
        with FakeEndpoint(token=self.TOKEN) as listener, FakeEndpoint(token=self.TOKEN) as compositor:
            for label, case in cases.items():
                with self.subTest(label):
                    listener.requests.clear()
                    token_file = self.write_token()
                    self.endpoint_file.unlink(missing_ok=True)
                    if case is not None:
                        url = compositor.url if not case else listener.url
                        self.write_endpoint(url, compositor.port, pid=case.get("pid"),
                                            auth="bearer", token_file=str(token_file))
                        if "mode" in case:
                            self.endpoint_file.chmod(case["mode"])
                    code, out, err = self.run_check("--url", listener.url)
                    self.assertEqual(code, 1, out)
                    first = out.splitlines()[0]
                    self.assertTrue(first.startswith("compositor: REFUSED 401 "), first)
                    self.assertIn("sent none", first)
                    self.assertEqual(len(listener.requests), 1)
                    self.assertNotIn("authorization", listener.requests[0]["headers"], "the token went to an unpublished port")
                    self.assertNotIn(self.TOKEN, out + err)
                    fixes = "\n".join(line for line in out.splitlines() if line.startswith("fix: "))
                    self.assertNotIn("--token-file", fixes, "a fix must not send the token to an unknown port")
                    if case == {}:
                        self.assertIn(compositor.url, fixes, "the fix names the URL Compositor published")
        self.assertEqual(compositor.requests, [])

    def test_an_endpoint_file_others_can_change_is_not_trusted(self):
        # The bridge's rule: this user's file, which no one else can write. It could send the token anywhere.
        token_file = self.write_token()
        with FakeEndpoint(token=self.TOKEN) as endpoint:
            for mode in (0o666, 0o664, 0o646):
                with self.subTest(mode=oct(mode)):
                    self.write_endpoint(endpoint.url, endpoint.port, auth="bearer", token_file=str(token_file))
                    self.endpoint_file.chmod(mode)
                    code, out, _ = self.run_check()
                    self.assertEqual(code, 1)
                    first = out.splitlines()[0]
                    self.assertTrue(first.startswith("compositor: UNTRUSTED ENDPOINT FILE "), first)
                    self.assertIn(f"mode {mode:o}", first)
                    self.assertRegex(out, r"(?m)^fix: ")
        self.assertEqual(endpoint.requests, [], "nothing is sent to the URL of a file others can change")

    def test_a_token_file_named_by_a_relative_path_is_not_used(self):
        # The bridge takes only an absolute token_file; a relative one would be read from wherever the check runs.
        self.write_token()
        with FakeEndpoint(token=self.TOKEN) as endpoint:
            self.write_endpoint(endpoint.url, endpoint.port, auth="bearer", token_file="token")
            code, out, _ = self.run_check()
        self.assertEqual(code, 1)
        self.assertTrue(out.startswith("compositor: BROKEN ENDPOINT FILE "), out)
        self.assertEqual(endpoint.requests, [])

    def test_an_endpoint_file_naming_somewhere_off_this_mac_is_not_trusted(self):
        # Only plain HTTP to loopback, as the bridge requires; a user part can't hide another host.
        token_file = self.write_token()
        port = free_port()
        for url in (f"http://192.0.2.1:{port}/mcp", f"https://127.0.0.1:{port}/mcp",
                    f"http://127.0.0.1:{port}@192.0.2.1/mcp", f"http://127.0.0.1.example.com:{port}/mcp"):
            with self.subTest(url=url):
                self.write_endpoint(url, port, auth="bearer", token_file=str(token_file))
                code, out, _ = self.run_check()
                self.assertEqual(code, 1)
                first = out.splitlines()[0]
                self.assertTrue(first.startswith("compositor: UNTRUSTED ENDPOINT FILE "), first)
                self.assertIn("loopback", first)

    def test_the_token_never_reaches_a_command_line(self):
        # Other users can read any process's arguments with ps: curl gets the header on stdin.
        script = CHECK.read_text(encoding="utf-8")
        for line in script.splitlines():
            if "curl" in line and not line.lstrip().startswith("#"):
                self.assertNotIn("$token", line)
        self.assertIn("-H @-", script)


# MARK: - install-skills.sh (dry run only)

class InstallSkillsDryRunTests(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="install-skills-home-"))
        self.addCleanup(subprocess.run, ["rm", "-rf", str(self.home)], check=False)
        self.names = [path.name for path in skill_dirs()]
        self.agents = self.home / ".agents" / "skills"
        self.clients = [self.home / ".claude" / "skills", self.home / ".codex" / "skills"]

    def run_install(self, *args):
        env = {**os.environ, "HOME": str(self.home)}
        result = subprocess.run(["/bin/bash", str(INSTALL), *args], capture_output=True, text=True, env=env, timeout=30)
        return result.returncode, result.stdout, result.stderr

    def snapshot(self):
        return sorted((str(path.relative_to(self.home)), os.readlink(path) if path.is_symlink() else None)
                      for path in self.home.rglob("*"))

    def test_a_dry_run_plans_every_link_and_changes_nothing(self):
        code, out, err = self.run_install("--dry-run")
        self.assertEqual(code, 0, out + err)
        self.assertEqual(self.snapshot(), [], "a dry run must not create anything")
        for name in self.names:
            self.assertIn(f"would link {self.agents / name} -> {SKILLS / name}", out)
            for client in self.clients:
                self.assertIn(f"would link {client / name} -> {self.agents / name}", out)

    def test_links_already_in_place_are_left_alone(self):
        name = self.names[0]
        self.agents.mkdir(parents=True)
        (self.agents / name).symlink_to(SKILLS / name)
        self.clients[0].mkdir(parents=True)
        (self.clients[0] / name).symlink_to(self.agents / name)
        self.clients[1].mkdir(parents=True)
        (self.clients[1] / name).symlink_to(Path("../../.agents/skills") / name)
        before = self.snapshot()
        code, out, err = self.run_install("--dry-run")
        self.assertEqual(code, 0, out + err)
        self.assertEqual(self.snapshot(), before)
        for path in [self.agents / name, *(client / name for client in self.clients)]:
            self.assertIn(f"ok {path}", out)
            self.assertNotIn(f"would link {path} ", out)

    def test_a_real_folder_in_the_way_is_refused(self):
        name = self.names[0]
        occupied = self.clients[1] / name
        occupied.mkdir(parents=True)
        (occupied / "SKILL.md").write_text("someone else's skill\n")
        before = self.snapshot()
        code, out, _ = self.run_install("--dry-run")
        self.assertEqual(code, 1)
        self.assertEqual(self.snapshot(), before)
        self.assertIn(f"refuse {occupied}", out)
        self.assertIn(f"would link {self.clients[0] / name} -> {self.agents / name}", out)

    def test_a_link_to_something_else_is_refused_and_its_clients_skipped(self):
        name = self.names[0]
        other = self.home / "other-skill"
        other.mkdir()
        self.agents.mkdir(parents=True)
        (self.agents / name).symlink_to(other)
        code, out, _ = self.run_install("--dry-run")
        self.assertEqual(code, 1)
        self.assertIn(f"refuse {self.agents / name}", out)
        for client in self.clients:
            self.assertNotIn(f"would link {client / name} ", out)

    def test_uninstall_removes_only_its_own_links(self):
        ours, theirs = self.names[0], self.names[-1]
        self.agents.mkdir(parents=True)
        (self.agents / ours).symlink_to(SKILLS / ours)
        for client in self.clients:
            client.mkdir(parents=True)
            (client / ours).symlink_to(self.agents / ours)
        (self.clients[0] / theirs).mkdir()
        before = self.snapshot()
        code, out, err = self.run_install("--uninstall", "--dry-run")
        self.assertEqual(code, 0, out + err)
        self.assertEqual(self.snapshot(), before)
        self.assertIn(f"would remove {self.agents / ours}", out)
        for client in self.clients:
            self.assertIn(f"would remove {client / ours}", out)
        self.assertNotIn(f"would remove {self.clients[0] / theirs}", out)
        self.assertIn(f"leave {self.clients[0] / theirs}", out)

    def test_uninstall_leaves_the_clients_of_another_checkouts_install(self):
        # Parallel worktrees each carry this script; uninstalling from one must not disconnect
        # Claude Code and Codex from the skills another checkout installed.
        name = self.names[0]
        other_checkout = self.home / "other-checkout" / "skills" / name
        other_checkout.mkdir(parents=True)
        dangling = self.home / "deleted-checkout" / "skills" / name
        occupants = {
            "another checkout's link": lambda path: path.symlink_to(other_checkout),
            "a link to a deleted checkout": lambda path: path.symlink_to(dangling),
            "a real folder": lambda path: path.mkdir(),
        }
        for kind, make in occupants.items():
            with self.subTest(agents_entry=kind):
                subprocess.run(["rm", "-rf", str(self.home / ".agents"), str(self.home / ".claude"),
                                str(self.home / ".codex")], check=True)
                self.agents.mkdir(parents=True)
                make(self.agents / name)
                for client in self.clients:
                    client.mkdir(parents=True)
                    (client / name).symlink_to(self.agents / name)
                before = self.snapshot()
                code, out, err = self.run_install("--uninstall", "--dry-run")
                self.assertEqual(code, 0, out + err)
                self.assertEqual(self.snapshot(), before)
                for path in [self.agents / name, *(client / name for client in self.clients)]:
                    self.assertNotIn(f"would remove {path}\n", out)
                    self.assertIn(f"leave {path}", out)

    def test_uninstall_removes_client_links_whose_agents_link_is_gone(self):
        name = self.names[0]
        for client in self.clients:
            client.mkdir(parents=True)
            (client / name).symlink_to(self.agents / name)
        before = self.snapshot()
        code, out, err = self.run_install("--uninstall", "--dry-run")
        self.assertEqual(code, 0, out + err)
        self.assertEqual(self.snapshot(), before)
        for client in self.clients:
            self.assertIn(f"would remove {client / name}\n", out)

    def test_bad_arguments_exit_2(self):
        code, _, err = self.run_install("--bogus")
        self.assertEqual(code, 2)
        self.assertIn("usage", err.lower())

    def test_usage_says_to_install_from_the_main_checkout(self):
        # Links point into whichever checkout runs the script; a worktree's dangle once it is removed.
        code, _, err = self.run_install("--help")
        self.assertEqual(code, 0)
        self.assertIn("main checkout", err)
        self.assertIn("main checkout", INSTALL.read_text(encoding="utf-8"))


class InstallSkillsTests(unittest.TestCase):
    """The real install and uninstall, under a temporary HOME: links made, found in place, and removed."""

    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="install-skills-real-"))
        self.addCleanup(subprocess.run, ["rm", "-rf", str(self.home)], check=False)
        self.names = [path.name for path in skill_dirs()]
        self.agents = self.home / ".agents" / "skills"
        self.clients = [self.home / ".claude" / "skills", self.home / ".codex" / "skills"]

    def run_install(self, *args):
        env = {**os.environ, "HOME": str(self.home)}
        result = subprocess.run(["/bin/bash", str(INSTALL), *args], capture_output=True, text=True, env=env, timeout=30)
        return result.returncode, result.stdout, result.stderr

    def test_install_twice_then_uninstall_twice(self):
        code, out, err = self.run_install()
        self.assertEqual(code, 0, out + err)
        for name in self.names:
            entry = self.agents / name
            self.assertTrue(entry.is_symlink())
            self.assertEqual(os.readlink(entry), str(SKILLS / name))
            self.assertTrue((entry / "SKILL.md").is_file())
            for client in self.clients:
                self.assertEqual(os.readlink(client / name), str(entry))
                self.assertTrue((client / name / "SKILL.md").is_file())

        code, out, err = self.run_install()
        self.assertEqual(code, 0, out + err)
        self.assertNotIn("linked ", out)
        self.assertEqual(out.count("(already linked)"), 3 * len(self.names))

        code, out, err = self.run_install("--uninstall")
        self.assertEqual(code, 0, out + err)
        leftovers = sorted(str(path.relative_to(self.home)) for path in self.home.rglob("*"))
        self.assertEqual(leftovers, sorted([".agents", ".agents/skills", ".claude", ".claude/skills", ".codex",
                                            ".codex/skills"]))
        code, out, err = self.run_install("--uninstall")
        self.assertEqual((code, out.strip()), (0, ""), err)


if __name__ == "__main__":
    unittest.main()
