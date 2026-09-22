#!/usr/bin/env python3
"""Refuse a UIKit container that writes an accessibilityLabel nobody reads.

UIKit reads `accessibilityLabel` off a view only when that view is itself an
accessibility element. A `UIView`, a `UITableViewCell` or a
`UICollectionViewCell` with subviews is not one by default: VoiceOver walks
past the label the type assembled and reads the subviews instead, one stop
each, with the drawn separators spoken. The label is not wrong, it is
unreachable, and nothing warns — not the compiler, not the Accessibility
Inspector's default pass, not a sighted read of the screen.

Observed in Fila 0.5.12: `BrowserGridCell` and `BackendRowCell` each built a
sentence in `configure(_:)` and neither set `isAccessibilityElement`, so every
row in the browser arrived as two separate stops with the assembled sentence
never spoken. Both had been that way since the cells were written.

This is the one accessibility defect mechanical enough to gate. Everything
else about labelling a screen is a reading job and lives in `CHECKLIST.md`.

Usage: check-accessibility.py <source root> [<source root> ...]

Exit 0 when clean, 65 on a finding, 66 on bad usage.
"""
import re
import sys
from pathlib import Path

# Types that are NOT accessibility elements by default, so a label written on
# one is invisible until `isAccessibilityElement` is set. UILabel, UIButton,
# UIImageView, UISwitch and the rest of UIControl are elements already and are
# deliberately absent.
CONTAINERS = {
    'UIView',
    'UITableViewCell',
    'UICollectionViewCell',
    'UICollectionViewListCell',
    'UITableViewHeaderFooterView',
    'UICollectionReusableView',
    'UIStackView',
    'UIScrollView',
    'UIVisualEffectView',
}

DECL = re.compile(
    r'\b(?:final|public|internal|private|fileprivate|open)\s+'
    r'(?:(?:final|public|internal|private|fileprivate|open)\s+)*'
    r'(class|extension)\s+(\w+)([^{]*)\{'
    r'|\b(class|extension)\s+(\w+)([^{]*)\{'
)
# `accessibilityLabel = x` or `self.accessibilityLabel = x`, but never
# `cell.accessibilityLabel = x` or `$0.accessibilityLabel = x`: a label written
# on another object is that object's business, not this type's.
ASSIGN_LABEL = re.compile(r'(?<![\w.$])(?:self\.)?accessibilityLabel\s*=(?!=)')
ASSIGN_ELEMENT = re.compile(r'(?<![\w.$])(?:self\.)?isAccessibilityElement\s*=(?!=)')


def strip_noise(text):
    """Blank comments and string bodies, keeping every byte offset and line."""
    out = []
    i, n, depth = 0, len(text), 0
    while i < n:
        if depth:
            if text.startswith('/*', i):
                depth, i = depth + 1, i + 2
                out.append('  ')
            elif text.startswith('*/', i):
                depth, i = depth - 1, i + 2
                out.append('  ')
            else:
                out.append('\n' if text[i] == '\n' else ' ')
                i += 1
            continue
        if text.startswith('//', i):
            end = text.find('\n', i)
            end = n if end < 0 else end
            out.append(' ' * (end - i))
            i = end
        elif text.startswith('/*', i):
            depth, i = 1, i + 2
            out.append('  ')
        elif text.startswith('"""', i):
            end = text.find('"""', i + 3)
            end = n if end < 0 else end + 3
            out.append(''.join('\n' if c == '\n' else ' ' for c in text[i:end]))
            i = end
        elif text[i] == '"':
            out.append(' ')
            i += 1
            while i < n and text[i] != '"':
                step = 2 if text[i] == '\\' else 1
                out.append(' ' * min(step, n - i))
                i += step
            if i < n:
                out.append(' ')
                i += 1
        else:
            out.append(text[i])
            i += 1
    return ''.join(out)


def close_brace(text, open_index):
    """Index just past the `}` matching the `{` at open_index, or len(text)."""
    depth = 0
    for i in range(open_index, len(text)):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return i + 1
    return len(text)


def scan(path, superclasses, labels, elements):
    """Record what `path` declares and what each declared type assigns."""
    source = strip_noise(path.read_text(encoding='utf-8', errors='replace'))
    bodies = []
    for match in DECL.finditer(source):
        kind = match.group(1) or match.group(4)
        name = match.group(2) or match.group(5)
        inherits = (match.group(3) or match.group(6) or '').strip()
        start = source.index('{', match.end() - 1)
        bodies.append((start, close_brace(source, start), name))
        if kind == 'class' and inherits.startswith(':'):
            first = re.split(r'[,<\s]', inherits[1:].strip(), maxsplit=1)[0]
            superclasses.setdefault(name, first)

    def owner(position):
        """The innermost declaration containing position, if any."""
        best = None
        for start, end, name in bodies:
            if start <= position < end and (best is None or start > best[0]):
                best = (start, name)
        return best[1] if best else None

    for match in ASSIGN_LABEL.finditer(source):
        name = owner(match.start())
        if name:
            line = source.count('\n', 0, match.start()) + 1
            labels.setdefault(name, []).append((path, line))
    for match in ASSIGN_ELEMENT.finditer(source):
        name = owner(match.start())
        if name:
            elements.add(name)


def ancestry(name, superclasses, seen=None):
    """`name` and every superclass of it declared in the scanned sources."""
    seen = seen or []
    if name in seen:
        return seen
    seen = seen + [name]
    parent = superclasses.get(name)
    return ancestry(parent, superclasses, seen) if parent else seen


def main(argv):
    roots = [Path(a) for a in argv[1:]]
    if not roots:
        print(__doc__.strip().splitlines()[-3], file=sys.stderr)
        return 66
    missing = [r for r in roots if not r.exists()]
    if missing:
        for root in missing:
            print(f'error: {root} does not exist', file=sys.stderr)
        return 66

    superclasses, labels, elements = {}, {}, set()
    for root in roots:
        files = sorted(root.rglob('*.swift')) if root.is_dir() else [root]
        for path in files:
            scan(path, superclasses, labels, elements)

    findings = []
    for name, sites in sorted(labels.items()):
        chain = ancestry(name, superclasses)
        if any(kin in elements for kin in chain):
            continue
        # A type whose superclass is unknown here may well be an element
        # already; only the containers we can name are a certain defect.
        base = next((superclasses[kin] for kin in chain if superclasses.get(kin) in CONTAINERS), None)
        if base is None:
            continue
        findings.append((name, base, sites))

    if not findings:
        print(f'ok: every accessibilityLabel in {len(labels)} types is reachable')
        return 0

    print(
        f'error: {len(findings)} type(s) assign an accessibilityLabel that '
        'UIKit never reads; set isAccessibilityElement = true, or write the '
        'label on the subview that already is an element:',
        file=sys.stderr,
    )
    for name, base, sites in findings:
        for path, line in sites:
            print(f'    {path}:{line}: {name} ({base}) is not an accessibility element', file=sys.stderr)
    return 65


if __name__ == '__main__':
    sys.exit(main(sys.argv))
