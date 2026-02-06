# crdt-db-game: P2P ARAM Simulation

ARAM-style 5v5 game simulation using EphemeralStore over WebSocket.

## Architecture

```
┌──────────┐  WS   ┌──────────────────┐  WS   ┌──────────┐
│ Player 0 │◄─────►│                  │◄─────►│ Player 5 │
│  30ms    │       │   GameRelay DO   │       │  80ms    │
├──────────┤       │                  │       ├──────────┤
│ Player 1 │◄─────►│  EphemeralStore  │◄─────►│ Player 6 │
│  30ms    │       │  (WASM merge)    │       │  80ms    │
├──────────┤       │                  │       ├──────────┤
│ Player 2 │◄─────►│  Broadcast diff  │◄─────►│ Player 7 │
│  30ms    │       │  to all peers    │       │ 200ms    │
├──────────┤       │                  │       ├──────────┤
│ Player 3 │◄─────►│                  │◄─────►│ Player 8 │
│  80ms    │       │                  │       │ 200ms    │
├──────────┤       │                  │       ├──────────┤
│ Player 4 │◄─────►│                  │◄─────►│ Player 9 │
│  80ms    │       └──────────────────┘       │ 200ms    │
└──────────┘                                  └──────────┘
  Team A (spawn x=0)                    Team B (spawn x=1000)
```

Each player:
1. Runs local ARAM game logic (movement, combat, respawn)
2. Sends own state to relay via WebSocket (with artificial latency)
3. Receives other players' state via broadcast (with artificial latency)
4. LWW merge resolves any conflicts

## Usage

```bash
# Terminal 1: Start relay server
pnpm install
pnpm dev

# Terminal 2: Run simulation
pnpm sim
```

## Game Rules

- 1D lane (0-1000), Team A spawns at x=0, Team B at x=1000
- Players move toward enemy base (70% forward, 20% stop, 10% backward)
- Attack range: 50 units, damage: 20/tick
- Death → respawn after 5 ticks at own base
- Neutral monsters spawn in center, give 25 gold on kill
- Player kill gives 50 gold to nearest enemy
