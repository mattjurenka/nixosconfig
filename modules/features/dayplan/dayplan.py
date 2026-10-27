#!/usr/bin/env python3
"""dayplan -- what should I be doing right now, from the "Claude" Google Calendar.

The calendar is the only source of truth. Claude writes time blocks to it in the
morning and an event titled "<approval_prefix>" running from the moment the plan
was approved to the end of the day; everything here reads that back.

  dayplan daemon    refresh the calendar, notify at block starts, hold the gate
  dayplan watch     a bar line on stdout whenever it changes (the noctalia widget)
  dayplan bar       that line, once
  dayplan today     today's plan as a list
  dayplan gate      exit 0 if today's plan is approved, 1 if not
  dayplan skip      open the gate for today without a plan (logged)
  dayplan sync      refresh the cache now
  dayplan events    today's events as JSON, for whatever is doing the planning
  dayplan auth      one-time OAuth consent for the Calendar API backend
  dayplan apply     write a plan to the calendar (JSON on stdin; API backend only)

Two ways to read the calendar, picked by which credential is present in
~/.config/dayplan:

  oauth-client.json + oauth-token.json  the Calendar API. Events show up within
                                        seconds, and `apply` can write them.
                                        Set up with
                                          dayplan auth --client-json <download>
  ical-url                              the calendar's secret .ics address. No
                                        setup beyond pasting a URL, but Google
                                        serves it from a cache that can lag by
                                        an hour or more -- which is an hour of
                                        staying locked out after approving.

Standard library only; no pip packages. Everything configurable is in DEFAULTS,
overridden by ~/.config/dayplan/config.json (which modules/features/dayplan.nix
generates).
"""

import datetime as dt
import http.server
import json
import os
import re
import secrets
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from pathlib import Path
from zoneinfo import ZoneInfo

CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "dayplan"
CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "dayplan"
STATE_DIR = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "dayplan"

DEFAULTS = {
    # Which calendar. Only used by the API backend; the iCal address names its
    # own calendar.
    "calendar_id": "primary",
    # None means "whatever the machine's clock says". Pinning it matters for a
    # laptop that travels: the plan was made in one zone and its blocks mean
    # the hours of that zone.
    "timezone": None,
    "sync_seconds": 120,
    "tick_seconds": 20,
    # Before this hour, "today" still means yesterday -- so a 1am session is
    # still working under the plan that was approved yesterday morning, and the
    # gate shuts again at 4am rather than at midnight.
    "day_starts_hour": 4,
    "approval_prefix": "✅ Plan approved",
    "gate_enabled": True,
    # Windows closed while the gate is shut, all case-insensitive. See
    # is_blocked for why these are two lists rather than one: an app_id is
    # stable, a title is fleeting and browser-only.
    "blocked_app_ids": [r"^steam$", r"^steam_app_\d+", r"^steamwebhelper$", r"^lutris$"],
    "blocked_titles": [r"youtube", r"twitch", r"reddit", r"netflix"],
    # Which windows a title rule is allowed to judge. A title only means a
    # website inside a browser; anywhere else "youtube" is as likely to be a
    # filename in an editor or an argument in a shell. `chrom` covers both
    # chromium-browser and the chrome-<hash>-Default windows a PWA gets.
    "title_scope_app_ids": [r"chrom", r"firefox", r"librewolf", r"brave", r"\bzen\b", r"epiphany"],
    # Opened once a day, the first time the gate has to step in.
    "planning_url": "https://claude.ai/new",
    # How stale the cache may be before the gate stops closing windows. A
    # morning with no network is not a morning without a plan, and being locked
    # out of your own laptop by a dead wifi link is the one failure this must
    # not have.
    "max_cache_age_minutes": 45,
    # The shortest gap between two "plan your day first" notifications. A
    # window that ignores close-window -- Steam with an "are you sure" dialog
    # up, say -- is closed again on every tick, and without this that is a
    # critical notification every 20 seconds.
    "gate_notify_cooldown_seconds": 180,
    "notify_minutes_before": 0,
}

SCOPE = "https://www.googleapis.com/auth/calendar"
AUTH_ENDPOINT = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token"
API_ROOT = "https://www.googleapis.com/calendar/v3"


# -------------------------------------------------------------- config and time

def load_config():
    cfg = dict(DEFAULTS)
    path = CONFIG_DIR / "config.json"
    if path.exists():
        try:
            cfg.update(json.loads(path.read_text()))
        except json.JSONDecodeError as e:
            print(f"dayplan: ignoring bad {path}: {e}", file=sys.stderr)
    return cfg


def tz(cfg):
    name = cfg.get("timezone")
    if name:
        try:
            return ZoneInfo(name)
        except Exception:
            print(f"dayplan: unknown timezone {name!r}, using the system one", file=sys.stderr)
    return dt.datetime.now().astimezone().tzinfo


def now(cfg):
    return dt.datetime.now(tz(cfg))


def plan_date(cfg, at=None):
    """The date whose plan is in force. Rolls over at day_starts_hour, not midnight."""
    at = at or now(cfg)
    return (at - dt.timedelta(hours=cfg["day_starts_hour"])).date()


def day_window(cfg, day):
    start = dt.datetime.combine(day, dt.time(cfg["day_starts_hour"]), tz(cfg))
    return start, start + dt.timedelta(days=1)


# ---------------------------------------------------------------- iCal parsing

def _unfold(text):
    return re.sub(r"\r?\n[ \t]", "", text).splitlines()


def _unescape(v):
    for a, b in ((r"\n", "\n"), (r"\N", "\n"), (r"\,", ","), (r"\;", ";"), (r"\\", "\\")):
        v = v.replace(a, b)
    return v


def _parse_ical_dt(cfg, params, value):
    """-> (aware datetime, all_day)."""
    if params.get("VALUE") == "DATE" or re.fullmatch(r"\d{8}", value):
        return dt.datetime.strptime(value[:8], "%Y%m%d").replace(tzinfo=tz(cfg)), True
    if value.endswith("Z"):
        return dt.datetime.strptime(value, "%Y%m%dT%H%M%SZ").replace(tzinfo=dt.timezone.utc), False
    naive = dt.datetime.strptime(value, "%Y%m%dT%H%M%S")
    tzid = params.get("TZID")
    try:
        zone = ZoneInfo(tzid) if tzid else tz(cfg)
    except Exception:
        zone = tz(cfg)
    return naive.replace(tzinfo=zone), False


def parse_ics(cfg, text):
    """The subset Google writes for one-off events.

    Recurring and cancelled entries are dropped rather than half-expanded: a
    plan is written fresh each morning, so nothing dayplan cares about repeats,
    and a mis-expanded RRULE would be worse than a missing one.
    """
    events, cur = [], None
    for line in _unfold(text):
        if line == "BEGIN:VEVENT":
            cur = {}
            continue
        if line == "END:VEVENT":
            if cur and "start" in cur and not cur.get("recurring") and cur.get("status") != "CANCELLED":
                if "end" not in cur:
                    span = dt.timedelta(days=1) if cur["all_day"] else dt.timedelta(0)
                    cur["end"] = cur["start"] + span
                events.append(cur)
            cur = None
            continue
        if cur is None or ":" not in line:
            continue
        head, value = line.split(":", 1)
        name, *raw = head.split(";")
        params = dict(p.split("=", 1) for p in raw if "=" in p)
        if name == "DTSTART":
            cur["start"], cur["all_day"] = _parse_ical_dt(cfg, params, value)
        elif name == "DTEND":
            cur["end"], _ = _parse_ical_dt(cfg, params, value)
        elif name == "SUMMARY":
            cur["title"] = _unescape(value)
        elif name == "DESCRIPTION":
            cur["desc"] = _unescape(value)
        elif name == "UID":
            cur["uid"] = value
        elif name == "STATUS":
            cur["status"] = value
        elif name == "RRULE":
            cur["recurring"] = True
    out = []
    for e in events:
        out.append({
            # The start is in the key because Google reuses a UID across the
            # instances of anything it considers one event, and a notification
            # is owed per block rather than per UID.
            "uid": e.get("uid", "") + "@" + e["start"].isoformat(),
            "id": e.get("uid", ""),
            "title": e.get("title", "(untitled)"),
            "desc": e.get("desc", ""),
            "start": e["start"],
            "end": e["end"],
            "all_day": e["all_day"],
        })
    out.sort(key=lambda e: e["start"])
    return out


# ------------------------------------------------------------------ credentials

def client_file():
    return CONFIG_DIR / "oauth-client.json"


def token_file():
    return CONFIG_DIR / "oauth-token.json"


def read_client(path):
    """-> {"client_id", "client_secret"} from either shape of client file.

    The console hands you `client_secret_<id>.json`, which wraps the pair in a
    single key naming the client type -- `installed` for a Desktop app, `web`
    for a Web app. Accepted as-is rather than asking for the two fields to be
    retyped, because retyping a secret is how a secret ends up in a shell
    history. A flat {"client_id", "client_secret"} is accepted too, which is
    what `auth --client-json` leaves behind.

    The type is checked here on purpose: only a Desktop client may redirect to
    a loopback port, so a Web one has to be caught now rather than arriving
    much later as a redirect_uri_mismatch from Google, which reads like a bug
    in this script. Same reasoning, and the same check, as
    second-brain/host/google_consent.py.
    """
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise SystemExit(f"no such file: {path}") from None
    except (OSError, ValueError) as e:
        raise SystemExit(f"could not read {path}: {type(e).__name__}: {e}") from None

    if "web" in data and isinstance(data["web"], dict):
        raise SystemExit(
            f"{path} is a 'web' OAuth client.\n"
            "dayplan needs a 'Desktop app' client: only those may use a loopback\n"
            "redirect on an arbitrary port, which is how the consent comes back.\n"
            "Create a Desktop-app client in the same project and use that instead."
        )
    block = data.get("installed") if isinstance(data.get("installed"), dict) else data

    pair = {
        "client_id": str(block.get("client_id", "")).strip(),
        "client_secret": str(block.get("client_secret", "")).strip(),
    }
    if not pair["client_id"] or not pair["client_secret"]:
        raise SystemExit(
            f"{path} carries no client_id/client_secret.\n"
            "Re-download it from the OAuth client in the Google Cloud console."
        )
    return pair


def ical_file(cfg):
    return Path(cfg.get("ical_url_file") or (CONFIG_DIR / "ical-url")).expanduser()


def backend(cfg):
    if client_file().exists() and token_file().exists():
        return "api"
    if ical_file(cfg).exists():
        return "ical"
    return None


def _write_private(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    # Created 0600 before anything is written to it, rather than chmod'ed after:
    # a refresh token is readable by the whole machine in the gap otherwise.
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text)


def _post_form(url, fields):
    body = urllib.parse.urlencode(fields).encode()
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/x-www-form-urlencoded"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())


def access_token():
    """A live bearer token, refreshed and cached on disk until shortly before it expires."""
    client = read_client(client_file())
    stored = json.loads(token_file().read_text())
    # 60s of slack, so a token does not expire between this check and the call
    # it is about to be used for.
    if stored.get("access_token") and stored.get("expires_at", 0) > time.time() + 60:
        return stored["access_token"]
    got = _post_form(TOKEN_ENDPOINT, {
        "client_id": client["client_id"],
        "client_secret": client["client_secret"],
        "refresh_token": stored["refresh_token"],
        "grant_type": "refresh_token",
    })
    stored["access_token"] = got["access_token"]
    stored["expires_at"] = time.time() + int(got.get("expires_in", 3600))
    _write_private(token_file(), json.dumps(stored))
    return stored["access_token"]


class ApiError(Exception):
    """A Google error with its body kept.

    urllib renders an HTTPError as "HTTP Error 403: Forbidden", which is the
    least useful sentence Google could have been quoted on: every interesting
    403 here -- the Calendar API not enabled in the project, the consented
    account having no access to the calendar, a scope that was never granted --
    looks identical, and the response body says which in plain words. Throwing
    it away costs a diagnostic round trip, so it is carried.
    """


def _api_error(e):
    try:
        err = json.loads(e.read().decode())["error"]
    except Exception:
        return ApiError(f"HTTP {e.code} {e.reason}")
    reasons = {d.get("reason") for d in err.get("errors", []) if d.get("reason")}
    reasons |= {
        d["reason"] for d in err.get("details", [])
        if d.get("@type", "").endswith("ErrorInfo") and d.get("reason")
    }
    tag = f" [{', '.join(sorted(reasons))}]" if reasons else ""
    return ApiError(f"HTTP {e.code}{tag}: {err.get('message', e.reason)}")


def api(method, path, params=None, body=None):
    url = API_ROOT + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": "Bearer " + access_token(),
        "Content-Type": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
    except urllib.error.HTTPError as e:
        raise _api_error(e) from None
    return json.loads(raw.decode()) if raw else {}


def auth(cfg, argv=()):
    """The one-time consent. Google dropped the copy-a-code flow, so this is the
    loopback one: a server on localhost for exactly as long as it takes to catch
    one redirect.

        dayplan auth --client-json ~/Downloads/client_secret_*.json
        dayplan auth                     # once the client is already in place

    The first form copies the client in at 0600 and then consents, so the
    console download is the only file anyone has to handle.
    """
    source = None
    for i, a in enumerate(argv):
        if a == "--client-json" and i + 1 < len(argv):
            source = Path(argv[i + 1]).expanduser()
        elif a.startswith("--client-json="):
            source = Path(a.split("=", 1)[1]).expanduser()

    if source is not None:
        client = read_client(source)
        _write_private(client_file(), json.dumps(client))
        print(f"Client {client['client_id']}\n  -> {client_file()}", flush=True)
    elif client_file().exists():
        client = read_client(client_file())
    else:
        print(
            "No OAuth client yet. Point this at the one the console gave you:\n"
            "  dayplan auth --client-json ~/Downloads/client_secret_*.json\n"
            "\n"
            "The second-brain work already created a Desktop client -- reusing it is\n"
            "fine, an OAuth client is an app identity rather than an account. Check\n"
            "two things in its project first: the Google Calendar API is enabled, and\n"
            "this account is on the consent screen's test-user list (otherwise consent\n"
            "comes back access_denied). See second-brain/host/google_consent.py.\n"
            "\n"
            "Otherwise: console.cloud.google.com -> APIs & Services -> Credentials ->\n"
            "Create credentials -> OAuth client ID -> Desktop app.",
            file=sys.stderr,
        )
        return 1

    state = secrets.token_urlsafe(16)
    holder = {}

    class Catch(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            holder.update({k: v[0] for k, v in query.items()})
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write("dayplan is authorised. Close this tab.\n".encode())

        def log_message(self, *a):
            pass

    with http.server.HTTPServer(("127.0.0.1", 0), Catch) as server:
        redirect = f"http://127.0.0.1:{server.server_port}/"
        url = AUTH_ENDPOINT + "?" + urllib.parse.urlencode({
            "client_id": client["client_id"],
            "redirect_uri": redirect,
            "response_type": "code",
            "scope": SCOPE,
            # Both are needed to be *handed* a refresh token: offline asks for
            # one, and consent forces a fresh grant on a client that already
            # has one -- without it a re-run comes back with an access token
            # only and nothing to renew it with.
            "access_type": "offline",
            "prompt": "consent",
            "state": state,
        })
        # Flushed, and printed before the browser is tried rather than after.
        # stdout is a pipe whenever this is run by anything but a terminal, and
        # a block-buffered URL is a URL nobody sees until the process exits --
        # which it will not do until the redirect it is waiting for arrives.
        # That deadlock is the whole reason this is explicit.
        print("Open this and approve:\n\n  " + url + "\n", flush=True)
        # Best effort. There is no browser to open on a machine reached over
        # ssh, and `webbrowser` finds none in an environment without DISPLAY or
        # WAYLAND_DISPLAY either -- it returns False and says nothing. The URL
        # above is the thing that actually has to work.
        if not webbrowser.open(url):
            print("(couldn't open a browser here -- use the URL above)", flush=True)
        print(f"Waiting for the redirect on 127.0.0.1:{server.server_port} ...", flush=True)
        server.handle_request()

    if holder.get("state") != state or "code" not in holder:
        print(f"auth failed: {holder.get('error', 'no code came back')}", file=sys.stderr)
        return 1
    got = _post_form(TOKEN_ENDPOINT, {
        "client_id": client["client_id"],
        "client_secret": client["client_secret"],
        "code": holder["code"],
        "grant_type": "authorization_code",
        "redirect_uri": redirect,
    })
    if "refresh_token" not in got:
        print("auth failed: Google returned no refresh token", file=sys.stderr)
        return 1
    _write_private(token_file(), json.dumps({
        "refresh_token": got["refresh_token"],
        "access_token": got.get("access_token"),
        "expires_at": time.time() + int(got.get("expires_in", 3600)),
    }))
    print(f"Saved to {token_file()}. dayplan will use the Calendar API from now on.", flush=True)
    return 0


# --------------------------------------------------------------- fetch and cache

def cache_file():
    return CACHE_DIR / "events.json"


def _iso(d):
    return d.isoformat()


def _from_iso(s):
    return dt.datetime.fromisoformat(s)


def fetch_ical(cfg):
    url = ical_file(cfg).read_text().strip()
    req = urllib.request.Request(url, headers={"User-Agent": "dayplan"})
    with urllib.request.urlopen(req, timeout=30) as r:
        body = r.read().decode("utf-8", "replace")
    if "BEGIN:VCALENDAR" not in body:
        raise ValueError("that URL does not serve a calendar")
    return parse_ics(cfg, body)


def fetch_api(cfg):
    """Three days either side of now, which covers "what did I do yesterday" and
    the deadlines the planner looks ahead at without pulling the whole year."""
    lo = now(cfg) - dt.timedelta(days=3)
    hi = now(cfg) + dt.timedelta(days=4)
    got = api("GET", f"/calendars/{urllib.parse.quote(cfg['calendar_id'])}/events", params={
        "timeMin": lo.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "timeMax": hi.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        # Recurrences expanded server-side and ordered, so the parsing this
        # backend skips is parsing nobody has to get right.
        "singleEvents": "true",
        "orderBy": "startTime",
        "maxResults": "250",
    })
    out = []
    for item in got.get("items", []):
        if item.get("status") == "cancelled":
            continue
        start, end = item.get("start", {}), item.get("end", {})
        all_day = "date" in start
        if all_day:
            s = dt.datetime.fromisoformat(start["date"]).replace(tzinfo=tz(cfg))
            e = dt.datetime.fromisoformat(end.get("date", start["date"])).replace(tzinfo=tz(cfg))
        else:
            s = dt.datetime.fromisoformat(start["dateTime"])
            e = dt.datetime.fromisoformat(end.get("dateTime", start["dateTime"]))
        out.append({
            "uid": item["id"] + "@" + s.isoformat(),
            "id": item["id"],
            "title": item.get("summary", "(untitled)"),
            "desc": item.get("description", ""),
            "start": s,
            "end": e,
            "all_day": all_day,
        })
    out.sort(key=lambda e: e["start"])
    return out


def sync(cfg):
    which = backend(cfg)
    if which is None:
        return False, (
            f"no calendar credential: write the secret iCal address to {ical_file(cfg)}, "
            "or run `dayplan auth` for the Calendar API"
        )
    try:
        events = fetch_api(cfg) if which == "api" else fetch_ical(cfg)
    except Exception as e:
        return False, f"sync failed ({which}): {e}"
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    payload = {
        "synced_at": _iso(now(cfg)),
        "backend": which,
        "events": [dict(e, start=_iso(e["start"]), end=_iso(e["end"])) for e in events],
    }
    tmp = cache_file().with_suffix(".tmp")
    tmp.write_text(json.dumps(payload))
    # Renamed into place so a reader never sees half a file.
    tmp.replace(cache_file())
    return True, f"ok ({which}, {len(events)} events)"


def load_cache(cfg):
    """-> (events, age in seconds or None if there is no cache)."""
    if not cache_file().exists():
        return [], None
    try:
        payload = json.loads(cache_file().read_text())
    except json.JSONDecodeError:
        return [], None
    events = [
        dict(e, start=_from_iso(e["start"]), end=_from_iso(e["end"]))
        for e in payload.get("events", [])
    ]
    try:
        age = (now(cfg) - _from_iso(payload["synced_at"])).total_seconds()
    except Exception:
        age = None
    return events, age


def events_for(cfg, events, day):
    lo, hi = day_window(cfg, day)
    return [e for e in events if e["start"] < hi and e["end"] > lo]


def blocks_in(cfg, events):
    """The plan proper: the timed blocks, with the approval marker and any all-day
    entry left out. Both of those are notes about the day rather than parts of it."""
    return [
        e for e in events
        if not e["all_day"] and not e["title"].startswith(cfg["approval_prefix"])
    ]


# ------------------------------------------------------------------------- gate

def override_file(cfg):
    return STATE_DIR / f"override-{plan_date(cfg)}"


def gate_state(cfg, events=None, age=None):
    """-> (open?, why). The why is what `dayplan gate` and the widget tooltip say.

    Every way of not knowing resolves to open. The gate exists to make the day
    get planned, and a gate that shuts because it cannot see the calendar does
    not do that -- it just takes the machine away. Each of those cases says so
    in its reason, which is what the bar and `dayplan gate` print.
    """
    if not cfg["gate_enabled"]:
        return True, "gate disabled"
    if override_file(cfg).exists():
        return True, "skipped for today"
    if backend(cfg) is None:
        # Nothing has been pointed at a calendar yet. A freshly switched
        # machine must not start closing windows with no way to plan: see
        # dayplan/setup.md.
        return True, "no calendar configured"
    if events is None:
        events, age = load_cache(cfg)
    for e in events_for(cfg, events, plan_date(cfg)):
        if e["title"].startswith(cfg["approval_prefix"]):
            return True, "plan approved"
    if age is None:
        return True, "calendar has never synced"
    if age > cfg["max_cache_age_minutes"] * 60:
        return True, f"calendar is {int(age // 60)}m stale -- not enforcing"
    return False, "no approved plan yet"


def niri_windows():
    try:
        out = subprocess.run(["niri", "msg", "-j", "windows"], capture_output=True, text=True, timeout=5)
        return json.loads(out.stdout) if out.returncode == 0 else []
    except Exception:
        return []


def is_blocked(cfg, win):
    """Whether this window should be closed while the gate is shut.

    Two kinds of rule, because a window names itself in two very different
    ways. An `app_id` is stable for as long as the thing runs -- Steam is
    `steam`, a game is `steam_app_<id>` -- so matching it is reliable. A title
    is whatever the program feels like saying this second, and for a browser it
    is only ever the *active tab*, which makes it both fleeting and the only
    handle there is on a tab.

    Title rules are scoped to the windows where a title means a site, which is
    what `title_scope_app_ids` is for. Without that scoping, `youtube` matches
    an editor holding a file with that in its path and a terminal running a
    command with that in its arguments -- and since enforcement is now instant
    rather than sampled every 20s, a false positive closes the editor the
    moment the file is opened.
    """
    app = win.get("app_id") or ""
    title = win.get("title") or ""
    if any(re.search(p, app, re.I) for p in cfg["blocked_app_ids"]):
        return True
    in_scope = any(re.search(p, app, re.I) for p in cfg["title_scope_app_ids"])
    return in_scope and any(re.search(p, title, re.I) for p in cfg["blocked_titles"])


def close_blocked(cfg, windows):
    """Close whichever of these are blocked. -> what got closed, by name."""
    closed = []
    for w in windows:
        if is_blocked(cfg, w):
            subprocess.run(
                ["niri", "msg", "action", "close-window", "--id", str(w["id"])],
                capture_output=True,
            )
            closed.append(w.get("title") or w.get("app_id"))
    if closed:
        announce_gate(cfg, closed)
    return closed


def announce_gate(cfg, closed):
    """Say something about a closure -- once a day loudly, then rate-limited.

    Nothing is said when nothing was closed. The bar already reads "Plan your
    day first" the whole time the gate is shut, which is the right weight for
    an ambient reading: a notification fired on the first tick after 4am would
    go off while he is asleep and be gone by the time he is up, and opening
    claude.ai then would put a planning chat in front of a man who has not
    woken yet. So the intrusive half happens at the moment he reaches for
    YouTube, which is the moment the point can actually land.
    """
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    opened = STATE_DIR / f"opened-{plan_date(cfg)}"
    first = not opened.exists()
    said = STATE_DIR / "gate-notified"
    quiet = said.exists() and time.time() - said.stat().st_mtime < cfg["gate_notify_cooldown_seconds"]
    if first or not quiet:
        notify(
            "Plan your day first",
            "Closed: " + ", ".join(closed[:3]) + "\n"
            + 'Say "plan my day" to Claude and approve it. That unlocks everything.',
            urgency="critical",
        )
        said.touch()
    if first:
        opened.touch()
        if cfg.get("planning_url"):
            subprocess.Popen(
                ["xdg-open", cfg["planning_url"]],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )


def enforce_gate(cfg, events, age):
    """The periodic sweep. gate_watch does the real work; this is the backstop.

    It catches what an event stream cannot: a window that was already open when
    the gate shut (approval expiring at 4am, or the first sync of the morning
    finding no plan), and anything missed while the stream was down.
    """
    if gate_state(cfg, events, age)[0]:
        return
    close_blocked(cfg, niri_windows())


def niri_events():
    """Yield parsed niri events, reconnecting across a niri restart.

    niri sends nothing while the layout is still, so this idles at no cost --
    the same reasoning as niri-fullscreen-watch.sh, which is the other reader
    of this stream in this tree.
    """
    while True:
        try:
            proc = subprocess.Popen(
                ["niri", "msg", "-j", "event-stream"],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
            )
        except Exception:
            time.sleep(5)
            continue
        try:
            for line in proc.stdout:
                try:
                    yield json.loads(line)
                except json.JSONDecodeError:
                    continue
        finally:
            proc.kill()
            proc.wait()
        # The stream ended: niri went away, or is restarting. Pick the next one
        # up rather than going quiet for the rest of the session.
        time.sleep(2)


def gate_watch(cfg):
    """Close a blocked window the moment it says what it is.

    This replaced a sweep on the 20s tick, which did not work for a browser and
    could not have. A tab's title is the only handle on it, and it is the
    window's title only while that tab is focused -- opening YouTube in a new
    tab of an existing window showed "YouTube - Chromium" for 2.6 seconds and
    then went back to whatever was there before. Sampling that every 20s caught
    it about one time in eight, which is not a gate, it is a dice roll.

    niri emits a window event on every title change, so the same navigation is
    now caught in milliseconds.
    """
    decided_at, closed_gate = 0.0, False

    for ev in niri_events():
        # WindowsChanged is the full list, sent on connect. WindowOpenedOrChanged
        # is one window, sent on open and on every title change after.
        if "WindowsChanged" in ev:
            windows = ev["WindowsChanged"].get("windows") or []
        elif "WindowOpenedOrChanged" in ev:
            window = ev["WindowOpenedOrChanged"].get("window")
            windows = [window] if window else []
        else:
            continue
        if not windows:
            continue

        # Typing in a browser's address bar changes the title on every
        # keystroke, so the gate decision is held briefly rather than re-read
        # from disk per event. Short enough that approving a plan still frees
        # the machine within the two minutes the sync loop takes anyway.
        if time.time() - decided_at > 5:
            events, age = load_cache(cfg)
            closed_gate = not gate_state(cfg, events, age)[0]
            decided_at = time.time()
        if closed_gate:
            close_blocked(cfg, windows)


# ---------------------------------------------------------------- notifications

def notify(summary, body="", urgency="normal"):
    subprocess.run(
        ["notify-send", "-a", "dayplan", "-u", urgency, summary, body],
        capture_output=True,
    )


def notify_block_starts(cfg, events):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    seen_file = STATE_DIR / f"notified-{plan_date(cfg)}.json"
    seen = set(json.loads(seen_file.read_text())) if seen_file.exists() else set()
    before = set(seen)
    t = now(cfg)
    lead = dt.timedelta(minutes=cfg["notify_minutes_before"])
    blocks = blocks_in(cfg, events_for(cfg, events, plan_date(cfg)))
    for i, e in enumerate(blocks):
        if e["uid"] in seen:
            continue
        if e["start"] - lead <= t < e["end"]:
            nxt = blocks[i + 1] if i + 1 < len(blocks) else None
            body = e["desc"].strip()
            body += f"\nUntil {fmt(cfg, e['end'])}" + (f" · then {nxt['title']}" if nxt else "")
            notify(f"▶ {e['title']}", body.strip(), urgency="critical")
            seen.add(e["uid"])
        elif e["end"] <= t:
            # Already over -- a block that ended while the laptop was asleep is
            # marked seen rather than announced late.
            seen.add(e["uid"])
    if seen != before:
        seen_file.write_text(json.dumps(sorted(seen)))


# ----------------------------------------------------------------------- output

def fmt(cfg, d):
    return d.astimezone(tz(cfg)).strftime("%-I:%M%p").lower().replace(":00", "")


def _left(minutes):
    return f"{minutes}m" if minutes < 60 else f"{minutes // 60}h{minutes % 60:02d}"


def bar_reading(cfg):
    """One reading of the day, as fields rather than as a string.

    Both halves of the noctalia widget stream this: the bar glyph uses the
    summary at the top, the panel behind it draws `blocks`. One command and one
    shape, so the line in the bar and the list under it can never disagree
    about which block is running.
    """
    events, age = load_cache(cfg)
    if age is None:
        # Two different problems with the same symptom, and the fix for each is
        # a different paragraph of setup.md, so the bar names which one it is.
        missing = "no calendar configured" if backend(cfg) is None else "calendar not synced"
        return {"state": "unsynced", "text": f"dayplan: {missing}", "glyph": "calendar-off", "blocks": []}

    t = now(cfg)
    day = plan_date(cfg)
    blocks = blocks_in(cfg, events_for(cfg, events, day))
    cur = next((e for e in blocks if e["start"] <= t < e["end"]), None)
    nxt = next((e for e in blocks if e["start"] > t), None)

    reading = {
        "date": f"{day:%A %b %-d}",
        "blocks": [
            {
                "title": e["title"],
                "desc": e["desc"].strip(),
                "start": fmt(cfg, e["start"]),
                "end": fmt(cfg, e["end"]),
                "when": "now" if e is cur else ("past" if e["end"] <= t else "later"),
            }
            for e in blocks
        ],
    }

    is_open, why = gate_state(cfg, events, age)
    if not is_open:
        return dict(reading, state="locked", text="Plan your day first", glyph="lock", tooltip=why)
    if cur:
        left = int((cur["end"] - t).total_seconds() // 60)
        return dict(
            reading,
            state="running",
            text=f"{cur['title']} · {_left(left)} left",
            glyph="player-play",
            block=cur["title"],
            left=left,
            next=nxt["title"] if nxt else None,
            tooltip=(cur["desc"].strip() or cur["title"]),
        )
    if nxt:
        return dict(
            reading,
            state="gap",
            text=f"Free until {fmt(cfg, nxt['start'])}",
            glyph="coffee",
            next=nxt["title"],
            tooltip=f"Next: {nxt['title']} at {fmt(cfg, nxt['start'])}",
        )
    return dict(reading, state="done", text="Day's plan done", glyph="check", tooltip=why)


def bar_line(cfg):
    r = bar_reading(cfg)
    mark = {"locked": "⚠", "running": "▶", "gap": "·", "done": "✓"}.get(r["state"], "")
    line = f"{mark} {r['text']}".strip()
    if r.get("next") and r["state"] == "running":
        line += f" → {r['next']}"
    return line


def print_today(cfg):
    events, age = load_cache(cfg)
    today = events_for(cfg, events, plan_date(cfg))
    is_open, why = gate_state(cfg, events, age)
    stamp = "never" if age is None else f"{int(age)}s ago"
    print(f"{plan_date(cfg):%A %b %-d} — gate {'open' if is_open else 'CLOSED'} ({why}); synced {stamp}")
    t = now(cfg)
    blocks = blocks_in(cfg, today)
    if not blocks:
        print("  (no blocks)")
    for e in blocks:
        mark = "▶" if e["start"] <= t < e["end"] else ("✓" if e["end"] <= t else " ")
        print(f" {mark} {fmt(cfg, e['start']):>7}–{fmt(cfg, e['end']):<7} {e['title']}")


def print_events(cfg, argv):
    """Today's and yesterday's plan as JSON. This is the read side of the planning
    skill: it asks what yesterday's blocks were before it asks which got done."""
    events, _ = load_cache(cfg)
    offset = 0
    for a in argv:
        if re.fullmatch(r"[-+]?\d+", a):
            offset = int(a)
    day = plan_date(cfg) + dt.timedelta(days=offset)
    out = [
        {
            "id": e["id"],
            "title": e["title"],
            "desc": e["desc"],
            "start": _iso(e["start"]),
            "end": _iso(e["end"]),
            "all_day": e["all_day"],
        }
        for e in events_for(cfg, events, day)
    ]
    print(json.dumps({"date": str(day), "events": out}, indent=2))


# ------------------------------------------------------------------ writing a plan

def apply_plan(cfg, argv):
    """Replace the rest of today on the Claude calendar with the blocks on stdin.

    Input is {"blocks": [{"title", "desc", "start", "end"}, ...], "approve": true}.
    Times are local ISO-8601, with or without an offset.

    The order is deliberate: clear, then write the blocks, then the approval
    marker last. The marker is what opens the gate, so it must never exist
    before the plan it vouches for.
    """
    if backend(cfg) != "api":
        print("apply needs the Calendar API backend; run `dayplan auth` first", file=sys.stderr)
        return 1
    source = Path(argv[2]).read_text() if len(argv) > 2 else sys.stdin.read()
    plan = json.loads(source)
    cal = urllib.parse.quote(cfg["calendar_id"])
    t = now(cfg)
    _, end_of_day = day_window(cfg, plan_date(cfg))

    def when(value):
        d = dt.datetime.fromisoformat(value)
        return d if d.tzinfo else d.replace(tzinfo=tz(cfg))

    # Everything from this moment on goes, including a marker from an earlier
    # approval: a re-plan at noon should leave the morning's finished blocks on
    # the calendar as the record of what was planned, and own the afternoon.
    stale = api("GET", f"/calendars/{cal}/events", params={
        "timeMin": t.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "timeMax": end_of_day.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "singleEvents": "true",
        "maxResults": "250",
    })
    removed = 0
    for item in stale.get("items", []):
        if item.get("status") == "cancelled":
            continue
        try:
            api("DELETE", f"/calendars/{cal}/events/{item['id']}")
            removed += 1
        except Exception as e:
            # One event that will not delete should not stop the rest of the
            # day being rewritten; the block loop below reports its own
            # failures and withholds the approval marker if there were any.
            print(f"could not delete {item.get('summary')!r}: {e}", file=sys.stderr)

    written, failed = 0, []
    zone = cfg.get("timezone") or str(tz(cfg))
    for b in plan.get("blocks", []):
        try:
            api("POST", f"/calendars/{cal}/events", body={
                "summary": b["title"],
                "description": b.get("desc", ""),
                "start": {"dateTime": when(b["start"]).isoformat(), "timeZone": zone},
                "end": {"dateTime": when(b["end"]).isoformat(), "timeZone": zone},
                # The phone's buzz at the start of each block. Google would
                # otherwise apply the calendar's own defaults, which are not these.
                "reminders": {"useDefault": False, "overrides": [{"method": "popup", "minutes": 0}]},
            })
            written += 1
        except Exception as e:
            failed.append(f"{b['title']}: {e}")

    # A half-written plan is not an approved one. Leaving the marker off keeps
    # the gate shut, which is the state that gets someone to look at this.
    approve = plan.get("approve", True) and not failed
    if approve:
        api("POST", f"/calendars/{cal}/events", body={
            "summary": cfg["approval_prefix"],
            "description": "dayplan's gate is open while this event is running.",
            "start": {"dateTime": t.replace(microsecond=0).isoformat(), "timeZone": zone},
            # 23:59 local, not the 4am boundary: the marker is a statement about
            # the calendar day, and Samsung's routine reads it as one.
            "end": {
                "dateTime": dt.datetime.combine(t.date(), dt.time(23, 59), tz(cfg)).isoformat(),
                "timeZone": zone,
            },
            "transparency": "transparent",
            "reminders": {"useDefault": False, "overrides": []},
        })

    ok, msg = sync(cfg)
    print(f"removed {removed}, wrote {written} blocks" + ("; approved" if approve else "; NOT approved"))
    if not ok:
        print(msg, file=sys.stderr)
    for line in failed:
        print("failed: " + line, file=sys.stderr)
    return 1 if failed else 0


# ----------------------------------------------------------------- long-running

def _supervise(name, fn, cfg):
    """Run fn forever in a thread, restarting it if it throws.

    A watcher that died silently would leave the gate looking enforced while it
    was not, which is the one failure mode worth spending a thread on noticing.
    """
    def loop():
        while True:
            try:
                fn(cfg)
            except Exception as e:
                print(f"{name} died ({e}); restarting", file=sys.stderr, flush=True)
            time.sleep(5)

    thread = threading.Thread(target=loop, name=name, daemon=True)
    thread.start()
    return thread


def daemon(cfg):
    # The gate reacts to niri's event stream rather than to this loop's tick --
    # see gate_watch for why a 20s sweep could never hold a browser. The loop
    # below still sweeps, as the backstop for windows that were already open
    # when the gate shut.
    _supervise("gate-watch", gate_watch, cfg)

    last_sync = 0.0
    while True:
        if time.time() - last_sync >= cfg["sync_seconds"]:
            ok, msg = sync(cfg)
            if not ok:
                print(msg, file=sys.stderr, flush=True)
            last_sync = time.time()
        events, age = load_cache(cfg)
        try:
            notify_block_starts(cfg, events)
            enforce_gate(cfg, events, age)
        except Exception as e:
            # Logged by systemd and then forgotten: a bad tick is not a reason
            # to leave the day unwatched.
            print(f"tick error: {e}", file=sys.stderr, flush=True)
        time.sleep(cfg["tick_seconds"])


def watch(cfg):
    """One JSON line per change, plus a keepalive, which is what the bar widget
    streams. The minutes-left in the reading means it changes once a minute on
    its own; the keepalive is so a widget can tell a quiet stream from a dead one."""
    last, last_at = None, 0.0
    while True:
        reading = bar_reading(cfg)
        line = json.dumps(reading)
        if line != last or time.time() - last_at > 50:
            print(line, flush=True)
            last, last_at = line, time.time()
        time.sleep(5)


# ------------------------------------------------------------------------- entry

def main(argv):
    cfg = load_config()
    cmd = argv[1] if len(argv) > 1 else "today"
    if cmd == "daemon":
        daemon(cfg)
    elif cmd == "watch":
        watch(cfg)
    elif cmd == "sync":
        ok, msg = sync(cfg)
        print(msg, file=sys.stderr if not ok else sys.stdout)
        return 0 if ok else 1
    elif cmd == "bar":
        print(bar_line(cfg))
    elif cmd == "today":
        print_today(cfg)
    elif cmd == "events":
        print_events(cfg, argv[2:])
    elif cmd == "gate":
        is_open, why = gate_state(cfg)
        print(("open" if is_open else "closed") + f": {why}")
        return 0 if is_open else 1
    elif cmd == "skip":
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        override_file(cfg).write_text(_iso(now(cfg)))
        with open(STATE_DIR / "skips.log", "a") as f:
            f.write(f"{_iso(now(cfg))} skipped planning\n")
        print(f"Gate open for {plan_date(cfg)}. Logged to {STATE_DIR / 'skips.log'}")
    elif cmd == "auth":
        return auth(cfg, argv[2:])
    elif cmd == "apply":
        return apply_plan(cfg, argv)
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except KeyboardInterrupt:
        sys.exit(130)
