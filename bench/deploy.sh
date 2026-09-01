#!/usr/bin/env bash
# Bring the persistent wavebench network up and bootstrap it if fresh.
# Idempotent: safe against a running network and after a host reboot.
# Never wipes state unless --reset is passed.
#
# Usage: bench/deploy.sh [--reset]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a; . "$HERE/config.env"; set +a
. "$HERE/lib/common.sh"

RESET=0
[[ "${1:-}" == "--reset" ]] && RESET=1

if (( RESET )); then
  echo "WARNING: destroying all network state (volumes, epoch history stays)"
  read -r -p "type 'reset' to confirm: " ans
  [[ "$ans" == "reset" ]] || die "aborted"
  $COMPOSE down -v
fi

# The auto-unlock password file every client mounts read-only.
mkdir -p "$CREDS"
printf '%s' "$WALLET_PASSWORD" > "$CREDS/wallet.pass"

log "starting bitcoind, postgres"
$COMPOSE up -d wb-bitcoind wb-pg

# A fresh postgres volume runs initdb, accepts connections briefly, then
# restarts into normal operation: a single successful pg_isready during
# that window is a lie that failed this script twice. Require two
# consecutive successes with a gap spanning the restart.
pg_up=0
for _ in $(seq 1 60); do
  if docker exec wb-pg pg_isready -U lightning >/dev/null 2>&1; then
    sleep 2
    docker exec wb-pg pg_isready -U lightning >/dev/null 2>&1 \
      && { pg_up=1; break; }
  fi
  sleep 2
done
(( pg_up )) || die "postgres never came up"

# pg_stat_statements is preloaded via server flags but the view has to be
# created once. Attributing an operation to the statements it waits on
# depends on this.
docker exec wb-pg psql -U lightning -d lumos -q -c \
  "CREATE EXTENSION IF NOT EXISTS pg_stat_statements" >/dev/null 2>&1 || \
  log "warning: could not create pg_stat_statements"

for _ in $(seq 1 60); do btc getblockchaininfo >/dev/null 2>&1 && break; sleep 1; done
btc getblockchaininfo >/dev/null || die "bitcoind never came up"

# A recreated bitcoind container starts with no wallet loaded even though
# the wallet file persists in the volume, so load before creating.
btc listwallets | jq -e 'index("miner")' >/dev/null 2>&1 \
  || btc loadwallet miner >/dev/null 2>&1 \
  || { log "creating miner wallet"; btc createwallet miner >/dev/null; }

# Coinbase outputs need 100 confirmations before they are spendable.
height=$(btc getblockcount)
if (( height < 101 )); then
  log "mining $((101 - height)) blocks to maturity"
  mine $((101 - height))
fi

# lnd reports synced_to_chain false when the tip is old, and lumosd waits on
# lnd. Nothing advances this chain except the harness, so refresh the tip
# after any long gap.
tip_age=$(( $(date +%s) - $(btc getblockchaininfo | jq -r .mediantime) ))
if (( tip_age > 1800 )); then
  log "chain tip is $((tip_age / 60))m old, refreshing"
  mine 1
fi

log "starting electrs, lnd"
$COMPOSE up -d wb-electrs wb-lnd
for _ in $(seq 1 90); do lnd getinfo >/dev/null 2>&1 && break; sleep 2; done
lnd getinfo >/dev/null || die "wb-lnd never came up"
wait_electrs_synced || die "electrs never synced"

ensure_operator_funded

log "starting lumosd"
$COMPOSE up -d wb-lumosd
for _ in $(seq 1 90); do lumoscli info >/dev/null 2>&1 && break; sleep 2; done
lumoscli info >/dev/null || die "wb-lumosd never came up"

log "starting clients"
$COMPOSE up -d
for n in $CLIENTS; do
  for _ in $(seq 1 90); do
    docker exec "$n" wavecli --network=regtest getinfo >/dev/null 2>&1 && break
    sleep 2
  done
done

# First boot: wallets that do not exist yet have to be created once. A
# created wallet auto-unlocks from the mounted password file on every later
# start. getinfo answers even with no wallet, so the wallet_state field is
# the actual signal.
wallet_state() { wavecli "$1" getinfo 2>/dev/null | jq -r '.wallet_state // empty'; }

for n in $CLIENTS; do
  if [[ "$(wallet_state "$n")" == "WALLET_STATE_NONE" ]]; then
    log "creating wallet on $n"
    docker exec "$n" wavecli --network=regtest create \
      --wallet-password-file /creds/wallet.pass \
      --print-mnemonic-json > "$CREDS/$n.mnemonic.json" 2>&1 \
      || die "wallet create failed on $n"
    for _ in $(seq 1 30); do
      [[ "$(wallet_state "$n")" == *READY* ]] && break; sleep 2
    done
    [[ "$(wallet_state "$n")" == *READY* ]] || die "$n wallet never became ready"
  fi
done

health_check

echo
echo "network ready"
echo "  operator  grpc localhost:17070  admin localhost:18085  pprof localhost:16060"
echo "  clients   rpc localhost:200NN   pprof localhost:161NN  (NN = 01..$(printf '%02d' "$NUM_CLIENTS"))"
echo "  block height $(btc getblockcount)"
