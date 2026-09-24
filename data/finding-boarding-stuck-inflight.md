# A rejected boarding join leaves the deposit permanently unboardable

Found on 2026-09-24 bringing the v5 series up on lumos `master@99a05392`
and wavelength `main@9de8b092`.

## What happens

lumos requires `minboardingconfirmations` (default 6) before a boarding
UTXO may join a round. Submit the join earlier and the operator rejects
it:

```
RNDS: round(0857159a) Join request validation failed
  err="invalid boarding request for outpoint 999abd97...:1:
       insufficient confirmations: got 2, want 6"
```

That rejection is where it goes wrong. The client has already marked the
outpoint as in flight, and it never clears the marker. Every later
attempt is refused locally and no join is ever sent again:

```
ARKW: Board trigger redundant; all confirmed boarding outpoints already
  in flight confirmed_count=2 confirmed_balance=4000000
DRPD: Board request accepted boarding_balance="0.04000000 BTC"
  vtxo_amount="0 BTC" vtxo_count=0
```

The deposit is stuck for the life of the process. It stayed stuck at
1,100 confirmations, far past the 6 the operator wanted. `ark board`
keeps answering `{"status":"registered","vtxo_count":0}`, so a caller
watching the RPC result alone sees success while nothing happens.

Restarting the daemon clears it and the join is re-sent immediately.

## Why it bites harder than it looks

A deposit is only admissible inside a window, and the wait pushes it out
of the far end:

```
invalid boarding request for outpoint c85909d7...:0: boarding input
  delay path is too close: got 1111 confirmations, max safe 464
  (exit delay 512 - safety margin 48)
```

So a deposit that is stuck long enough stops being boardable at all, and
a restart no longer rescues it. On a chain with real block production the
user has roughly `exit delay - safety margin` blocks to notice, after
which the funds need the on-chain exit path instead.

## Reproduction

1. Send coins to a boarding address.
2. Mine 1 block, so the UTXO has fewer confirmations than
   `minboardingconfirmations`.
3. Call `ark board`. The operator rejects the join for depth.
4. Mine 100 more blocks and call `ark board` again, as often as you like.

Expected: the join is re-sent once the UTXO is deep enough.
Actual: "Board trigger redundant", no join is sent, balance stays 0.

## Suggested fix

Release the in-flight marker when the operator rejects the join, at
minimum for retryable reasons like insufficient confirmations. A
rejection for depth is a "not yet", not a "never", and the client
already knows the required depth: `getinfo` reports
`server_info.min_confirmations`, so it could also just hold the join back
until the UTXO qualifies rather than spending its one attempt early.

## Harness workaround

`bench/lib/cases.sh` now mines 8 blocks before calling `ark board`, and
if the balance still does not move it restarts the daemon and retries
once.
