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
  dayplan feeds     minutes of today's feeds used, on every device
  dayplan meditate  start today's meditation, in its full-screen window
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
import math
import os
import re
import secrets
import socket
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
    "blocked_titles": [r"youtube", r"twitch", r"reddit", r"netflix", r"showdown"],
    # Which windows a title rule is allowed to judge. A title only means a
    # website inside a browser; anywhere else "youtube" is as likely to be a
    # filename in an editor or an argument in a shell. `chrom` covers both
    # chromium-browser and the chrome-<hash>-Default windows a PWA gets.
    "title_scope_app_ids": [r"chrom", r"firefox", r"librewolf", r"brave", r"\bzen\b", r"epiphany"],
    # The 中文 launcher's YouTube window, which the learn-chinese extension holds
    # to Chinese. Open at any hour and not a feed.
    "study_app_ids": [r"^chrome-www\.youtube\.com__results-"],
    # What the day's allowance of feeds covers, here and on the phone together.
    "feed_titles": [r"youtube", r"twitch", r"reddit", r"\br/\w{2,21}\b", r"\bshowdown!"],
    # Pages a feed's name is in that aren't one: where videos are made rather
    # than watched. The gate's title rules, the allowance and drift leave them be.
    "not_feed_titles": [r"youtube studio", r"studio\.youtube\.com"],
    "feeds_limit_minutes": 60,
    # Below this, a page doesn't fit what it's held to (see drift_watch).
    "drift_enabled": True,
    "drift_cut": 0.2,
    # Windows it leaves alone. A terminal or code editor's title is a command or
    # a path rather than what's being done, and a terminal closes without asking
    # what's running in it. The last two are dialogs another app is waiting on.
    "drift_keep_app_ids": [
        r"kitty", r"^foot", r"alacritty", r"ghostty", r"wezterm", r"konsole", r"terminal",
        r"neovide", r"^code", r"^cursor$", r"^dev\.zed\.", r"jetbrains",
        r"xdg-desktop-portal", r"polkit",
    ],
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


# corkboard's node on this machine: where it listens is in the MCP config it
# writes for sessions, and that config's token reads plans.
NODE_DIR = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "corkboard/node"


def backend(cfg):
    if (NODE_DIR / "session-mcp.json").exists() and (NODE_DIR / "session-token").exists():
        return "node"
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
    try:
        got = _post_form(TOKEN_ENDPOINT, {
            "client_id": client["client_id"],
            "client_secret": client["client_secret"],
            "refresh_token": stored["refresh_token"],
            "grant_type": "refresh_token",
        })
    except urllib.error.HTTPError as e:
        # The token endpoint's body is {"error": "invalid_grant", ...}, not the
        # API's shape, and invalid_grant is the one that needs a person: the
        # refresh token is dead (revoked, or seven days old on a client whose
        # consent screen is still in Testing).
        try:
            err = json.loads(e.read().decode())
        except Exception:
            err = {}
        msg = f"token refresh: HTTP {e.code} {err.get('error', e.reason)}"
        if err.get("error_description"):
            msg += f": {err['error_description']}"
        if err.get("error") == "invalid_grant":
            msg += " -- run `dayplan auth`"
        raise ApiError(msg) from None
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


def node_assistant():
    """The node's default brain, by the name the dropdown's button gives it
    ("Plan with Pepper"); None when there's no node or it can't be asked."""
    try:
        mcp = json.loads((NODE_DIR / "session-mcp.json").read_text())
        url = urllib.parse.urlsplit(mcp["mcpServers"]["corkboard-memory"]["url"])
        token = (NODE_DIR / "session-token").read_text().strip()
        req = urllib.request.Request(
            f"{url.scheme}://{url.netloc}/api/node/status",
            headers={"Authorization": f"Bearer {token}"},
        )
        with urllib.request.urlopen(req, timeout=10) as r:
            name = json.loads(r.read().decode()).get("default_brain")
    except Exception:
        return None
    return name[:1].upper() + name[1:] if name else None


def fetch_node(cfg):
    """The day plans corkboard's node keeps (accepted on the phone or in the
    plan window), as the calendar's events would be: each block, and an
    approval marker from when the day was accepted to its end."""
    mcp = json.loads((NODE_DIR / "session-mcp.json").read_text())
    url = urllib.parse.urlsplit(mcp["mcpServers"]["corkboard-memory"]["url"])
    token = (NODE_DIR / "session-token").read_text().strip()
    out = []
    today = plan_date(cfg)
    for n in range(-3, 5):
        day = today + dt.timedelta(days=n)
        req = urllib.request.Request(
            f"{url.scheme}://{url.netloc}/api/node/plans/{day.isoformat()}",
            headers={"Authorization": f"Bearer {token}"},
        )
        with urllib.request.urlopen(req, timeout=10) as r:
            plan = json.loads(r.read().decode())
        if not plan.get("accepted"):
            continue
        midnight = dt.datetime.combine(day, dt.time(0), tz(cfg))
        for b in plan.get("day", {}).get("blocks", []):
            out.append({
                "uid": f"{day}/{b['id']}",
                "id": b["id"],
                "title": b.get("title", "(untitled)"),
                "desc": b.get("desc", ""),
                "kind": b.get("kind"),
                "start": midnight + dt.timedelta(minutes=b["start"]),
                "end": midnight + dt.timedelta(minutes=b["stop"]),
                "all_day": False,
            })
        accepted = dt.datetime.fromisoformat(plan["accepted"].replace("Z", "+00:00")).astimezone(tz(cfg))
        out.append({
            "uid": f"{day}/accepted",
            "id": "accepted",
            "title": cfg["approval_prefix"],
            "desc": "",
            "start": accepted,
            "end": day_window(cfg, day)[1],
            "all_day": False,
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
        events = {"node": fetch_node, "api": fetch_api, "ical": fetch_ical}[which](cfg)
        if which == "node":
            fetch_meditation(cfg)
    except Exception as e:
        return False, f"sync failed ({which}): {e}"
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    payload = {
        "synced_at": _iso(now(cfg)),
        "backend": which,
        "assistant": node_assistant() if which == "node" else None,
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
            # As on the phone, the plan and then the meditation. One the node
            # can't be asked about doesn't hold the gate.
            med = load_meditation(cfg) if backend(cfg) == "node" else None
            if med is None or med["elapsed"] >= med["goal"]:
                return True, "plan approved"
            return False, f"meditated {med['elapsed'] // 60} of {med['goal'] // 60}m"
    if age is None:
        return True, "calendar has never synced"
    if age > cfg["max_cache_age_minutes"] * 60:
        return True, f"calendar is {int(age // 60)}m stale -- not enforcing"
    return False, "no approved plan yet"


def planned_unmeditated(cfg, events=None, age=None):
    """Whether the plan is in and only the meditation holds the gate."""
    is_open, why = gate_state(cfg, events, age)
    return not is_open and why.startswith("meditated ")


# ------------------------------------------------------------------- meditation
#
# The phone's morning meditation, kept by corkboard's node (day.ts's
# meditation:<date>) so the laptop times the same one. While it runs, from
# whichever device, the laptop is in meditation mode: a full-screen window
# with the timer in it, and the moment another window takes the focus the
# meditation pauses -- on the phone too, as it does there when another app
# comes to the front. Getting on the laptop halfway through is getting off
# the meditation.

MEDITATION_APP_ID = "dayplan-meditate"


def node_call(method, path, owner=False, timeout=10):
    """corkboard's node on this machine. The sessions' token reads; a start or
    pause is the user's own (owner-token), as on the phone."""
    mcp = json.loads((NODE_DIR / "session-mcp.json").read_text())
    url = urllib.parse.urlsplit(mcp["mcpServers"]["corkboard-memory"]["url"])
    token = (NODE_DIR / ("owner-token" if owner else "session-token")).read_text().strip()
    req = urllib.request.Request(
        f"{url.scheme}://{url.netloc}/api/node/{path}",
        method=method,
        data=b"" if method == "POST" else None,
        headers={"Authorization": f"Bearer {token}"},
    )
    return urllib.request.urlopen(req, timeout=timeout)


def meditation_file():
    return CACHE_DIR / "meditation.json"


def _keep_meditation(m):
    m["read_at"] = time.time()
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = meditation_file().with_suffix(".tmp")
    tmp.write_text(json.dumps(m))
    tmp.replace(meditation_file())
    return m


def fetch_meditation(cfg):
    with node_call("GET", f"meditation/{plan_date(cfg).isoformat()}") as r:
        return _keep_meditation(json.loads(r.read().decode()))


def meditate(cfg, change):
    """Start or pause today's meditation, for every device."""
    with node_call("POST", f"meditation/{plan_date(cfg).isoformat()}/{change}", owner=True) as r:
        return _keep_meditation(json.loads(r.read().decode()))


def load_meditation(cfg):
    """Today's meditation as last read, timed on to now; None if it's not
    today's or is too old to go by."""
    try:
        m = json.loads(meditation_file().read_text())
    except Exception:
        return None
    if m.get("date") != plan_date(cfg).isoformat() or time.time() - m.get("read_at", 0) > cfg["max_cache_age_minutes"] * 60:
        return None
    if m.get("since"):
        started = dt.datetime.fromisoformat(m["since"].replace("Z", "+00:00")).timestamp()
        m["elapsed"] = min(m["goal"], m["banked"] + max(0, int(time.time() - started)))
        m["running"] = m["elapsed"] < m["goal"]
    return m


def meditation_window():
    return next((w for w in niri_windows() if w.get("app_id") == MEDITATION_APP_ID), None)


def open_meditation(cfg, start=False):
    """The meditation's window, focused, opened if it isn't; with start, the
    meditation started too."""
    if start:
        meditate(cfg, "start")
    w = meditation_window()
    if w:
        subprocess.run(["niri", "msg", "action", "focus-window", "--id", str(w["id"])], capture_output=True)
        return
    subprocess.Popen(
        [cfg.get("terminal", "kitty"), "--class", MEDITATION_APP_ID, "--title", "meditate", sys.executable, sys.argv[0], "meditation-screen"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
    )


def meditation_watch(cfg):
    """Each change to the day object, from the node: a meditation started on
    the phone brings its window up here within a second."""
    while True:
        try:
            running = fetch_meditation(cfg)["running"]
            if running:
                open_meditation(cfg)
            with node_call("GET", "day/events", timeout=90) as r:
                for line in r:
                    if not line.startswith(b"data:"):
                        continue
                    m = fetch_meditation(cfg)
                    if m["running"] and not running:
                        open_meditation(cfg)
                    running = m["running"]
        except Exception as e:
            print(f"meditation watch: {e}", file=sys.stderr, flush=True)
        time.sleep(5)


def left_meditation(cfg, focused_app):
    """Another window took the focus, or the meditation's own closed: off it."""
    if focused_app == MEDITATION_APP_ID:
        return
    m = load_meditation(cfg)
    if not m or not m["running"]:
        return
    try:
        m = meditate(cfg, "pause")
    except Exception as e:
        print(f"meditation pause: {e}", file=sys.stderr, flush=True)
        return
    notify("Meditation paused", f"{m['elapsed'] // 60} of {m['goal'] // 60}m")


def meditation_screen(cfg):
    """The window's inside: the time left, and space to start or pause."""
    import curses

    # Full screen as it opens, while it's the focused window.
    subprocess.run(["niri", "msg", "action", "fullscreen-window"], capture_output=True)

    def draw(scr):
        curses.curs_set(0)
        curses.use_default_colors()
        scr.timeout(250)
        m, read_at, said_done = load_meditation(cfg), 0.0, False
        while True:
            if time.time() - read_at > 3:
                try:
                    fetch_meditation(cfg)
                except Exception:
                    pass
                read_at = time.time()
            m = load_meditation(cfg) or m or {"elapsed": 0, "goal": 1800, "running": False}
            done = m["elapsed"] >= m["goal"]
            if done and not said_done:
                notify("Meditation done", "")
                said_done = True
            left = m["goal"] - m["elapsed"]
            width = 40
            filled = width * m["elapsed"] // m["goal"]
            lines = [
                "meditate",
                "",
                "done" if done else f"{left // 60:02d}:{left % 60:02d}",
                "",
                "█" * filled + "░" * (width - filled),
                "",
                "q" if done else ("space  pause" if m["running"] else "space  start"),
            ]
            scr.erase()
            h, w = scr.getmaxyx()
            for i, text in enumerate(lines):
                y, x = h // 2 - len(lines) // 2 + i, max(0, (w - len(text)) // 2)
                if 0 <= y < h:
                    scr.addnstr(y, x, text, max(0, w - x - 1), curses.A_BOLD if i == 2 else curses.A_NORMAL)
            scr.refresh()
            key = scr.getch()
            if key in (ord("q"), 27):
                return
            if key == ord(" ") and not done:
                try:
                    meditate(cfg, "pause" if m["running"] else "start")
                except Exception:
                    pass

    curses.wrapper(draw)


def niri_windows():
    try:
        out = subprocess.run(["niri", "msg", "-j", "windows"], capture_output=True, text=True, timeout=5)
        return json.loads(out.stdout) if out.returncode == 0 else []
    except Exception:
        return []


def is_blocked(cfg, win):
    """The rule this window is closed under while the gate is shut, or None.

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
        return app
    if is_study(cfg, win):
        return None
    if not any(re.search(p, app, re.I) for p in cfg["title_scope_app_ids"]):
        return None
    if is_work_page(cfg, title) or not_feed(cfg, title):
        return None
    return next((p for p in cfg["blocked_titles"] if re.search(p, title, re.I)), None)


def close_window(win):
    subprocess.run(
        ["niri", "msg", "action", "close-window", "--id", str(win["id"])],
        capture_output=True,
    )


def close_blocked(cfg, windows):
    """Close whichever of these are blocked. -> the rules that closed them,
    never the windows' titles: a title is the name of what was being watched,
    and this goes into a notification."""
    closed = []
    for w in windows:
        rule = is_blocked(cfg, w)
        if rule:
            close_window(w)
            closed.append(rule)
            if rule != (w.get("app_id") or ""):
                offer_work(cfg, w.get("title") or "", "Not work")
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
    said = STATE_DIR / "gate-notified"
    quiet = said.exists() and time.time() - said.stat().st_mtime < cfg["gate_notify_cooldown_seconds"]
    if planned_unmeditated(cfg):
        # Planned already: what's left is the meditation, so it's that window
        # that comes up, already running.
        if not quiet:
            notify("Meditate first", "Closed: " + ", ".join(closed[:3]), urgency="critical")
            said.touch()
        open_meditation(cfg, start=True)
        return
    opened = STATE_DIR / f"opened-{plan_date(cfg)}"
    first = not opened.exists()
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
        plan = cfg.get("planning_command") or (cfg.get("planning_url") and ["xdg-open", cfg["planning_url"]])
        if plan:
            subprocess.Popen(
                plan,
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
    decided_at, closed_gate, spent = 0.0, False, False
    # Each window's app_id, for what a focus change lands on.
    apps = {}

    for ev in niri_events():
        if "WindowsChanged" in ev:
            apps = {w["id"]: w.get("app_id") or "" for w in ev["WindowsChanged"].get("windows") or []}
        elif "WindowOpenedOrChanged" in ev and ev["WindowOpenedOrChanged"].get("window"):
            w = ev["WindowOpenedOrChanged"]["window"]
            apps[w["id"]] = w.get("app_id") or ""
        if "WindowFocusChanged" in ev:
            # Nothing focused is the screen locked or off, which is no use of it.
            focused = ev["WindowFocusChanged"].get("id")
            if focused is not None:
                left_meditation(cfg, apps.get(focused, ""))
            continue
        if "WindowClosed" in ev:
            if apps.pop(ev["WindowClosed"].get("id"), None) == MEDITATION_APP_ID:
                left_meditation(cfg, "")
            continue
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
            spent = feeds_left(cfg, load_feeds(cfg)) <= 0
            decided_at = time.time()
        if closed_gate:
            close_blocked(cfg, windows)
        elif spent:
            close_feeds(cfg, windows)


# ------------------------------------------------------------------------ drift
#
# A browser page that doesn't fit what the day says is happening closes, judged
# by a small embedding model on this machine: while the gate's shut against
# "not entertainment", and through each planned block not marked off against
# that block. "This is work" on the notification lets that page back in for the
# day, and is learned from: pages like it stay open from then on. Pages and
# verdicts stay in this process's memory: a title is the name of what was being
# watched, so it goes to the local model and no further, not to a file, the
# journal or a notification. What's learned is kept as the model's numbers for
# the page marked, without its title.

DRIFT_TICK_SECONDS = 5
DRIFT_GATE = "Work, planning the day, or useful life admin. Not entertainment or leisure."
DRIFT_QUERY = "Represent this sentence for searching relevant passages: "
DRIFT_LEISURE = [
    "video game", "funny or entertainment video", "social media feed", "movie or TV streaming",
    "online shopping", "celebrity gossip", "sports news", "memes", "dating",
    "gameplay and game guides", "anime and TV shows", "reddit humor and pictures",
    "film trailers and reactions", "fan communities", "gambling and fantasy sports", "pop culture trivia",
]
DRIFT_WORK = [
    "software development", "writing a document", "technical documentation", "email and office admin",
    "banking and bills", "calendar and planning", "studying a technical subject",
    "programming tutorial or conference talk", "code repository or pull request", "spreadsheets and budgets",
    "learning a skill", "comparing products or vendors for a project", "government, health or household errands",
    "professional networking, careers and job search", "computer hardware and engineering articles",
    "industry news and analysis", "research papers and science",
]
# A logistic fit over similarity to the block, the leisure list and the work list.
DRIFT_MEAN, DRIFT_SD = [0.51634, 0.53443, 0.51412], [0.13794, 0.06344, 0.05573]
DRIFT_WEIGHTS, DRIFT_BIAS = [1.2683, -2.0454, 1.0802], -0.5442
# A browser's own name after the page's, and what a window says with no page.
BROWSER_SUFFIX = re.compile(r"\s+[-—–]\s+(mozilla firefox|firefox|chromium|google chrome|brave|zen browser|librewolf|web)( private browsing)?$", re.I)
NO_PAGE = re.compile(r"^$|^(new tab|new private tab|private browsing|loading|untitled|about:\S*|mozilla firefox|chromium|google chrome|google|duckduckgo|bing|inbox( \(\d+\))?)$", re.I)

# How alike a page and one marked as work have to be for it to stay, and how
# many of those are kept, the newest.
DRIFT_LEARNED_NEAR = 0.75
DRIFT_LEARNED_KEEP = 400

_work_pages = {}
_offered = {}
_learned = None
# The focused window that doesn't fit but runs on the day's allowance, which
# feeds_watch counts. Its id and nothing about it.
_on_allowance = None


def page_of(title):
    """A title without the browser's name or a count of what's unread, so a
    page marked as work is still that page when a notification comes in."""
    return re.sub(r"^\(\d+\+?\)\s*", "", BROWSER_SUFFIX.sub("", title).strip())


def is_work_page(cfg, title):
    return _work_pages.get(page_of(title)) == plan_date(cfg).isoformat()


def learned_file():
    return STATE_DIR / "drift-learned.json"


def load_learned():
    global _learned
    if _learned is None:
        try:
            _learned = json.loads(learned_file().read_text())
        except Exception:
            _learned = []
    return _learned


def learn_work(v):
    """Keep a page marked as work, unless one all but the same is kept already."""
    global _learned
    kept = load_learned()
    if any(_cosine(v, k) > 0.97 for k in kept):
        return
    _learned = (kept + [[round(x, 5) for x in v]])[-DRIFT_LEARNED_KEEP:]
    tmp = learned_file().with_suffix(".tmp")
    _write_private(tmp, json.dumps(_learned))
    tmp.replace(learned_file())


def is_learned(v):
    return any(_cosine(v, k) >= DRIFT_LEARNED_NEAR for k in load_learned())


def offer_work(cfg, title, why, v=None):
    """A notification for what was just closed, whose "This is work" lets the
    page back in until the day turns over and, given the page's embedding, has
    ones like it stay from then on. It waits on its own thread."""
    page, at = page_of(title), time.time()
    if at - _offered.get(page, 0) < 60:
        return
    _offered[page] = at

    def ask():
        try:
            out = subprocess.run(
                ["notify-send", "-a", "dayplan", "-u", "critical", "-A", "work=This is work", "--wait", "Closed", why],
                capture_output=True, text=True, timeout=1800,
            )
        except subprocess.TimeoutExpired:
            return
        if out.stdout.strip() == "work":
            _work_pages[page] = plan_date(cfg).isoformat()
            if v:
                learn_work(v)

    threading.Thread(target=ask, daemon=True).start()


class Embedder:
    """llama-server on loopback, started on first use and again if it dies. Its
    logging is off and its output dropped, since what it's given are titles."""

    def __init__(self, model):
        self.model, self.proc, self.port, self.seen = model, None, None, {}

    def start(self):
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            self.port = s.getsockname()[1]
        self.proc = subprocess.Popen(
            ["llama-server", "-m", self.model, "--host", "127.0.0.1", "--port", str(self.port),
             "-t", "2", "-c", "512", "-b", "512", "--no-webui", "--log-disable", "--embedding"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        for _ in range(120):
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/health", timeout=2) as r:
                    if r.status == 200:
                        return
            except Exception:
                time.sleep(0.5)
        raise RuntimeError("llama-server did not start")

    def __call__(self, text):
        if text not in self.seen:
            if self.proc is None or self.proc.poll() is not None:
                self.start()
            if len(self.seen) > 2000:
                self.seen.clear()
            req = urllib.request.Request(
                f"http://127.0.0.1:{self.port}/v1/embeddings", json.dumps({"input": text}).encode(),
                {"content-type": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=30) as r:
                self.seen[text] = json.load(r)["data"][0]["embedding"]
        return self.seen[text]


def _cosine(a, b):
    return sum(x * y for x, y in zip(a, b)) / (math.sqrt(sum(x * x for x in a)) * math.sqrt(sum(x * x for x in b)))


def drift_fit(embed, page, target):
    """-> how likely, 0 to 1, this page belongs to what it's held to."""
    v = embed(page)
    near = lambda anchors: sum(sorted((_cosine(v, embed(DRIFT_QUERY + a)) for a in anchors), reverse=True)[:3]) / 3
    x = [_cosine(v, embed(DRIFT_QUERY + target)), near(DRIFT_LEISURE), near(DRIFT_WORK)]
    z = sum(w * (n - m) / s for w, n, m, s in zip(DRIFT_WEIGHTS, x, DRIFT_MEAN, DRIFT_SD)) + DRIFT_BIAS
    return 1 / (1 + math.exp(-z))


def held_to(cfg, events, age):
    """What a page has to fit right now, or None through a play block: a work
    or fixed block over anything else, then an off block, and with nothing on,
    what the gate holds to. As with the gate, not knowing the plan holds nothing."""
    is_open, why = gate_state(cfg, events, age)
    if not is_open:
        return DRIFT_GATE
    if why != "plan approved" or age is None or age > cfg["max_cache_age_minutes"] * 60:
        return None
    t = now(cfg)
    on = [b for b in blocks_in(cfg, events) if b["start"] <= t < b["end"]]
    busy = next((b for b in on if b.get("kind") not in ("off", "play")), None)
    if busy:
        return busy["title"]
    if any(b.get("kind") == "play" for b in on):
        return None
    return on[0]["title"] if on else DRIFT_GATE


def allowance_open(cfg, events, age):
    """With the morning done, anything runs through blocks on the day's allowance."""
    return gate_state(cfg, events, age)[0] and feeds_left(cfg, load_feeds(cfg)) > 0


def feed_allowed(cfg, events, age, win):
    return is_feed(cfg, win) and allowance_open(cfg, events, age)


def drift_watch(cfg):
    """Close the focused window once its title has settled and doesn't fit.

    Sampled, and only a title that held across two ticks: a page says "Loading"
    and its previous name on the way in, and a close here costs the window.
    Only the focused window, since a reference left on the other monitor isn't
    what's being done. Marking one as work lets the page back in, in a browser,
    and elsewhere the whole app, whose title changes as it's used, and keeps
    ones like it open after (learn_work). While the
    day's allowance lasts one that doesn't fit stays, and spends it.
    """
    global _on_allowance
    embed, last = Embedder(os.environ["DAYPLAN_EMBED_MODEL"]), None
    while True:
        time.sleep(DRIFT_TICK_SECONDS)
        _on_allowance = None
        events, age = load_cache(cfg)
        target = held_to(cfg, events, age)
        w = next((w for w in niri_windows() if w.get("is_focused")), None)
        if target is None or w is None:
            last = None
            continue
        app, title = w.get("app_id") or "", w.get("title") or ""
        if any(re.search(p, app, re.I) for p in cfg["blocked_app_ids"]):
            if allowance_open(cfg, events, age):
                _on_allowance = w["id"]
            else:
                close_window(w)
            continue
        if feed_allowed(cfg, events, age, w):
            last = None
            continue
        page = page_of(title)
        work = title if any(re.search(p, app, re.I) for p in cfg["title_scope_app_ids"]) else app
        if any(re.search(p, app, re.I) for p in cfg["drift_keep_app_ids"]) or is_study(cfg, w) or NO_PAGE.match(page) or (
            work == title and not_feed(cfg, title)
        ):
            last = None
            continue
        was, last = last, (w["id"], title)
        if was != last or is_work_page(cfg, work):
            continue
        try:
            fit, v = drift_fit(embed, page, target), embed(page)
        except Exception as e:
            # Its type alone: the message of a failed request could carry the text.
            print(f"drift: {type(e).__name__}", file=sys.stderr, flush=True)
            continue
        if fit < cfg["drift_cut"] and not is_learned(v):
            if allowance_open(cfg, events, age):
                _on_allowance = w["id"]
                continue
            close_window(w)
            last = None
            offer_work(cfg, work, "Not work" if target == DRIFT_GATE else f"Not {target}", v)


# ------------------------------------------------------------------------ feeds
#
# An allowance of feeds a day, this laptop's and the phone's together, after
# which they close until the day turns over. Nothing here is undone by
# `dayplan skip`, which is the morning gate's; a page marked "This is work" as
# it closes is no feed for the day, and spends nothing.
#
# What's kept is seconds and nothing else. A window's title is the name of the
# video, so it's matched here and goes no further: not to a file, the journal,
# a notification or the node.

FEEDS_TICK_SECONDS = 5
FEEDS_SYNC_SECONDS = 60
FEEDS_WARN_SECONDS = 10 * 60
FEEDS_STALE_SECONDS = 30


def feeds_file():
    return STATE_DIR / "feeds.json"


def is_study(cfg, win):
    return any(re.search(p, win.get("app_id") or "", re.I) for p in cfg["study_app_ids"])


def not_feed(cfg, title):
    return any(re.search(p, title, re.I) for p in cfg["not_feed_titles"])


def is_feed(cfg, win):
    app = win.get("app_id") or ""
    title = win.get("title") or ""
    return not is_study(cfg, win) and not is_work_page(cfg, title) and not not_feed(cfg, title) and any(
        re.search(p, app, re.I) for p in cfg["title_scope_app_ids"]
    ) and any(re.search(p, title, re.I) for p in cfg["feed_titles"])


def load_feeds(cfg):
    """Today's seconds, each device's; a new day's start at nothing."""
    day = plan_date(cfg).isoformat()
    try:
        f = json.loads(feeds_file().read_text())
    except Exception:
        f = {}
    return f if f.get("date") == day else {"date": day, "laptop": 0, "phone": 0, "warned": False}


def save_feeds(f):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = feeds_file().with_suffix(".tmp")
    tmp.write_text(json.dumps(f))
    tmp.replace(feeds_file())


def feeds_left(cfg, f):
    return cfg["feeds_limit_minutes"] * 60 - f["laptop"] - f["phone"]


def allowance_reading(cfg):
    """Whether this laptop is spending the allowance now, and the minutes left.

    Counting writes the file every tick, so an old one saying so is a daemon
    that's gone.
    """
    f = load_feeds(cfg)
    counting = bool(f.get("counting")) and time.time() - feeds_file().stat().st_mtime < FEEDS_STALE_SECONDS
    return {"counting": counting, "left": _left((max(0, feeds_left(cfg, f)) + 59) // 60)}


def close_feeds(cfg, windows):
    closed = [w for w in windows if is_feed(cfg, w)]
    for w in closed:
        close_window(w)
        # That one page, for the day: it isn't learned from, since one video's
        # title is much like any other's.
        offer_work(cfg, w.get("title") or "", "Feeds used up")
    if not closed:
        return
    # A window that ignores the close comes round again on every event.
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    said = STATE_DIR / "feeds-notified"
    if not said.exists() or time.time() - said.stat().st_mtime >= cfg["gate_notify_cooldown_seconds"]:
        notify("Feeds used up", "Back tomorrow", urgency="critical")
        said.touch()


def sync_feeds(cfg, f):
    """Give the node this laptop's count and take the phone's. Unreachable, the
    count goes on here and catches up later."""
    try:
        with node_call("POST", f"feeds/{f['date']}/laptop?seconds={f['laptop']}", owner=True) as r:
            seen = json.loads(r.read().decode())
    except Exception as e:
        print(f"feeds sync: {e}", file=sys.stderr, flush=True)
        return f
    return {**f, "laptop": max(f["laptop"], seen["laptop"]), "phone": max(f["phone"], seen["phone"])}


def feeds_watch(cfg):
    """Count the seconds a feed is up, in any window, while the screen's in use,
    and those of a focused window drift_watch let run on the allowance.

    Any window rather than the focused one, since a video on the other monitor
    is still being watched. Sampled rather than event-driven: a count can be a
    few seconds out, which closing a window can't.
    """
    last, synced, carry = time.time(), 0.0, 0.0
    while True:
        time.sleep(FEEDS_TICK_SECONDS)
        t = time.time()
        # Capped, so a suspend isn't counted as watching.
        gap, last = min(t - last, FEEDS_TICK_SECONDS * 3), t
        f = before = load_feeds(cfg)
        windows = niri_windows()
        counting = any(w.get("is_focused") for w in windows) and any(is_feed(cfg, w) or w["id"] == _on_allowance for w in windows)
        if counting:
            carry += gap
            f = {**f, "laptop": f["laptop"] + int(carry)}
            carry -= int(carry)
        f = {**f, "counting": counting}
        if backend(cfg) == "node" and t - synced >= FEEDS_SYNC_SECONDS:
            synced = t
            f = sync_feeds(cfg, f)
        left = feeds_left(cfg, f)
        if 0 < left <= FEEDS_WARN_SECONDS and not f.get("warned"):
            f = {**f, "warned": True}
            notify("Feeds", f"{left // 60}m left today")
        if f != before:
            save_feeds(f)
        if left <= 0:
            close_feeds(cfg, windows)


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
    try:
        assistant = json.loads(cache_file().read_text()).get("assistant") or "Claude"
    except Exception:
        assistant = "Claude"
    if age is None:
        # Two different problems with the same symptom, and the fix for each is
        # a different paragraph of setup.md, so the bar names which one it is.
        missing = "no calendar configured" if backend(cfg) is None else "calendar not synced"
        return {"state": "unsynced", "text": f"dayplan: {missing}", "glyph": "calendar-off", "blocks": [], "assistant": assistant}

    t = now(cfg)
    day = plan_date(cfg)
    blocks = blocks_in(cfg, events_for(cfg, events, day))
    cur = next((e for e in blocks if e["start"] <= t < e["end"]), None)
    nxt = next((e for e in blocks if e["start"] > t), None)

    reading = {
        "date": f"{day:%A %b %-d}",
        "assistant": assistant,
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
    med = load_meditation(cfg) if backend(cfg) == "node" else None
    if med and med["running"]:
        left = (med["goal"] - med["elapsed"] + 59) // 60
        return dict(reading, state="meditating", text=f"Meditating · {left}m left", glyph="yoga", tooltip=why)
    if not is_open and med and planned_unmeditated(cfg, events, age):
        return dict(reading, state="locked", text=f"Meditate first · {med['elapsed'] // 60}/{med['goal'] // 60}m", glyph="lock", tooltip=why)
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
    if age > cfg["max_cache_age_minutes"] * 60:
        # Nothing left that it knows of isn't the day done: it can't see the day.
        return dict(reading, state="unsynced", text="dayplan: plan not synced", glyph="calendar-off", tooltip=why)
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
    _supervise("feeds-watch", feeds_watch, cfg)
    if cfg["drift_enabled"] and os.environ.get("DAYPLAN_EMBED_MODEL"):
        _supervise("drift-watch", drift_watch, cfg)
    if backend(cfg) == "node":
        _supervise("meditation-watch", meditation_watch, cfg)

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
        reading = dict(bar_reading(cfg), allowance=allowance_reading(cfg))
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
    elif cmd == "feeds":
        f = load_feeds(cfg)
        print(f"{(f['laptop'] + f['phone']) // 60} of {cfg['feeds_limit_minutes']}m")
    elif cmd == "meditate":
        open_meditation(cfg, start=True)
    elif cmd == "meditation-screen":
        meditation_screen(cfg)
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
