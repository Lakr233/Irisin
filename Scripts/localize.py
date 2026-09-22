#!/usr/bin/env python3
"""Hand the app's strings to translators, one file per locale, and merge back.

    Scripts/localize.py extract <dir> [locale ...]
    Scripts/localize.py merge <dir>

`extract` writes `<dir>/<locale>.json` with every string that locale is
missing, from the two string catalogs and the Settings.bundle page:
`{"locale": ..., "strings": {"<table>|<key>": {"source", "zh-Hans",
"comment"}}}`. A translator answers with `<dir>/<locale>.out.json`, a flat
`{"<table>|<key>": "<translation>"}`.

`merge` writes every answer into its catalog (the locale sorted in with the
others, as Xcode writes it) or into `Settings.bundle/<locale>.lproj`. An
answer whose format specifiers differ from the source is refused and named;
running `extract` again shows what is still missing.

The locales are the ones Fila, iGhostVT and CocoaInspector ship, and the six
Irisin was asked for on its own: Bengali, Hindi, Indonesian, Swahili, Turkish
and Yoruba.
"""

import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOURCES = os.path.join(ROOT, "Irisin", "Resources")
CATALOGS = {
    "Localizable": os.path.join(RESOURCES, "Localizable.xcstrings"),
    "InfoPlist": os.path.join(RESOURCES, "InfoPlist.xcstrings"),
}
SETTINGS = os.path.join(RESOURCES, "Settings.bundle")
SETTINGS_TABLE = "Root"
REFERENCE = "zh-Hans"
LOCALES = [
    "ar",
    "bn",
    "de",
    "es",
    "fr",
    "hi",
    "id",
    "it",
    "ja",
    "ko",
    "pt-BR",
    "ru",
    "sw",
    "tr",
    "vi",
    "yo",
    "zh-Hans",
    "zh-Hant",
]

STRINGS_LINE = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$')
SPECIFIER = re.compile(r"%(?:(\d+)\$)?(lld|ld|d|@|%)")


def read_catalog(path):
    with open(path, encoding="utf-8") as handle:
        raw = handle.read()
    return raw, json.loads(raw)


def write_catalog(path, raw, catalog):
    out = json.dumps(catalog, indent=2, separators=(",", " : "), ensure_ascii=False)
    if raw.endswith("\n"):
        out += "\n"
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(out)


def unit_value(entry, locale):
    unit = entry.get("localizations", {}).get(locale, {}).get("stringUnit")
    return unit["value"] if unit and unit.get("value") else None


def unescape(text):
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), text)


def escape(text):
    return text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def read_strings(path):
    if not os.path.exists(path):
        return {}
    pairs = {}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            match = STRINGS_LINE.match(line)
            if match:
                pairs[unescape(match.group(1))] = unescape(match.group(2))
    return pairs


def settings_path(locale):
    return os.path.join(SETTINGS, f"{locale}.lproj", f"{SETTINGS_TABLE}.strings")


def sources():
    """Every translatable string: (id, source, reference, comment, {locale: value})."""
    for table, path in CATALOGS.items():
        _, catalog = read_catalog(path)
        for key, entry in catalog["strings"].items():
            if not key or entry.get("shouldTranslate") is False:
                continue
            present = {
                locale: unit_value(entry, locale) for locale in entry.get("localizations", {})
            }
            yield (
                f"{table}|{key}",
                unit_value(entry, "en") or key,
                present.get(REFERENCE),
                entry.get("comment"),
                present,
            )
    english = read_strings(settings_path("en"))
    translated = {locale: read_strings(settings_path(locale)) for locale in LOCALES}
    for key, value in english.items():
        present = {locale: translated[locale].get(key) for locale in LOCALES}
        yield (f"{SETTINGS_TABLE}|{key}", value, present[REFERENCE], None, present)


def extract(directory, locales):
    os.makedirs(directory, exist_ok=True)
    rows = list(sources())
    for locale in locales:
        strings = {}
        for identifier, source, reference, comment, present in rows:
            if present.get(locale):
                continue
            item = {"source": source}
            if reference and locale != REFERENCE:
                item[REFERENCE] = reference
            if comment:
                item["comment"] = comment
            strings[identifier] = item
        with open(os.path.join(directory, f"{locale}.json"), "w", encoding="utf-8") as handle:
            json.dump({"locale": locale, "strings": strings}, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
        print(f"{locale:8} {len(strings)} missing")


def specifiers(text):
    """The argument types in the order they are consumed; None if positions are malformed."""
    found = [(m.group(1), m.group(2)) for m in SPECIFIER.finditer(text) if m.group(2) != "%"]
    if not any(position for position, _ in found):
        return [kind for _, kind in found]
    if not all(position for position, _ in found):
        return None
    ordered = sorted(found, key=lambda pair: int(pair[0]))
    if [int(position) for position, _ in ordered] != list(range(1, len(ordered) + 1)):
        return None
    return [kind for _, kind in ordered]


def merge(directory):
    rows = {identifier: source for identifier, source, *_ in sources()}
    answers = {}
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".out.json"):
            continue
        locale = name[: -len(".out.json")]
        if locale not in LOCALES:
            print(f"skip {name}: {locale} is not a shipped locale", file=sys.stderr)
            continue
        with open(os.path.join(directory, name), encoding="utf-8") as handle:
            answers[locale] = json.load(handle)

    accepted = {}
    refused = 0
    for locale, items in answers.items():
        for identifier, text in items.items():
            source = rows.get(identifier)
            if source is None:
                problem = "unknown key"
            elif not isinstance(text, str) or not text.strip():
                problem = "empty"
            elif specifiers(text) != specifiers(source):
                problem = f"specifiers {specifiers(text)} != {specifiers(source)}"
            else:
                accepted.setdefault(identifier.split("|", 1)[0], []).append(
                    (locale, identifier.split("|", 1)[1], text)
                )
                continue
            refused += 1
            print(f"refused {locale} {identifier!r}: {problem}", file=sys.stderr)

    for table, path in CATALOGS.items():
        items = accepted.get(table, [])
        if not items:
            continue
        raw, catalog = read_catalog(path)
        for locale, key, text in items:
            entry = catalog["strings"][key]
            localizations = entry.setdefault("localizations", {})
            localizations[locale] = {"stringUnit": {"state": "translated", "value": text}}
            entry["localizations"] = dict(sorted(localizations.items()))
        write_catalog(path, raw, catalog)
        print(f"{table:12} {len(items)} written")

    english = read_strings(settings_path("en"))
    updates = {}
    for locale, key, text in accepted.get(SETTINGS_TABLE, []):
        updates.setdefault(locale, {})[key] = text
    for locale, values in sorted(updates.items()):
        pairs = {**read_strings(settings_path(locale)), **values}
        os.makedirs(os.path.dirname(settings_path(locale)), exist_ok=True)
        with open(settings_path(locale), "w", encoding="utf-8") as handle:
            for key in english:
                if key in pairs:
                    handle.write(f'"{escape(key)}" = "{escape(pairs[key])}";\n')
    if updates:
        print(f"{SETTINGS_TABLE:12} {sum(map(len, updates.values()))} written")
    print(f"{refused} refused")
    return 1 if refused else 0


def main(argv):
    if len(argv) >= 3 and argv[1] == "extract":
        extract(argv[2], argv[3:] or LOCALES)
        return 0
    if len(argv) == 3 and argv[1] == "merge":
        return merge(argv[2])
    print(__doc__, file=sys.stderr)
    return 64


if __name__ == "__main__":
    assert specifiers("%@ of %@") == ["@", "@"]
    assert specifiers("%2$@ ／ %1$lld") == ["lld", "@"]
    assert specifiers("%1$@ %1$@") is None
    assert specifiers("100%% %d") == ["d"]
    sys.exit(main(sys.argv))
