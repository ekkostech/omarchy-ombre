// Run quickshell for the Qt-backed tests only where it can actually start.
//
// quickshell is a Wayland program. Launched without a compositor to talk to
// (an SSH session, a cron job, CI) Qt falls back to the xcb plugin, cannot
// connect, and aborts: every launch leaves a SIGABRT core dump that the fleet
// observer counts as a crash of the desktop shell. Checking `quickshell
// --version` does not catch this, because printing the version needs no
// display. So we look for the compositor's socket ourselves: use
// WAYLAND_DISPLAY when the session has one, otherwise the first wayland-N
// socket in XDG_RUNTIME_DIR (set by pam_systemd even over SSH). When neither
// exists the tests skip instead of crashing.
const fs = require('node:fs');
const path = require('node:path');
const {spawnSync} = require('node:child_process');

function waylandDisplay() {
  if (process.env.WAYLAND_DISPLAY) return process.env.WAYLAND_DISPLAY;
  const runtime = process.env.XDG_RUNTIME_DIR;
  if (!runtime) return '';
  try {
    return fs.readdirSync(runtime)
      .filter(name => /^wayland-\d+$/.test(name) && fs.statSync(path.join(runtime, name)).isSocket())
      .sort()[0] || '';
  } catch {
    return '';
  }
}

const display = waylandDisplay();
const env = display ? {...process.env, WAYLAND_DISPLAY: display, QT_QPA_PLATFORM: 'wayland'} : {...process.env};

function available(shell) {
  return Boolean(display)
    && fs.existsSync(path.join(shell, 'shell/Commons'))
    && spawnSync('quickshell', ['--version']).status === 0;
}

function run(dir, extraEnv = {}) {
  return spawnSync('quickshell', ['-p', dir], {encoding: 'utf8', timeout: 10000, env: {...env, ...extraEnv}});
}

module.exports = {available, display, run};
