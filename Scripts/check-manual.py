#!/usr/bin/env python3
"""Fails when the user manual names a control the app does not have.

The manual is written by hand, in Documentation/Manual (English) and
Documentation/Manual/zh-Hans, with the site's root page beside it in
Documentation/Site. It quotes the app's controls, and a control renamed in the
string catalog is renamed nowhere else on its own. So every name the manual
quotes is marked `<span class="ui">` and read against the catalogs and
Irisin's page in the Settings app: an English page quotes the English key, a
zh-Hans page the zh-Hans value, and a translator who wrote their own Chinese
for a control is told which value the app shows. A path through the app
(`Settings → Packages → Auto Translate`) is one span, checked part by part. A
key with a format specifier cannot be quoted as it is stored, so its span
names it (`data-key="%lld completed"`) and the text is matched with each
specifier standing for anything.

The two languages are one manual: the same pages, and on each page the same
number of controls, figures, images, headings and chapters, the controls in
the same order. Every relative `src`, `srcset` and `href` leads to a file, and
a fragment to an `id`. The site's page reaches the manual as `manual/...`,
where the Pages workflow copies it. Each page says its language in `lang`, and
it is the language of its directory.

A chapter is a directory of its own with an index.html in it, served as
`<slug>/`, and the contents page is the index.html beside them. A file whose
name starts with `_` and anything under `assets/` is not a page. Until
Documentation/Manual has its first page there is nothing to check, the site's
page included: what stands there before the manual is a redirect.

usage: check-manual.py <repository root>
"""

import difflib
import json
import os
import plistlib
import re
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit

ENGLISH = "en-US"
CHINESE = "zh-Hans"
ARROW = "→"
SPECIFIER = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|%)")
STRINGS_LINE = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$')
COUNTED = ("controls", "<figure>", "<img>", "<h2>", "<h3>", "chapters")


def read_text(path: Path) -> str:
    data = path.read_bytes()
    return data.decode("utf-16" if data[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-8", "replace")


def normalise(text: str) -> str:
    return " ".join(text.replace(" ", " ").split())


def unescape(text: str) -> str:
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), text)


def plist_texts(node):
    """Every Title and FooterText in a Settings.bundle page."""
    if isinstance(node, dict):
        for name, child in node.items():
            if name in ("Title", "FooterText") and isinstance(child, str):
                yield child
            else:
                yield from plist_texts(child)
    elif isinstance(node, list):
        for child in node:
            yield from plist_texts(child)


class Strings:
    """What the app says: English keys, and the zh-Hans value of each."""

    def __init__(self, resources: Path):
        self.english = {}
        self.translated = {}
        for catalog in sorted(resources.glob("*.xcstrings")):
            for key, entry in json.loads(catalog.read_text())["strings"].items():
                localizations = entry.get("localizations", {})
                self.english[key] = self.unit(localizations, "en") or key
                value = self.unit(localizations, CHINESE)
                if value:
                    self.translated[key] = value
        settings = resources / "Settings.bundle"
        if (settings / "Root.plist").exists():
            for text in plist_texts(plistlib.loads((settings / "Root.plist").read_bytes())):
                self.english.setdefault(text, text)
        table = settings / f"{CHINESE}.lproj" / "Root.strings"
        if table.exists():
            for line in read_text(table).splitlines():
                match = STRINGS_LINE.match(line.strip())
                if match:
                    self.english.setdefault(unescape(match.group(1)), unescape(match.group(1)))
                    self.translated[unescape(match.group(1))] = unescape(match.group(2))
        self.by_name = {ENGLISH: {}, CHINESE: {}}
        for key in self.english:
            self.by_name[ENGLISH].setdefault(normalise(key), set()).add(key)
        for key, value in self.translated.items():
            self.by_name[CHINESE].setdefault(normalise(value), set()).add(key)

    @staticmethod
    def unit(localizations, locale):
        unit = localizations.get(locale, {}).get("stringUnit")
        return unit["value"] if unit and unit.get("value") else None

    def value(self, key, language):
        return self.english.get(key) if language == ENGLISH else self.translated.get(key)

    def keys(self, name, language):
        return self.by_name[language].get(name, set())

    def suggestion(self, name, language):
        """The closest name: one that shares a word and has as many comes first."""
        words = name.lower().split()
        close = difflib.get_close_matches(name, list(self.by_name[language]), 8, 0.6)

        def likeness(candidate):
            theirs = candidate.lower().split()
            return (
                len(set(words) & set(theirs)),
                len(words) == len(theirs),
                difflib.SequenceMatcher(None, name, candidate).ratio(),
            )

        return f'; did you mean "{max(close, key=likeness)}"?' if close else ""


def matches(text: str, value: str) -> bool:
    """`text` is `value` with something in place of each format specifier."""
    pattern, end = "", 0
    for specifier in SPECIFIER.finditer(normalise(value)):
        pattern += re.escape(normalise(value)[end:specifier.start()])
        pattern += "%" if specifier.group() == "%%" else ".+?"
        end = specifier.end()
    pattern += re.escape(normalise(value)[end:])
    return re.fullmatch(pattern, text, re.DOTALL) is not None


class Control:
    def __init__(self, line, key):
        self.line = line
        self.key = key
        self.text = ""
        self.parts = []  # (name, the English keys it is, or None when it is none)


class Page(HTMLParser):
    def __init__(self, path: Path):
        super().__init__(convert_charrefs=True)
        self.path = path
        self.lang = None
        self.lang_line = 1
        self.controls = []
        self.counts = dict.fromkeys(COUNTED, 0)
        self.ids = set()
        self.references = []
        self.open = None
        self.depth = 0
        self.feed(read_text(path))
        self.close()
        self.counts["controls"] = len(self.controls)
        for control in self.controls:
            control.text = normalise(control.text)

    def handle_starttag(self, tag, attrs):
        line = self.getpos()[0]
        attributes = {name: value or "" for name, value in attrs}
        classes = attributes.get("class", "").split()
        if tag == "html":
            self.lang, self.lang_line = attributes.get("lang"), line
        if "id" in attributes:
            self.ids.add(attributes["id"])
        if tag == "a" and "name" in attributes:
            self.ids.add(attributes["name"])
        for name in ("src", "href"):
            if name in attributes:
                self.references.append((line, attributes[name].strip()))
        for candidate in attributes.get("srcset", "").split(","):
            if candidate.split():
                self.references.append((line, candidate.split()[0]))
        if tag in ("figure", "img", "h2", "h3"):
            self.counts[f"<{tag}>"] += 1
        if tag == "section" and "chapter" in classes:
            self.counts["chapters"] += 1
        if tag == "span":
            if self.open is not None:
                self.depth += 1
            elif "ui" in classes:
                self.open, self.depth = Control(line, attributes.get("data-key")), 0
                self.controls.append(self.open)

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag == "span":
            self.handle_endtag(tag)

    def handle_endtag(self, tag):
        if tag == "span" and self.open is not None:
            if self.depth == 0:
                self.open = None
            else:
                self.depth -= 1

    def handle_data(self, data):
        if self.open is not None:
            self.open.text += data


class Manual:
    def __init__(self, root: Path):
        self.root = root
        self.manual = root / "Documentation" / "Manual"
        self.site = root / "Documentation" / "Site"
        self.strings = Strings(root / "Irisin" / "Resources")
        self.pages = {}
        self.problems = []

    def report(self, path: Path, line, message):
        where = f"{path.relative_to(self.root)}:{line}" if line else f"{path.relative_to(self.root)}"
        self.problems.append((str(path), line or 0, f"{where}: {message}"))

    def page(self, path: Path) -> Page:
        if path not in self.pages:
            self.pages[path] = Page(path)
        return self.pages[path]

    @staticmethod
    def listed(directory: Path):
        """The pages of one language, by the address each is served at.

        The contents page is `index.html` and answers for the directory
        itself, so its address is ""; a chapter is a directory beside it with
        its own `index.html`, so its address is `<slug>/`. The two languages
        are paired by that address, which is what both trees share. `assets`
        holds no page, nor does a name that starts with `_`, nor the other
        language's directory.
        """
        pages = {}
        for path in sorted(directory.glob("*.html")):
            if not path.name.startswith("_"):
                pages["" if path.name == "index.html" else path.name] = path
        for path in sorted(directory.glob("*/index.html")):
            slug = path.parent.name
            if not slug.startswith("_") and slug not in ("assets", ENGLISH, CHINESE):
                pages[f"{slug}/"] = path
        return pages

    def check_controls(self, page: Page, language):
        for control in page.controls:
            if control.key is not None:
                value = self.strings.value(control.key, language)
                if control.key not in self.strings.english:
                    hint = self.strings.suggestion(control.key, ENGLISH)
                    self.report(page.path, control.line, f'"{control.key}" is not in the string catalog{hint}')
                elif value is None:
                    self.report(page.path, control.line, f'"{control.key}" has no {language} value in the string catalog')
                elif not matches(control.text, value):
                    self.report(page.path, control.line, f'"{control.text}" does not match "{value}"')
                else:
                    control.parts = [(control.text, {control.key})]
                    continue
                control.parts = [(control.text, None)]
                continue
            for name in (normalise(part) for part in control.text.split(ARROW)):
                keys = self.strings.keys(name, language)
                control.parts.append((name, keys or None))
                if not keys:
                    hint = self.strings.suggestion(name, language) if name else ""
                    self.report(page.path, control.line, f'"{name}" is not in the string catalog{hint}')

    def check_pair(self, english: Page, chinese: Page):
        for name in COUNTED:
            if english.counts[name] != chinese.counts[name]:
                self.report(
                    chinese.path,
                    None,
                    f"{name}: {english.counts[name]} in English, {chinese.counts[name]} in {CHINESE}",
                )
        if english.counts["controls"] != chinese.counts["controls"]:
            return
        for ours, theirs in zip(english.controls, chinese.controls):
            if len(ours.parts) != len(theirs.parts):
                self.report(chinese.path, theirs.line, f'"{theirs.text}" is not "{ours.text}" part for part')
                continue
            for (name, keys), (translated, translated_keys) in zip(ours.parts, theirs.parts):
                if keys is None or translated_keys is None or keys & translated_keys:
                    continue
                key = sorted(keys)[0]
                expected = self.strings.value(key, CHINESE)
                shown = f' ("{expected}")' if expected else ""
                self.report(
                    chinese.path,
                    theirs.line,
                    f'"{translated}" is not the {CHINESE} value of "{key}"{shown}',
                )

    def published(self, page: Path, path, is_site):
        """The file a reference reaches on the site, or None above its root.

        Documentation/Site is the root and the Pages workflow copies
        Documentation/Manual to `manual/` in it, so the page's address there is
        what the reference is resolved against: `manual/` from the site's page
        is the manual, and `../` from a manual page is the site.
        """
        base = self.site if is_site else self.manual
        address = ("" if is_site else "manual/") + page.parent.relative_to(base).as_posix()
        reached = os.path.normpath(os.path.join("/", address, path.replace("/", os.sep)))
        steps = os.path.normpath(os.path.join(address, path.replace("/", os.sep)))
        if steps == os.pardir or steps.startswith(os.pardir + os.sep):
            return None
        inside = Path(reached).relative_to("/")
        if inside.parts[:1] == ("manual",):
            return self.manual.joinpath(*inside.parts[1:])
        return self.site / inside

    def check_references(self, page: Page, is_site):
        for line, reference in page.references:
            parts = urlsplit(reference)
            if parts.scheme or parts.netloc or reference.startswith("//") or not reference:
                continue
            fragment = unquote(parts.fragment)
            if not parts.path:
                if fragment and fragment != "top" and fragment not in page.ids:
                    self.report(page.path, line, f'{reference}: no id "{fragment}" on this page')
                continue
            target = self.published(page.path, unquote(parts.path), is_site)
            if target is None:
                self.report(page.path, line, f"{reference} leaves the site")
                continue
            if target.is_dir():
                target = target / "index.html"
            if not target.is_file():
                self.report(page.path, line, f"{reference} does not exist")
            elif fragment and target.suffix == ".html" and fragment not in self.page(target).ids:
                where = target.relative_to(self.root)
                self.report(page.path, line, f'{reference}: no id "{fragment}" in {where}')

    def check_page(self, path: Path, language, is_site=False) -> Page:
        page = self.page(path)
        if page.lang != language:
            self.report(path, page.lang_line, f'lang is "{page.lang or ""}", expected "{language}"')
        self.check_controls(page, language)
        self.check_references(page, is_site)
        return page

    def check(self):
        english = {name: self.check_page(path, ENGLISH) for name, path in self.listed(self.manual).items()}
        translations = self.manual / CHINESE
        if translations.is_dir():
            chinese = {name: self.check_page(path, CHINESE) for name, path in self.listed(translations).items()}
            for name in sorted(english.keys() - chinese.keys()):
                self.report(english[name].path, None, f"has no {CHINESE} page")
            for name in sorted(chinese.keys() - english.keys()):
                self.report(chinese[name].path, None, "has no English page")
            for name in sorted(english.keys() & chinese.keys()):
                self.check_pair(english[name], chinese[name])
        front = self.site / "index.html"
        translated_front = self.site / CHINESE / "index.html"
        if front.is_file():
            self.check_page(front, ENGLISH, is_site=True)
        if translated_front.is_file():
            self.check_page(translated_front, CHINESE, is_site=True)
            if front.is_file():
                self.check_pair(self.page(front), self.page(translated_front))


def main() -> int:
    root = Path(sys.argv[1])
    pages = root / "Documentation" / "Manual"
    if not Manual.listed(pages) and not Manual.listed(pages / CHINESE):
        return 0
    manual = Manual(root)
    manual.check()
    if manual.problems:
        print("error: the manual names the app's controls as the string catalog does, in both languages", file=sys.stderr)
        print("\n".join(message for _, _, message in sorted(manual.problems)), file=sys.stderr)
        return 65
    return 0


if __name__ == "__main__":
    sys.exit(main())
