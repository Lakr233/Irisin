// Pulls what the page shares with the app out of the app's own sources, so
// there is one accent colour and one icon in the repository: the accent from
// the design token (Irisin has no colour set in an asset catalog), the icon
// from AppIcon, made small with sips. Runs before every webpack build; the
// output lives in src/generated and is not checked in.
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const repo = path.resolve(__dirname, '..', '..');
const out = path.join(__dirname, '..', 'src', 'generated');
fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(out, { recursive: true });

// Accent: UIColor.buttonNormal, "the one accent", light and dark.
const tokens = fs.readFileSync(path.join(repo, 'Irisin/Interface/DesignTokens/UIColor+Content.swift'), 'utf8');
const match = tokens.match(/static let buttonNormal = UIColor\(light: UIColor\(hex: 0x([0-9A-Fa-f]{6})\), dark: UIColor\(hex: 0x([0-9A-Fa-f]{6})\)\)/);
if (!match) throw new Error('could not read UIColor.buttonNormal from UIColor+Content.swift');
const [accentLight, accentDark] = [match[1], match[2]].map((hex) => '#' + hex.toLowerCase());
fs.writeFileSync(
  path.join(out, 'accent.css'),
  `/* generated from UIColor+Content.swift (buttonNormal) */\n:root { --accent: ${accentLight}; }\n@media (prefers-color-scheme: dark) { :root { --accent: ${accentDark}; } }\n`,
);

// The app's icon, light and dark, at the touch icon's size.
const icons = path.join(repo, 'Irisin/Resources/Assets.xcassets/AppIcon.appiconset');
for (const [source, name] of [
  ['AppIcon.jpg', 'icon-light.png'],
  ['AppIcon-dark.jpg', 'icon-dark.png'],
]) {
  execFileSync('sips', ['-s', 'format', 'png', '-Z', '180', path.join(icons, source), '--out', path.join(out, name)], {
    stdio: 'ignore',
  });
}

console.log(`synced accent ${accentLight}/${accentDark} and the icon`);
