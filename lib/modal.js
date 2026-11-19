"use strict";

// Guesses whether a VSCode modal editor (for example Settings) is open.
// While one is open, VSCode shades the whole window, title bar included.
// The extension API has no flag for this, so this works it out from the
// editor groups. No VSCode API here, so the tests can run without VSCode.
//
// A modal adds its own editor group, after all the others. It holds an
// internal page (Settings, Keyboard Shortcuts, an extension's page), which
// the API shows as a tab with no known kind.
//
// groups: [{ viewColumn, tabs: [{ label, known, active }] }]
//   known: the API knows what the tab shows (a file, a diff, a notebook...).
function isModalOpen(groups) {
  // The window always has its own group, so a modal makes at least two.
  if (!Array.isArray(groups) || groups.length < 2) return false;
  const last = groups.reduce((a, b) => (b.viewColumn > a.viewColumn ? b : a));
  const tab = last.tabs.find((t) => t.active);
  if (!tab || tab.known) return false;
  // A split copies the page, so another group has it too.
  return !groups.some(
    (g) => g !== last && g.tabs.some((t) => t.label === tab.label),
  );
}

module.exports = { isModalOpen };
