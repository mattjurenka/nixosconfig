# dayplan: the parts that can't be declared

Everything on the laptop comes from `modules/features/dayplan.nix`. Three
things don't: the calendar credential (which must not go in the store), the
phone, and the claude.ai half of the planning skill.

## 1. Point dayplan at the calendar

Pick one of two backends. dayplan uses whichever credential it finds.

### The quick one: the secret iCal address

Google Calendar on the web → the **Claude** calendar → Settings → *Integrate
calendar* → **Secret address in iCal format**.

```sh
install -m600 /dev/null ~/.config/dayplan/ical-url
printf '%s\n' 'https://calendar.google.com/calendar/ical/.../basic.ics' > ~/.config/dayplan/ical-url
dayplan sync && dayplan today
```

Thirty seconds of setup, and one real catch: Google serves that URL from a
cache it refreshes on its own schedule, which can be an hour or more behind the
calendar. An hour behind means an hour of staying locked out after approving a
plan. Watch for it on the first morning — `dayplan sync; dayplan gate` right
after approving — and if it lags, switch to the other backend.

### The one that doesn't lag: the Calendar API

This is what is set up. Events appear within seconds, and `dayplan apply` can
write a plan from Claude Code instead of from the browser.

Project **`dayplan-512206`** (number 911829084497), Desktop OAuth client
`911829084497-i9ol4v1q5asaqt5n7rslbuk1oog13k2c`, consented 2026-10-19. The
credential lives in `~/.config/dayplan/{oauth-client,oauth-token}.json`, both
0600, neither in the store.

To redo it, or to set it up on another machine:

```sh
dayplan auth --client-json ~/Downloads/client_secret_<id>.apps.googleusercontent.com.json
dayplan sync && dayplan today
```

Three things bit this on the way in, in order, and all three are console
settings rather than anything in the code:

1. **The client must be type "Desktop app".** A *Web* client cannot use a
   loopback redirect on an arbitrary port, which is how the consent comes back
   to the CLI, and Google reports that much later as `redirect_uri_mismatch`.
   `dayplan auth` checks the type up front and refuses.
2. **The consent screen's audience must match the account.** A project created
   while signed in as a Workspace account (`m@trystable.co`) defaults to
   *Internal*, and consenting as `matthewjurenka@gmail.com` then fails with
   `Error 403: org_internal`. Either flip *APIs & Services → OAuth consent
   screen → Audience* to External and add the account as a test user, or
   consent as the org account and share the Claude calendar with it.
3. **The Calendar API must be enabled in that project.** It is not enabled by
   creating a client, and the failure arrives *after* a successful consent, as
   a 403 `SERVICE_DISABLED` on the first call. Enable it at
   `console.cloud.google.com/apis/api/calendar-json.googleapis.com/overview?project=<number>`;
   no re-consent is needed afterwards.

While the consent screen stays in testing *with an External audience*, a test
user's refresh token is good for seven days at a time, so `dayplan auth` has to
be re-run weekly — the same tax `second-brain/host/google_consent.py` documents.
An Internal (Workspace-only) app is exempt. Publishing the consent screen ends
it either way.

## 2. Check it on this machine

```sh
systemctl --user restart dayplan
journalctl --user -u dayplan -f        # sync errors and tick errors land here
dayplan today                          # the plan, and whether the gate is open
dayplan gate                            # exit 0 open, 1 closed
dayplan bar                             # the line the widget renders
```

Three things the daemon depends on, all checked on omni-laptop as of
2026-10-19 and all working — re-run them on a host where the gate does nothing:

```sh
# niri's systemd session exports this into the user manager, which is what
# makes `niri msg` work inside the service. Empty means the gate can see no
# windows and will close nothing.
systemctl --user show-environment | grep NIRI_SOCKET

# notify-send needs only the session bus to reach noctalia's daemon.
systemctl --user show-environment | grep DBUS_SESSION_BUS_ADDRESS

# Do the blocked regexes match the real windows? Open Steam and a YouTube tab
# and look at what they actually call themselves.
niri msg windows
```

On this laptop a YouTube tab is `app_id: chromium-browser` with "… - YouTube -
Chromium" in the title, which the title rules catch, and a running game is
`steam_app_<appid>` (`steam_app_250900` for Isaac). Steam's own windows are
`app_id: steam`. A different browser or launcher needs its own line in
`my.dayplan.gate.blockedTitles`.

Nothing is enforced until a credential exists: with none, the gate reports
itself open as "no calendar configured" and closes nothing. Every other way of
not knowing — a cache that has never synced, one more than 45 minutes stale —
also resolves to open, and says which. A gate that shuts because it cannot see
the calendar doesn't get the day planned, it just takes the laptop away.

If the gate ever needs to be off for a day: `dayplan skip`. It writes to
`~/.local/state/dayplan/skips.log`, which is the point — the friction is that
the skips are counted, not that there is no way out.

### How fast the gate reacts

Enforcement runs off `niri msg -j event-stream`, not off the daemon's
20-second tick, and that distinction is the difference between a gate and a
dice roll.

A game is caught either way: `steam_app_<id>` is its `app_id` and sits there
until the game exits. A website is not. Opening YouTube in a new tab of an
existing Chromium window leaves the `app_id` as `chromium-browser` and makes
the *title* read `YouTube - Chromium` only while that tab is in front --
measured at **2.6 seconds** on this machine before the title reverted. A
20-second sweep caught that roughly one time in eight.

On the event stream the same navigation is closed in about **half a second**:
window appeared 23:14:21.48, closed 23:14:22.03. A non-blocked site in the same
browser is untouched, which is what `titleScopeAppIds` and the control test are
for.

## 3. The phone (Samsung, One UI)

Menu names move between One UI versions; this is the shape of it.

1. **Google Calendar app** → make sure the **Claude** calendar is ticked and
   syncing. Each block carries a popup reminder at 0 minutes, so it buzzes at
   the start on its own.
2. **Home screen** → add the Google Calendar **Schedule** widget. That is the
   phone's now/next view; there is no dayplan widget on the phone.
3. **Digital Wellbeing** → *Focus mode* → create one called **Plan first**,
   allowing only Phone, Messages, Calendar, Claude, ExpressVPN and whatever counts as
   essential. Everything else — YouTube, games, Reddit — stays blocked while
   it is on.
4. **Modes and Routines** → two routines:
   - **A**: *if* 4:00 AM → *then* turn on Focus mode "Plan first".
   - **B**: *if* a calendar event containing "Plan approved" is happening →
     *then* turn off Focus mode.

   Routine B is the one that might not exist: not every One UI version offers a
   calendar-event condition. Without it, end Focus mode by hand after
   approving — which is a tap, and the laptop gate still opens on its own.

## 4. The planning skill on claude.ai

`plan-my-day/SKILL.md` is installed for Claude Code on this machine by the
module. The phone plans through claude.ai, which has the Google Calendar
connector and its own skill list, so the same file has to be uploaded there:
Settings → Capabilities → Skills → upload
`modules/features/dayplan/plan-my-day/SKILL.md`.

Re-upload it when the file changes. There is no sync between the two.

## What this does not do

- Nothing tracks whether a block actually happened. Rollover works because the
  skill asks each morning.
- The gate opens for the whole day once approved. It does not enforce the
  individual blocks, and shouldn't — being locked out of a browser during a
  work block would mean being locked out of the work.
- Closing a Steam window leaves Steam in the tray, and closing a browser window
  takes its other tabs with it. Both are friction rather than a wall.
