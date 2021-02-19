## dynamic-vesting-escrow

> A vesting escrow for dynamic teams, based on [Curve vesting escrow](https://github.com/curvefi/curve-dao-contracts)

### Features:

- Ability to claim a specific amount.
- Recipient specific `startTime`, `endTime`. Configurable flag `ALLOW_PAST_START_TIME` to decide if `startTime` can be in past.
- Recipient specific cliff duration (min duration after start time to call claim).
- Recipient specific pause, unpause, terminate. `Paused` freezes the recipient's vesting state (recipient can claim vested tokens), and updates the recipient specific parameters when `UnPaused` so that number of tokens vesting per second (can be unique for each recipient) remains the same for complete lifecycle of the recipient.
- No limit on recipient pause duration. Any recipient can be paused, unpaused as many times as the owner wishes.
- Ability to automatically transfer unvested tokens of the `Terminated` recipient to a "safe" address, and transfer all the vested tokens to the recipient.
- Global vesting escrow termination. Ability to transfer (seize) unvested tokens to a "safe" address. The recipient(s) is/are still entitled to the vested portion.
- Ability to add more recipients (no dilution) in the vesting escrow at any point in time (provided that escrow is not terminated).

### Known Issue

This is a minor issue, which **does NOT effect the security of the contract in a significant way**.

Due to rounding error, `totalLockedOf` returns a value different (slightly off) from the expected value. But the return values of `totalLockedOf` are capped so that at the end of the vesting period, the recipient can claim exactly the `totalVestingAmount` assigned to it.

This rounding error also effects functions which use `totalLockedOf`:

- `claimableAmountFor`
- `batchTotalLockedOf`
- `seizeLockedTokens`

**This contract may have more issues, so test it yourself before using it in production.**
