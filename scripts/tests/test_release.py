"""Release checks: one version across every target, a version the update feed can offer,
links in README.md and docs/ that resolve, and git ignoring the Python test caches.

Run from the repository root with the system python3 (no packages needed):
    python3 -m unittest discover -s scripts/tests -p test_release.py
"""

import plistlib
import re
import subprocess
import unittest
import xml.etree.ElementTree as ElementTree
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PROJECT = REPO / "Compositor.xcodeproj" / "project.pbxproj"
APPCAST = REPO / "appcast.xml"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def build_setting(name):
    """Every value `name` has across the project's build configurations."""
    return re.findall(rf"^\s*{name} = ([^;]+);$", PROJECT.read_text(), re.MULTILINE)


def version_tuple(text):
    return tuple(int(part) for part in text.split("."))


def feed_problems(marketing, build, published_version, published_build):
    """Why Sparkle wouldn't offer version `marketing` (build `build`) over the feed's newest item, if it wouldn't."""
    problems = []
    if version_tuple(marketing) < published_version:
        problems.append(f"MARKETING_VERSION {marketing} is older than the published {published_version}")
    if build < published_build:
        problems.append(f"CURRENT_PROJECT_VERSION {build} is older than the published {published_build}")
    elif build == published_build and version_tuple(marketing) > published_version:
        # The version just published keeps its build (publish.sh commits the appcast with it); a new one needs more.
        problems.append(f"MARKETING_VERSION {marketing} is new but CURRENT_PROJECT_VERSION is still the published {build}")
    return problems


class VersionTests(unittest.TestCase):
    def test_every_target_builds_one_version(self):
        # The compositor-mcp bridge reports its own embedded version to clients, so a bump
        # that misses a target leaves the app and its bridge disagreeing.
        marketing = build_setting("MARKETING_VERSION")
        build = build_setting("CURRENT_PROJECT_VERSION")
        self.assertTrue(marketing, "no MARKETING_VERSION in project.pbxproj")
        self.assertEqual(len(build), len(marketing), "a configuration sets one version but not the other")
        self.assertEqual(len(set(marketing)), 1, f"MARKETING_VERSION differs between targets: {marketing}")
        self.assertEqual(len(set(build)), 1, f"CURRENT_PROJECT_VERSION differs between targets: {build}")

    def test_version_is_one_the_published_feed_can_offer(self):
        # Sparkle offers an update only when its build number is higher than the one installed.
        items = ElementTree.parse(APPCAST).getroot().findall("channel/item")
        self.assertTrue(items, "appcast.xml has no items")
        published_build = max(int(item.findtext(f"{SPARKLE}version")) for item in items)
        published_version = max(version_tuple(item.findtext(f"{SPARKLE}shortVersionString")) for item in items)
        self.assertEqual(feed_problems(build_setting("MARKETING_VERSION")[0], int(build_setting("CURRENT_PROJECT_VERSION")[0]),
                                       published_version, published_build), [])

    def test_a_new_version_needs_a_higher_build_number(self):
        # A marketing bump that leaves the build at the published one would never be offered. The version
        # just published (publish.sh commits the appcast with the project's own build) is fine as it stands.
        self.assertTrue(feed_problems("1.4.0", 17, (1, 3, 0), 17))
        self.assertEqual(feed_problems("1.3.0", 17, (1, 3, 0), 17), [])
        self.assertEqual(feed_problems("1.4.0", 18, (1, 3, 0), 17), [])
        self.assertTrue(feed_problems("1.3.0", 16, (1, 3, 0), 17))
        self.assertTrue(feed_problems("1.2.9", 18, (1, 3, 0), 17))


class SigningTests(unittest.TestCase):
    def test_the_bridge_is_signed_with_its_own_empty_entitlements(self):
        # Without an entitlements file, Xcode signs the compositor-mcp tool with an injected
        # com.apple.application-identifier, which a command-line tool has no provisioning profile for, so
        # macOS would refuse to run a Developer ID-signed bridge. Release also leaves out Xcode's base
        # entitlements (get-task-allow), which notarization refuses.
        blocks = re.findall(r"isa = XCBuildConfiguration;\s*buildSettings = \{(.*?)\n\t\t\t\};\s*name = (\w+);",
                            PROJECT.read_text(), re.DOTALL)
        bridge = {name: settings for settings, name in blocks if "compositor.mcp-bridge" in settings}
        self.assertEqual(set(bridge), {"Debug", "Release"})
        for name, settings in bridge.items():
            with self.subTest(configuration=name):
                self.assertIn('CODE_SIGN_ENTITLEMENTS = "Config/compositor-mcp.entitlements";', settings)
        self.assertIn("CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO;", bridge["Release"])
        entitlements = REPO / "Config" / "compositor-mcp.entitlements"
        with entitlements.open("rb") as file:
            self.assertEqual(plistlib.load(file), {})


class DocumentationTests(unittest.TestCase):
    def test_relative_links_resolve(self):
        pages = [REPO / "README.md", *sorted((REPO / "docs").glob("*.md"))]
        broken = []
        for page in pages:
            for target in re.findall(r"\]\(([^)\s]+)\)", page.read_text()):
                if re.match(r"[a-z][a-z0-9+.-]*:", target) or target.startswith("#"):
                    continue
                path = target.split("#", 1)[0]
                if not (page.parent / path).exists():
                    broken.append(f"{page.relative_to(REPO)} -> {target}")
        self.assertEqual(broken, [])


class GitIgnoreTests(unittest.TestCase):
    def test_python_test_caches_are_ignored(self):
        # Running the script tests with unittest or pytest must leave the worktree clean.
        for path in ("scripts/tests/__pycache__/test_release.cpython-313.pyc",
                     "skills/compositor/scripts/__pycache__/tool_atlas.cpython-313.pyc",
                     ".pytest_cache/v/cache/nodeids",
                     "scripts/.pytest_cache/README.md"):
            with self.subTest(path=path):
                result = subprocess.run(["git", "-C", str(REPO), "check-ignore", "--quiet", "--no-index", path])
                self.assertEqual(result.returncode, 0, f"{path} is not ignored")


if __name__ == "__main__":
    unittest.main()
