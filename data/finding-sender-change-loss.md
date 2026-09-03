# Sender loses its own change output (upstream masters, 2026-09-03)

Seen on lumos master@efa4deb5 + wavelength main@e03e9d7c, v4 epoch 6.

client07 sent 31,201 sat to client10:

    OOR transfer submitted session_id=2ad8ea1c...9d26
      amount_sat=31201 input_total_sat=1318637 change_sat=1287436
      recipient_count=1 output_count=2

Both ends report the session terminal and healthy:

    client07: OOR_SESSION_STATUS_COMPLETED / OUTGOING
    client10: OOR_SESSION_STATUS_COMPLETED / INCOMING

The recipient was paid. The sender's CHANGE was not materialised locally:

    operator: 2ad8ea1c...9d26:1  value_sat 1287436  VTXO_STATUS_LIVE
              round_id "" (OOR-created)
    client07: outpoint absent from `ark vtxos list` in every status
              vtxo_sum == confirmed == 885,603 (books self-consistent,
              just 1,287,436 short of reality)

Stable across the following 12 epochs, so it is permanent, not lag. The
value is spendable only by client07's key, but its daemon does not know the
output exists; recovery would need a seed-restore indexer rescan.

Distinct from the v3 finding on the release tags, where the RECIPIENT lost
incoming value. Here the recipient side works (the upstream "postpone
over-cap incoming admissions" work covers that path) and the loss moved to
the sender's own change.

Detected by the capital-conservation gauge: invisible_sat stepped 0 ->
1,287,436 at epoch 6 and stayed flat. The operator-side identity
(deposited == live + in_flight + expired + fees) held exactly at 0
throughout, so no sats left the system: they are simply invisible to their
owner.

## v4 series result (60 epochs on masters, 2026-09-03)

Sender change loss recurred twice more in the clean run: invisible_sat
stepped to 36,706 around epoch 50 and 102,383 by epoch 60. Rare (3 events
in 1,800 payments) but permanent per event.

Still present, self-healing: the stale live-vtxo set. wb-client02 kept
selecting operator-SPENT vtxos as inputs, 47 rejected sends across epochs
7-9 and 37-49, then recovered on its own. On the release tags the same
condition was permanent and jammed the client for the rest of the run.
