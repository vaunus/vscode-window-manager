"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("path");

const theme = require("../lib/theme");

const { KIND } = theme;

// Fake theme files, read through the "read" hook.
function reader(files) {
  return (file) => {
    if (!(file in files)) throw new Error(`ENOENT ${file}`);
    return files[file];
  };
}

const EXT = "/ext/themes-pack";
const extensions = [
  { extensionPath: "/ext/no-themes", packageJSON: { contributes: {} } },
  {
    extensionPath: EXT,
    packageJSON: {
      contributes: {
        themes: [
          {
            id: "Dark Modern",
            label: "%darkModern%",
            uiTheme: "vs-dark",
            path: "./themes/dark_modern.json",
          },
          {
            id: "Dark+",
            label: "%darkPlus%",
            uiTheme: "vs-dark",
            path: "./themes/dark_plus.json",
          },
          { label: "Sunny", uiTheme: "vs", path: "./themes/sunny.json" },
          { id: "Night HC", uiTheme: "hc-black", path: "./themes/hc.json" },
        ],
      },
    },
  },
];

const files = {
  [path.join(EXT, "themes/dark_modern.json")]:
    '{"include": "./dark_plus.json", "colors": {"titleBar.activeBackground": "#181818", "titleBar.inactiveBackground": "#1F1F1F"}}',
  [path.join(EXT, "themes/dark_plus.json")]:
    '{"include": "./dark_vs.json", "colors": {}}',
  [path.join(EXT, "themes/dark_vs.json")]:
    '{"colors": {"editor.background": "#1E1E1E"}}',
  [path.join(EXT, "themes/sunny.json")]: `{
    // A comment, and a URL that is not one: "http://x"
    "$schema": "vscode://schemas/color-theme",
    /* block comment */
    "colors": {
      "titleBar.activeBackground": "#fe8",
    },
  }`,
  [path.join(EXT, "themes/hc.json")]: '{"colors": {}}',
};
const read = reader(files);

function colors(settings, kind = KIND.dark) {
  return theme.titleBarColors({ extensions, settings, kind, read });
}

function color(settings, kind = KIND.dark) {
  const c = colors(settings, kind);
  return c && c.active;
}

test("parseJsonc reads comments, trailing commas and a BOM", () => {
  assert.deepEqual(
    theme.parseJsonc('﻿{"a": "x // y", /* c */ "b": [1, 2,], // d\n}'),
    { a: "x // y", b: [1, 2] },
  );
  assert.deepEqual(theme.parseJsonc('{"a": "q\\" ,}"}'), { a: 'q" ,}' });
});

test("themeColors merges included files under the theme", () => {
  const colors = theme.themeColors(
    path.join(EXT, "themes/dark_modern.json"),
    read,
  );
  assert.equal(colors["titleBar.activeBackground"], "#181818");
  assert.equal(colors["editor.background"], "#1E1E1E");
});

test("themeColors gives {} for a missing or broken file", () => {
  assert.deepEqual(theme.themeColors("/nope.json", read), {});
  assert.deepEqual(
    theme.themeColors("/bad.json", reader({ "/bad.json": "{" })),
    {},
  );
});

test("themeColors stops on an include loop", () => {
  const loop = reader({
    "/a.json": '{"include": "./a.json", "colors": {"x": "#111111"}}',
  });
  assert.equal(theme.themeColors("/a.json", loop).x, "#111111");
});

test("normalizeColor", () => {
  assert.equal(theme.normalizeColor("#181818"), "#181818");
  assert.equal(theme.normalizeColor("#abc"), "#AABBCC");
  assert.equal(theme.normalizeColor("#abcd"), "#AABBCC");
  assert.equal(theme.normalizeColor("#11223344"), "#112233");
  assert.equal(theme.normalizeColor("red"), null);
  assert.equal(theme.normalizeColor(undefined), null);
});

test("customColor: a theme block wins over a plain key", () => {
  const custom = {
    "titleBar.activeBackground": "#111111",
    "[Dark Modern]": { "titleBar.activeBackground": "#222222" },
  };
  assert.equal(theme.customColor(custom, "Dark Modern"), "#222222");
  assert.equal(theme.customColor(custom, "Dark+"), "#111111");
});

test("customColor: several names and wildcards", () => {
  const custom = {
    "[Sunny][Dark+]": { "titleBar.activeBackground": "#333333" },
    "[Dark*]": { "titleBar.activeBackground": "#444444" },
  };
  assert.equal(theme.customColor(custom, "Sunny"), "#333333");
  assert.equal(theme.customColor(custom, "Dark Modern"), "#444444");
  assert.equal(theme.customColor(custom, "Other"), undefined);
});

test("findTheme by id, or by label when there is no id", () => {
  assert.equal(
    theme.findTheme(extensions, "Dark Modern").file,
    path.join(EXT, "themes/dark_modern.json"),
  );
  assert.equal(theme.findTheme(extensions, "Sunny").name, "Sunny");
  assert.equal(theme.findTheme(extensions, "Missing"), null);
});

test("titleBarColors from the theme and its includes", () => {
  assert.equal(color({ colorTheme: "Dark Modern" }), "#181818");
  assert.equal(color({ colorTheme: "Sunny" }, KIND.light), "#FFEE88");
});

test("titleBarColors falls back to the VSCode default for the theme kind", () => {
  assert.equal(color({ colorTheme: "Dark+" }), "#3C3C3C");
  assert.equal(color({ colorTheme: "Missing" }, KIND.light), "#DDDDDD");
  assert.equal(color({ colorTheme: "Night HC" }, KIND.hcDark), "#000000");
});

test("titleBarColor: color settings win over the theme", () => {
  const colorCustomizations = {
    "[Dark Modern]": { "titleBar.activeBackground": "#00ff00" },
  };
  assert.equal(
    color({ colorTheme: "Dark Modern", colorCustomizations }),
    "#00FF00",
  );
  assert.equal(
    color({
      colorTheme: "Dark Modern",
      colorCustomizations: { "titleBar.activeBackground": "bad" },
    }),
    "#181818",
  );
});

test("titleBarColors uses the preferred theme of the active kind", () => {
  const settings = {
    colorTheme: "Dark Modern",
    preferredLightColorTheme: "Sunny",
    autoDetectColorScheme: true,
  };
  assert.equal(color(settings, KIND.light), "#FFEE88");
  assert.equal(
    color({ ...settings, preferredDarkColorTheme: "Dark+" }, KIND.dark),
    "#3C3C3C",
  );
  // Auto detect off: the color theme, if its kind matches.
  assert.equal(
    color({ ...settings, autoDetectColorScheme: false }, KIND.dark),
    "#181818",
  );
});

test("titleBarColors is null for the native title bar", () => {
  assert.equal(
    colors({ colorTheme: "Dark Modern", titleBarStyle: "native" }),
    null,
  );
});

test("titleBarColors: inactive color from the theme", () => {
  assert.deepEqual(colors({ colorTheme: "Dark Modern" }), {
    active: "#181818",
    inactive: "#1F1F1F",
  });
});

test("titleBarColors: inactive is the active color at 60% over the editor background", () => {
  // Dark+ sets neither: #3C3C3C at 60% over #1E1E1E.
  assert.equal(colors({ colorTheme: "Dark+" }).inactive, "#303030");
  // A custom active color, and a theme with no inactive color.
  const colorCustomizations = {
    "titleBar.activeBackground": "#FF0000",
    "editor.background": "#000000",
  };
  assert.equal(
    colors({ colorTheme: "Dark+", colorCustomizations }).inactive,
    "#990000",
  );
});

test("titleBarColors: a custom inactive color wins", () => {
  const colorCustomizations = {
    "[Dark Modern]": { "titleBar.inactiveBackground": "#123456" },
  };
  assert.equal(
    colors({ colorTheme: "Dark Modern", colorCustomizations }).inactive,
    "#123456",
  );
});

test("shade: the colors under a modal's #00000080 shade", () => {
  assert.deepEqual(theme.shade({ active: "#181818", inactive: "#1F1F1F" }), {
    active: "#0C0C0C",
    inactive: "#0F0F0F",
  });
  assert.deepEqual(theme.shade({ active: "#FFFFFF", inactive: "#000000" }), {
    active: "#7F7F7F",
    inactive: "#000000",
  });
});
