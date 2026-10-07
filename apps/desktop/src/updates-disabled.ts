// Fleet build: auto-update is off. Upstream releases are unsigned (and
// signed by a different team when they are), so Santa would block any
// update electron-updater installed — updates ship as a re-signed build
// through the fleet's own deployment instead.
export const UPDATES_DISABLED = true;
