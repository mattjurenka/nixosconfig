#!/usr/bin/env python3
"""Prove the browser stack works before blaming a dapp for anything.

Launches Chromium with the wallet extension loaded, resolves the extension's
runtime ID, opens the extension's own first page and screenshots it. A clean
run means browser, extension, MV3 service worker and screen are all fine.

  wallet-smoke                        # headful on :0, screenshot to /tmp
  wallet-smoke /mnt/outbox/wallet.png # somewhere Matt can see it
  WALLET_HEADLESS=1 wallet-smoke      # --headless=new, no X involved
  WALLET_EXTENSION=/path/to/dist wallet-smoke   # a different extension

Run through the `wallet-smoke` wrapper rather than directly: it is what
supplies WALLET_EXTENSION's default.
"""

import os
import sys

from playwright.sync_api import sync_playwright

extension = os.environ["WALLET_EXTENSION"]
profile = os.environ.get("WALLET_PROFILE", "/tmp/wallet-smoke-profile")
headless = os.environ.get("WALLET_HEADLESS") == "1"
shot = sys.argv[1] if len(sys.argv) > 1 else "/tmp/wallet-smoke.png"

# The first page an extension shows differs by wallet -- MetaMask's is
# home.html. Overridable so this script survives pointing at another one.
landing = os.environ.get("WALLET_LANDING", "home.html")

with sync_playwright() as p:
    # channel="chromium" is load-bearing, not a style choice. Playwright's
    # plain chromium in headless mode is chromium-headless-shell, which
    # cannot load extensions at all -- the browser starts, the script runs,
    # and the wallet is simply not there. The channel asks for the full
    # browser, which uses --headless=new and does support them.
    #
    # launch_persistent_context, not launch: extensions need a real profile
    # directory, and there is no --load-extension path through an incognito
    # context.
    context = p.chromium.launch_persistent_context(
        profile,
        channel="chromium",
        headless=headless,
        args=[
            f"--disable-extensions-except={extension}",
            f"--load-extension={extension}",
        ],
    )

    try:
        # The ID comes from the `key` injected into the manifest at build
        # time, not from the directory path -- see the dappwrightPubKey
        # comment in ./browser.nix. Reading it off the service worker anyway,
        # and checking it against what the environment claims, because the
        # two disagreeing is exactly the failure a dAppwright bump would
        # cause, and it is much cheaper to catch here than in a dapp test.
        workers = context.service_workers
        worker = workers[0] if workers else context.wait_for_event(
            "serviceworker", timeout=60_000
        )
        extension_id = worker.url.split("/")[2]
        print(f"extension id : {extension_id}")

        expected = os.environ.get("WALLET_EXTENSION_ID")
        if expected and extension_id != expected:
            print(f"MISMATCH     : expected {expected}")
            print("The manifest key and dAppwright's hardcoded ID have drifted.")
            sys.exit(1)

        page = context.new_page()
        page.goto(f"chrome-extension://{extension_id}/{landing}")
        page.wait_for_load_state("domcontentloaded")
        # The onboarding UI mounts after load; a fixed wait beats a selector
        # here, because the selector is the part that changes between wallet
        # versions and this script should not need updating with them.
        page.wait_for_timeout(5_000)
        page.screenshot(path=shot, full_page=True)

        print(f"title        : {page.title()}")
        print(f"screenshot   : {shot}")
    finally:
        context.close()
