"use strict";

// Finds the title bar colors of a VSCode window (focused and not focused),
// from its color theme and its color settings. The bar app paints the box
// over the window buttons in these colors. No VSCode API here, so the tests
// can run without VSCode.

const fs = require("fs");
const path = require("path");

const ACTIVE = "titleBar.activeBackground";
const INACTIVE = "titleBar.inactiveBackground";
const EDITOR = "editor.background";

// vscode.ColorThemeKind values.
const KIND = { light: 1, dark: 2, hcDark: 3, hcLight: 4 };

// VSCode's own colors for themes that do not set them, by theme kind.
const DEFAULTS = {
  [ACTIVE]: { 1: "#DDDDDD", 2: "#3C3C3C", 3: "#000000", 4: "#FFFFFF" },
  [EDITOR]: { 1: "#FFFFFF", 2: "#1E1E1E", 3: "#000000", 4: "#FFFFFF" },
};
// With no inactive color set, VSCode shows the active color at 60%.
const INACTIVE_ALPHA = 0.6;
// While a modal is open, VSCode lays black at this alpha (#00000080) over
// the whole window.
const MODAL_SHADE = 0x80 / 255;

// The theme kind of each "uiTheme" value in a theme contribution.
const UI_KIND = { vs: 1, "vs-dark": 2, "hc-black": 3, "hc-light": 4 };

// Index just after the string that starts at text[i].
function stringEnd(text, i) {
  let j = i + 1;
  while (j < text.length && text[j] !== '"') j += text[j] === "\\" ? 2 : 1;
  return Math.min(j + 1, text.length);
}

function stripComments(text) {
  let out = "";
  let i = 0;
  while (i < text.length) {
    if (text[i] === '"') {
      const j = stringEnd(text, i);
      out += text.slice(i, j);
      i = j;
    } else if (text.startsWith("//", i)) {
      while (i < text.length && text[i] !== "\n") i++;
    } else if (text.startsWith("/*", i)) {
      const end = text.indexOf("*/", i + 2);
      i = end < 0 ? text.length : end + 2;
    } else {
      out += text[i++];
    }
  }
  return out;
}

function stripTrailingCommas(text) {
  let out = "";
  let i = 0;
  while (i < text.length) {
    if (text[i] === '"') {
      const j = stringEnd(text, i);
      out += text.slice(i, j);
      i = j;
      continue;
    }
    if (text[i] === ",") {
      let k = i + 1;
      while (k < text.length && /\s/.test(text[k])) k++;
      if (text[k] === "}" || text[k] === "]") {
        i++;
        continue;
      }
    }
    out += text[i++];
  }
  return out;
}

// JSON with comments and trailing commas, as VSCode allows in theme files.
function parseJsonc(text) {
  return JSON.parse(
    stripTrailingCommas(stripComments(String(text).replace(/^﻿/, ""))),
  );
}

function readText(file) {
  return fs.readFileSync(file, "utf8");
}

// A theme file's colors, with the colors of the files it includes under them.
function themeColors(file, read = readText, depth = 0) {
  if (depth > 10) return {};
  let theme;
  try {
    theme = parseJsonc(read(file));
  } catch {
    return {};
  }
  if (!theme || typeof theme !== "object") return {};
  const base =
    typeof theme.include === "string"
      ? themeColors(
          path.join(path.dirname(file), theme.include),
          read,
          depth + 1,
        )
      : {};
  const own =
    theme.colors && typeof theme.colors === "object" ? theme.colors : {};
  return { ...base, ...own };
}

// "a" over "b": a at the given alpha, b under it. Both "#RRGGBB".
function mix(a, b, alpha) {
  const ch = (hex, i) => parseInt(hex.slice(1 + i * 2, 3 + i * 2), 16);
  const out = [0, 1, 2].map((i) =>
    Math.round(ch(a, i) * alpha + ch(b, i) * (1 - alpha)),
  );
  return `#${out
    .map((n) => n.toString(16).padStart(2, "0"))
    .join("")
    .toUpperCase()}`;
}

// "#RGB", "#RGBA", "#RRGGBB" or "#RRGGBBAA" as "#RRGGBB". Alpha is dropped.
// Null for anything else.
function normalizeColor(value) {
  if (typeof value !== "string") return null;
  const m = /^#([0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$/i.exec(value.trim());
  if (!m) return null;
  let hex = m[1];
  if (hex.length <= 4)
    hex = hex
      .slice(0, 3)
      .split("")
      .map((c) => c + c)
      .join("");
  return `#${hex.slice(0, 6).toUpperCase()}`;
}

// A theme name pattern from a "[...]" block. "*" matches any text.
function nameMatches(pattern, name) {
  const re = pattern
    .split("*")
    .map((s) => s.replace(/[.+?^${}()|[\]\\]/g, "\\$&"))
    .join(".*");
  return new RegExp(`^${re}$`).test(name);
}

// A color from the "workbench.colorCustomizations" setting.
// Plain keys apply to all themes. A "[Theme Name]" block applies to one
// theme, and wins over plain keys. "[A][B]" names more than one theme.
function customColor(custom, themeName, colorKey = ACTIVE) {
  if (!custom || typeof custom !== "object") return undefined;
  let color = custom[colorKey];
  for (const [key, value] of Object.entries(custom)) {
    if (!key.startsWith("[") || !value || typeof value !== "object") continue;
    const names = (key.match(/\[[^\]]*\]/g) || []).map((n) => n.slice(1, -1));
    if (
      names.some((n) => nameMatches(n, themeName)) &&
      value[colorKey] !== undefined
    )
      color = value[colorKey];
  }
  return color;
}

// The theme a setting names, from the themes that extensions contribute.
// Settings name a theme by its id, or by its label when it has no id.
function findTheme(extensions, name) {
  if (!name) return null;
  for (const ext of extensions) {
    const themes =
      ext &&
      ext.packageJSON &&
      ext.packageJSON.contributes &&
      ext.packageJSON.contributes.themes;
    if (!Array.isArray(themes)) continue;
    for (const t of themes) {
      if (!t || typeof t.path !== "string") continue;
      if (t.id === name || t.label === name) {
        return {
          name: t.id || t.label,
          kind: UI_KIND[t.uiTheme] || null,
          file: path.join(ext.extensionPath, t.path),
        };
      }
    }
  }
  return null;
}

// The theme in use. VSCode has already picked it, so its kind is known.
// The settings say which theme that is: the first named theme of the right
// kind wins. With "window.autoDetectColorScheme" on, the preferred themes
// come first.
function activeTheme(extensions, settings, kind) {
  const preferred = {
    [KIND.light]: settings.preferredLightColorTheme,
    [KIND.dark]: settings.preferredDarkColorTheme,
    [KIND.hcDark]: settings.preferredHighContrastColorTheme,
    [KIND.hcLight]: settings.preferredHighContrastLightColorTheme,
  }[kind];
  const names = settings.autoDetectColorScheme
    ? [preferred, settings.colorTheme]
    : [settings.colorTheme, preferred];
  let fallback = null;
  for (const name of names) {
    const t = findTheme(extensions, name);
    if (!t) continue;
    if (t.kind === kind) return t;
    fallback = fallback || t;
  }
  return fallback;
}

// The title bar colors as { active, inactive }, each "#RRGGBB". Active is
// for a focused window. Null when macOS draws the title bar
// ("window.titleBarStyle": "native"), so the bar uses its own color.
function titleBarColors({ extensions, settings, kind, read = readText }) {
  if (settings.titleBarStyle === "native") return null;
  const theme = activeTheme(extensions, settings, kind);
  const name = theme ? theme.name : "";
  const colors = theme ? themeColors(theme.file, read) : {};
  // A color setting wins over the theme.
  const pick = (key) =>
    normalizeColor(customColor(settings.colorCustomizations, name, key)) ||
    normalizeColor(colors[key]);
  const active = pick(ACTIVE) || DEFAULTS[ACTIVE][kind];
  if (!active) return null;
  const editor = pick(EDITOR) || DEFAULTS[EDITOR][kind] || active;
  const inactive = pick(INACTIVE) || mix(active, editor, INACTIVE_ALPHA);
  return { active, inactive };
}

// The title bar colors under a modal's shade.
function shade(colors) {
  return {
    active: mix("#000000", colors.active, MODAL_SHADE),
    inactive: mix("#000000", colors.inactive, MODAL_SHADE),
  };
}

module.exports = {
  KIND,
  shade,
  parseJsonc,
  themeColors,
  normalizeColor,
  customColor,
  findTheme,
  activeTheme,
  titleBarColors,
};
