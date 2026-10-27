import { test as base } from '@playwright/test';
import { BrowserContext } from 'playwright-core';
import { bootstrap, Dappwright, getWallet, MetaMaskWallet } from '@tenkeylabs/dappwright';

// Hardhat's own default mnemonic. Public, worthless, and the one every dapp
// test fixture on the internet already uses -- which is the point: the guest
// should never hold a seed worth stealing. See the wallet note at the top of
// modules/hosts/brain-vm/browser.nix.
// Account 0 of that mnemonic, which is what the wallet comes up showing.
export const HARDHAT_ACCOUNT_0 = '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266';

const SEED = 'test test test test test test test test test test test junk';

export const test = base.extend<{ wallet: Dappwright }, { walletContext: BrowserContext }>({
  walletContext: [
    async ({}, use) => {
      const [, , context] = await bootstrap('', {
        wallet: 'metamask',
        // The version the installed dAppwright's selectors were written
        // against, and the one brain-vm pre-seeds into dAppwright's cache so
        // this never reaches GitHub at runtime. Changing it here means a
        // download -- and selectors that may not match.
        version: MetaMaskWallet.recommendedVersion,
        seed: SEED,
        // Headful by default, because this guest has a real X server on :0
        // and wallet popups are better behaved there -- and `scrot` can see
        // what went wrong. WALLET_HEADLESS=1 switches to --headless=new,
        // which also works and is what CI-shaped runs should use.
        headless: process.env.WALLET_HEADLESS === '1',
      });

      await use(context);
      await context.close();
    },
    { scope: 'worker' },
  ],
  context: async ({ walletContext }, use) => {
    await use(walletContext);
  },
  wallet: async ({ walletContext }, use) => {
    await use(await getWallet('metamask', walletContext));
  },
});
