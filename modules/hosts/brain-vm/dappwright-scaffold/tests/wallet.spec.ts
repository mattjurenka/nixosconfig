import { expect } from '@playwright/test';
import { HARDHAT_ACCOUNT_0, test } from './wallet-fixture';

// The smoke test, and it needs no dapp and no chain. Reaching this body at
// all means dAppwright drove MetaMask's onboarding to completion -- seed
// imported, password set, popups dismissed -- which is the part that breaks
// when a wallet version moves under the selectors. Locking and unlocking
// proves the wallet is still driveable afterwards.
//
// If this passes and your dapp test does not, the problem is the dapp.
test('the wallet onboards, locks and unlocks', async ({ wallet }) => {
  // The address MetaMask shows is truncated -- 0xf39Fd...92266 -- so this
  // matches the prefix that survives truncation rather than the whole thing.
  const shown = wallet.page.getByText(HARDHAT_ACCOUNT_0.slice(0, 7)).first();
  await expect(shown).toBeVisible();

  // Not wallet.countAccounts(): measured against MetaMask 13.50.0 on
  // 2026-10-17, it returns -1 rather than 1. dAppwright's selector for the
  // account list does not match this build's DOM, and an assertion on a
  // number that is always -1 is worse than no assertion.
  await wallet.lock();
  await wallet.unlock();

  await expect(wallet.page).toHaveTitle(/MetaMask/);
});
