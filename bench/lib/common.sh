# shellcheck shell=bash
# Shared helpers. Source, do not execute.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DDP="$REPO_ROOT/.ddp"
COMPOSE="docker compose -f $DDP/docker-compose.yml -p wavebench"
CREDS="$REPO_ROOT/bench/creds"
BTC="docker exec wb-bitcoind bitcoin-cli -regtest -rpcuser=devuser -rpcpassword=devpass"

CLIENTS=""
for _i in $(seq -w 1 "${NUM_CLIENTS:-10}"); do CLIENTS="$CLIENTS wb-client$_i"; done
CLIENTS="${CLIENTS# }"

die() { echo "FATAL: $*" >&2; exit 1; }
log() { echo "[$(date -u +%H:%M:%S)] $*"; }

btc() { $BTC "$@"; }
lnd() { docker exec wb-lnd lncli --network regtest "$@"; }
lumoscli() { docker exec wb-lumosd lumoscli "$@"; }

# wavecli against one client container. Auth material lives in the client's
# own datadir, which wavecli finds by default.
wavecli() {
  local n=$1; shift
  docker exec "$n" wavecli --network=regtest "$@"
}

# Mine N blocks to the bitcoind miner wallet. The only source of blocks in
# the whole network: nothing mines unless the harness calls this.
mine() {
  local n=${1:-1}
  local addr; addr=$($BTC -rpcwallet=miner getnewaddress)
  $BTC generatetoaddress "$n" "$addr" >/dev/null
}

# Wait until electrs has indexed the current bitcoind tip, so lwwallet
# clients polling it can see what was just mined. Esplora lags bitcoind by
# its own indexing pass; acting before it catches up makes clients miss
# confirmations.
wait_electrs_synced() {
  local want got i
  want=$(btc getblockcount)
  for i in $(seq 1 60); do
    got=$(curl -s --max-time 5 localhost:13002/blocks/tip/height || echo -1)
    [[ "$got" == "$want" ]] && return 0
    sleep 1
  done
  log "WARNING: electrs stuck at height ${got:-?} (bitcoind at $want)"
  return 1
}

# Mine n blocks and wait for electrs to serve them.
mine_synced() { mine "${1:-1}"; wait_electrs_synced; }

# Poll a condition, mining one block between attempts. Rounds and boards
# need confirmations to progress, and on this network confirmations only
# happen when we produce them. Usage: mine_until <timeout_s> <cmd...>
mine_until() {
  local timeout=$1; shift
  local start; start=$(date +%s)
  while true; do
    "$@" && return 0
    (( $(date +%s) - start > timeout )) && return 1
    mine_synced 1
    sleep 2
  done
}

# Offchain (ark) confirmed balance of one client, in sat. Prints nothing on
# RPC failure so callers can record null rather than a fake zero (P5).
ark_balance() {
  local n=$1
  wavecli "$n" balance 2>/dev/null \
    | jq -r '.confirmed_sat // empty' 2>/dev/null
}

# Number of live vtxos a client holds. Empty on failure, never 0.
live_vtxos() {
  local n=$1
  wavecli "$n" ark vtxos list --status live 2>/dev/null \
    | jq -r 'if type=="array" then length else (.vtxos | length) end' 2>/dev/null
}

# Fail unless every container is running and every daemon answers.
health_check() {
  local n missing=""
  for n in wb-bitcoind wb-electrs wb-lnd wb-pg wb-lumosd $CLIENTS; do
    [[ "$(docker inspect -f '{{.State.Running}}' "$n" 2>/dev/null)" == "true" ]] \
      || missing="$missing $n"
  done
  [[ -z "$missing" ]] || die "containers not running:$missing"

  btc getblockcount >/dev/null || die "bitcoind unresponsive"
  docker exec wb-pg pg_isready -U lightning >/dev/null || die "postgres unresponsive"
  lnd getinfo >/dev/null || die "wb-lnd unresponsive"
  lumoscli info >/dev/null || die "wb-lumosd unresponsive"
  for n in $CLIENTS; do
    wavecli "$n" getinfo >/dev/null || die "$n unresponsive"
  done
}

# Top up the operator's lnd wallet. Rounds anchor their commitment
# transactions from this wallet, and several concurrent anchors need
# separate confirmed outputs, not one big one (P11).
ensure_operator_funded() {
  local floor=${1:-100000000} want_utxos=${2:-12}
  local bal have addr
  bal=$(lnd walletbalance | jq -r .confirmed_balance)
  if (( bal < floor )); then
    log "funding wb-lnd (balance $bal < $floor)"
    addr=$(lnd newaddress p2wkh | jq -r .address)
    $BTC -rpcwallet=miner sendtoaddress "$addr" 5 >/dev/null
    mine_synced 3
  fi
  have=$(lnd listunspent --min_confs=1 2>/dev/null | jq '.utxos | length')
  if (( ${have:-0} < want_utxos )); then
    log "splitting operator coins (${have:-0} < $want_utxos outputs)"
    local i
    for ((i = ${have:-0}; i < want_utxos; i++)); do
      addr=$(lnd newaddress p2wkh | jq -r .address)
      $BTC -rpcwallet=miner sendtoaddress "$addr" 1 >/dev/null
    done
    mine_synced 3
  fi
}
