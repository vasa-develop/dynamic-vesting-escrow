## dynamic-vesting-escrow

> A vesting escsrow for dynamic teams, based on Curve vesting escrow

### Features:

- Ability to claim a specific amount.
- Recipient specific startTime, endTime. Configurable flag to decide if startTime can be in past.
- Recipient specific cliff duration (min duration after start time to call claim).
- Recipient specific pause, unpause, terminate. "Pause" freezes the recipient's vesting state (claim blocked), and updates the recipient specific parameters on "UnPause" (claim unblocked) so that number of tokens vesting per second remains the same for complete lifecycle of the recipient.
- Ability to automatically transfer unvested tokens of the "Terminated" recipient to a "safe" address, and transfer all the vested tokens to the recipient.
- Global vesting escrow termination. Automatically transfers unvested tokens to a "safe" address. The recipient(s) is/are still entitled to the vested portion.
- Ability to add more recipients (no dilution) in the vesting escrow at any point in time (provided that escrow is not terminated).
