'use strict';

// Reader for two records the CLI keeps — the plugin never writes either.
//
// The hooks run `hwip notify … 2>/dev/null || true`, so a failed push used to
// look exactly like "quiet mode, nothing to send". `hwip notify` now records
// its own last failure and deletes the record on the next good push; this file
// turns that record into one line for /hwip-mode (scripts/hwip-mode.sh runs it)
// and the SessionStart hook (hwip-setup.js requires it).
//
// The format is the CLI's (cli src/notify-failure.ts is the source of truth;
// tests/fixtures/last-notify-failure.json holds the line both repos pin):
//
//   ${XDG_STATE_HOME:-~/.local/state}/hwip/last-notify-failure.json
//   {"v":1,"at":"<ISO>","kind":"<kind>","status":<int|null>,"code":"<string|null>"}
//
// `no-app` and `unsealed` are refusals the CLI made before anything was sent:
// they carry no HTTP status. Anything else — no file, another version, an
// unknown kind — reads as "no failure": a CLI that writes nothing this file
// knows must not make the plugin guess.
//
// The second record is the devices whose encryption key changed. Whoever
// replaced the pin (the CLI, its listener, the MCP server) wrote it, and the
// hook's stderr that saw it went nowhere, so it waits until a person is shown
// it: here, SessionStart and /hwip-mode (`node notify-failure.js key-changes`)
// show each change once and delete the record. The format is the CLI's
// (cli src/key-changes.ts; tests/fixtures/key-changes.json):
//
//   ~/.hwip/key-changes.json
//   {"v":1,"changes":[{"deviceId":"<id>","at":"<ISO>","name":"<nickname, optional>"}]}
//
// Taken as the CLI takes it: under ~/.hwip/trusted-devices.lock (the lock
// every writer holds while it rewrites the record, cli src/trust-lock.ts),
// renamed to key-changes.json.<pid>.taken, read, deleted — a writer cannot
// put back what was taken, and of two readers only the one whose rename wins
// shows it. A lock held past a second leaves the record for the next look.

const fs = require('fs');
const os = require('os');
const path = require('path');

const KIND_TEXT = {
    'no-key': 'no API key — run: npx @hwip/cli install',
    auth: 'API key rejected — it may have been revoked; run: hwip login',
    quota: 'push quota used up',
    'rate-limit': 'rate limited by the server',
    client: 'request rejected by the server',
    server: 'server error',
    timeout: 'request timed out',
    network: 'could not reach the server',
    'no-app': 'no app is signed in — sign in to the Hwip app on an iPhone or Android phone',
    unsealed: 'could not encrypt the push, so nothing was sent — run: hwip verify',
};

const ISO_UTC = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/;
/** A device id as the app, the CLI and the server mint them. */
const DEVICE_ID = /^[A-Za-z0-9_-]{1,64}$/;
const NAME_MAX = 80;
const MAX_KEY_CHANGES = 64;

const stateDir = () =>
    path.join(process.env.XDG_STATE_HOME || path.join(os.homedir(), '.local', 'state'), 'hwip');

const failurePath = () => path.join(stateDir(), 'last-notify-failure.json');

const keyChangesPath = () => path.join(os.homedir(), '.hwip', 'key-changes.json');

const trustLockPath = () => path.join(os.homedir(), '.hwip', 'trusted-devices.lock');

/** The CLI's lock protocol (cli src/trust-lock.ts): created with `wx`, "<pid> <ms>" inside, older than 10 s = left by a dead process. */
const LOCK_STALE_MS = 10000;
const LOCK_WAIT_MS = 1000;
const LOCK_POLL_MS = 20;

const sleepSync = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

const lockAge = (lock) => {
    try { return Date.now() - fs.statSync(lock).mtimeMs; } catch { return null; }
};

/** Run `fn` holding the trust lock; `{ locked: false }` when it cannot be had, and `fn` did not run. */
const withTrustLock = (fn) => {
    const lock = trustLockPath();
    const deadline = Date.now() + LOCK_WAIT_MS;
    let brokeStale = false;
    for (;;) {
        let fd;
        try {
            fd = fs.openSync(lock, 'wx', 0o600);
        } catch (err) {
            if (!err || err.code !== 'EEXIST') return { locked: false };
            const age = lockAge(lock);
            if (!brokeStale && age !== null && age > LOCK_STALE_MS && (lockAge(lock) || 0) > LOCK_STALE_MS) {
                brokeStale = true;
                try { fs.unlinkSync(lock); } catch { /* someone else broke it first */ }
                continue;
            }
            if (Date.now() >= deadline) return { locked: false };
            sleepSync(LOCK_POLL_MS);
            continue;
        }
        try {
            fs.writeSync(fd, `${process.pid} ${Date.now()}\n`);
        } catch {
            // An empty lock nobody owns would hold every writer off until it goes stale.
            fs.closeSync(fd);
            fs.rmSync(lock, { force: true });
            return { locked: false };
        }
        fs.closeSync(fd);
        break;
    }
    try {
        return { locked: true, value: fn() };
    } finally {
        fs.rmSync(lock, { force: true });
    }
};

/** The record, or null when there is none this version understands. */
const readLastPushFailure = () => {
    let raw;
    try { raw = JSON.parse(fs.readFileSync(failurePath(), 'utf-8')); } catch { return null; }
    if (!raw || raw.v !== 1) return null;
    // Validated, not trusted: the timestamp is echoed to the user, and `in`
    // would accept prototype keys like "toString" as a kind.
    if (typeof raw.at !== 'string' || !ISO_UTC.test(raw.at)) return null;
    if (!Object.prototype.hasOwnProperty.call(KIND_TEXT, raw.kind)) return null;
    return {
        at: raw.at,
        kind: raw.kind,
        status: Number.isInteger(raw.status) ? raw.status : null,
    };
};

/** One line for a person. Nothing from the file is echoed except the kind's
 *  own text, the timestamp and the status number. */
const describeLastPushFailure = (f) => {
    const text = KIND_TEXT[f.kind];
    return `Last Hwip push failed at ${f.at}: ${text}` +
        `${f.status === null ? '' : ` (HTTP ${f.status})`}` +
        `${text.includes('hwip verify') ? '.' : '. Details: hwip verify'}`;
};

/** The relay writes nicknames: no control, direction or zero-width characters, one space per run, 80 characters at most. */
const cleanName = (name) => {
    if (typeof name !== 'string') return undefined;
    const plain = name.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]|\p{Cf}/gu, '').replace(/\s+/g, ' ').trim();
    const chars = Array.from(plain);
    if (chars.length === 0) return undefined;
    return chars.length > NAME_MAX ? chars.slice(0, NAME_MAX).join('') : plain;
};

const takeRecord = (file) => {
    const taken = `${file}.${process.pid}.taken`;
    try { fs.renameSync(file, taken); } catch { return null; }
    try { return JSON.parse(fs.readFileSync(taken, 'utf-8')); } catch { return null; } finally {
        try { fs.rmSync(taken, { force: true }); } catch { /* gone already */ }
    }
};

/** The changes nobody has been shown yet, and the record gone. A record this
 *  version does not understand reads as none, and goes too. */
const takeKeyChanges = () => {
    const file = keyChangesPath();
    // Most sessions find nothing: no lock, and no ~/.hwip made for one.
    if (!fs.existsSync(file)) return [];
    const done = withTrustLock(() => takeRecord(file));
    const raw = done.locked ? done.value : null;
    if (!raw || raw.v !== 1 || !Array.isArray(raw.changes)) return [];
    const changes = [];
    for (const c of raw.changes.slice(-MAX_KEY_CHANGES)) {
        if (!c || typeof c.deviceId !== 'string' || !DEVICE_ID.test(c.deviceId)) continue;
        if (typeof c.at !== 'string' || !ISO_UTC.test(c.at)) continue;
        const name = cleanName(c.name);
        changes.push(name === undefined ? { deviceId: c.deviceId, at: c.at } : { deviceId: c.deviceId, at: c.at, name });
    }
    return changes;
};

/** One line for a person: the cleaned name, else the checked device id. */
const describeKeyChange = (c) =>
    `Hwip: ${c.name || c.deviceId} changed its encryption key — the new key is trusted. Not expecting that? Check: hwip trust`;

module.exports = { readLastPushFailure, describeLastPushFailure, failurePath, takeKeyChanges, describeKeyChange, keyChangesPath };

if (require.main === module) {
    if (process.argv[2] === 'key-changes') {
        for (const c of takeKeyChanges()) process.stdout.write(`${describeKeyChange(c)}\n`);
    } else {
        const f = readLastPushFailure();
        if (f) process.stdout.write(`${describeLastPushFailure(f)}\n`);
    }
}
