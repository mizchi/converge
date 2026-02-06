# crdt-db-signaling: Star Relay + Gossip Topology

Signaling relay server with two topology modes using EphemeralStore over WebSocket.

## Architecture

### Star Mode
```
  Client A ──► Relay ──► Client B
  Client C ──► Relay ──► Client D
```
All messages go through the central relay. Relay merges and broadcasts diffs.

### Gossip Mode
```
  Client A ──► Relay ──► k random peers
                          │
                          ▼
                        Peer B merges ──► Relay (re-gossip) ──► k random peers
                                          │
                                          ▼ (seen → STOP)
```
Server forwards to fanout=k random peers. Receivers re-gossip.
`msgId` deduplication prevents infinite loops.

## Usage

```bash
pnpm install
pnpm dev

# Terminal 2:
pnpm sim:star    # Star mode simulation
pnpm sim:gossip  # Gossip mode simulation
```

## WebSocket Protocol

### Connection
```
/ws?room=main&mode=star&peer_id=p0&team=0&ns=state
```
- `mode`: `star` or `gossip` (first connection sets room mode)
- `ns`: comma-separated namespace list

### Messages

#### Client → Server
- `{ type: "state", entries: NsEntries }` — send own state
- `{ type: "gossip_relay", entries: NsEntries, msgId: string }` — re-gossip

#### Server → Client
- `{ type: "snapshot", mode: string, entries: NsEntries }` — initial state
- `{ type: "diff", entries: NsEntries }` — star mode diff
- `{ type: "gossip_diff", entries: NsEntries, msgId: string }` — gossip diff
- `{ type: "peer_joined", peer_id: string, team: number }`
- `{ type: "peer_left", peer_id: string }`
