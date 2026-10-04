# Stronghold-Protocol — Wire Protocol Map for a Native Swift Client

All paths relative to `/run/airbuild/team/state/team/developer/stronghold-src`. Everything is JSON text frames over one WebSocket; every frame is `{ t: "<type>", ...payload }`. Normative catalogue: `shared/protocol.js` (C2S validators at `shared/protocol.js:244`, S2C type list at `:308`).

---

## 1. Connection lifecycle

### 1.1 Endpoint (server)

- HTTP + WS on one port (default 3000, env `PORT`/`HOST`). Static files at `/`, game data at `/data/`, shared JS at `/shared/`, sim JS at `/sim/`.
- **WebSocket path: `/ws`** — anything else is rejected with HTTP 404 at upgrade (`server/index.js:736-741`). No query params are used.
- Per-message-deflate is **off** (`perMessageDeflate: false`, `server/index.js:729`); max inbound frame **64 KB** (`WS_MAX_PAYLOAD`, `server/index.js:40`). Binary frames get `error BAD_MSG "binary frame"` (`server/net.js:526`).
- Admission at upgrade: `maxConnections` (2000) → 503, per-network `maxConnectionsPerAddr` (64) → 429 (`server/index.js:742-746`, `server/net.js:434-442`).
- `GET /healthz` → `{ ok, version: PROTOCOL_VERSION, app: APP_VERSION, uptimeSec, build, sockets, sessions, rooms, matches, humans, bots }` (`server/index.js:660-671`).
- ws↔wss: the browser derives it from the page scheme (`public/js/net.js:defaultWsUrl`, ~line 122: `ws(s)://<host>/ws`; `wss` when page is https). A native client should use `wss` for TLS deployments, `ws` for LAN.

### 1.2 Server close codes (`server/net.js:58`)

| code | meaning |
|---|---|
| 4001 | session replaced (same token connected elsewhere) — **do not auto-reconnect** |
| 4002 | hello timeout (socket never sent `hello` within `helloTimeoutMs` = 30 s) |
| 1008 | flooding (rate-limit drops > 400/s) |
| 1001 | server shutdown |

### 1.3 Client behavior (`public/js/net.js`)

- One socket, JSON frames. Auto-reconnect with backoff (base 500 ms, ×2, max 10 s, ±20 % jitter) (`BACKOFF`, `public/js/net.js:12`).
- Heartbeat: `ping { t:'ping', c:<epochMs> }` every 4 s; connection considered dead if **no inbound frame at all** for 15 s (`PING_INTERVAL_MS`/`DEAD_AFTER_MS`, `public/js/net.js:13-14`).
- `hello` is sent whenever the player name is known: on open, and again when the name changes (a repeat hello on a live socket renames + resyncs). Client hello timeout 8 s (`HELLO_TIMEOUT_MS`).
- Requests made while (re)connecting are queued and flushed after `welcome`.

### 1.4 hello / welcome / error / pong / ok

**C2S `hello`** (`shared/protocol.js:246`):
```
{ t:'hello', rid?:int(0..2^31), name:string(≤12, trimmed nonempty),
  token?:string(≤64),      // optional — reconnect token
  version?:int }           // optional — must equal PROTOCOL_VERSION (1) when present
```
Server processing (`server/net.js:onHelloMsg`, ~line 575):
- `version != null && version !== PROTOCOL_VERSION(1)` → `error BAD_MSG detail:"version mismatch: server 1"` (no session created).
- `name` is sanitized (NFC, control chars stripped, capped at `NAME_MAX_LEN` 12 code points, `server/net.js:sanitizeName`); empty → `error BAD_MSG "bad field name"`.
- **Token handling**: if `token` resolves to a live session → resume it (`resumed:true`), old socket closed 4001. If it doesn't resolve → **silently creates a fresh session** (a bad/expired token is not an error). No token → new session.
- New session ids: `playerId = 'p_' + 5 random bytes hex` (10 hex chars); **token = 128-bit hex (32 chars)** (`server/net.js:newToken`, `create`).

**S2C `welcome`** (`server/net.js:600`):
```
{ t:'welcome', playerId:string, token:string, name:string,
  serverNow:number,            // server epoch ms
  version:number,              // PROTOCOL_VERSION (1)
  resumed:boolean, rid? }      // rid echoed if the hello had a valid rid
```

**S2C `error`** (`server/net.js:errorMsg`, ~line 398):
```
{ t:'error', code:string(ERR code), msg:string,   // msg = human (Chinese) ERR_TEXT
  rid?:int,            // echoed when the request had a valid rid
  detail?:string }     // ≤120 chars developer reason (present on most errors)
```

**S2C `pong`** (answer to `ping`, `server/net.js:507`): `{ t:'pong', c:number, s:number, rid? }` — `c` echoes the client's clock value, `s` = server epoch ms (client derives clock offset: `s + rtt/2 − now`, best (lowest-RTT) of last 8 samples wins; `welcome.serverNow` / first `m.public.serverNow` bootstrap it — `public/js/net.js:_onPong/_addClockSample`).

**S2C `ok`**: `{ t:'ok', rid }` — sent for any validated request with a valid `rid` whose handler didn't return an error (`server/net.js:557`).

Rate limiting: 40 msg/s token bucket (burst 40); excess answered `error RATE` (rid best-effort peeked from ≤2 KB frames) and >400 drops in 1 s closes 1008. A second bucket (2/s, burst 6) covers heavy intents `g.watch` and `room.loadout` (`server/net.js:40-41`, `HEAVY_TYPES :69`).

---

## 2. Request/response correlation (`rid`)

- Every C2S message may carry `rid: int 0..2^31` (`validateC2S`, `shared/protocol.js:332`). Optional everywhere; `b.progress`/`b.result` are commonly sent **without** `rid` (fire-and-forget; see below).
- Client (`public/js/net.js:_nextRid/request`, ~line 400): monotonically increasing `rid` (wraps at 2,147,483,000); pending map keyed by `rid`; the request **resolves with the first reply frame carrying that rid** (`ok`, or any push that happens to echo the rid — only `ok`/`error` do), rejects `NetError` on `error` or after 8 s (`REQUEST_TIMEOUT_MS`).
- Server: after a handler returns, if the handler returned no error and `rid` was valid → `{ t:'ok', rid }`; on error → `error` with echoed `rid` (`server/net.js:542-558`). A rid-less `b.progress` that reaches no running match is **never answered** (avoids a stale toast) (`server/net.js:552-556`).
- **Error codes** `shared/constants.js:115-139` (`ERR`), display text `ERR_TEXT :141`:
  `BAD_MSG, RATE, NOT_IN_ROOM, ROOM_NOT_FOUND, ROOM_FULL, ROOM_STARTED, NOT_HOST, NOT_READY, WRONG_PHASE, NO_FUNDS, HAND_FULL, BOARD_FULL, BAD_TILE, BAD_TARGET, SOLD_OUT, MAX_LEVEL, NOT_YOUR_TURN, ALREADY, TEMP_NOT_EMPTY, ELIMINATED, INTERNAL, APPLICATION_EXPIRED` (the last is Workers-account rooms only).

---

## 3. Lobby / room flow

### 3.1 room.* intents (C2S, `shared/protocol.js:248-262`)

| intent | fields | notes |
|---|---|---|
| `room.create` | `mode:'solo'|'coop'`, `difficulty: 'FUNNY'|'NORMAL'|'HARD'|'ABYSS'` | creating while in a lobby room implicitly leaves it |
| `room.join` | `code:string(≤6, [A-Za-z0-9])` | 4-char room code, uppercased server-side |
| `room.spectate` | — | **only handled by the Workers account rooms** (`worker/`); the plain server answers `BAD_MSG "unhandled type"` (`server/lobby.js:265-267`) |
| `room.leave` | — | |
| `room.ready` | `ready:boolean` | lobby ready toggle |
| `room.setDifficulty` | `difficulty` | host only; resets others' ready |
| `room.addBot` / `room.removeBot` | / `seat:int 0..3` | host only, coop only, bots ready=true |
| `room.start` | — | host only; every other human must be connected AND ready |
| `room.loadout` | `entries: { [chessId]: { skill?:int 0..9, module?:string|'none' } }` (≤160) | validated against game data (`checkLoadout`, `shared/protocol.js:130`); accepted while in room and (during a match) only in INFO_CHECK |

Handlers: `server/lobby.js:309-477`. Errors: `room.join` → `ROOM_NOT_FOUND`, `ROOM_FULL` (also "solo room"), `ROOM_STARTED`; `room.*` host ops → `NOT_HOST`; start with unready players → `NOT_READY`.

### 3.2 `room.state` push (`server/lobby.js:Room.toState`, 145-160)

```
{ t:'room.state', code:string(4), hostId:string|null, mode:'solo'|'coop',
  difficulty:string, inMatch:boolean,
  seats: (Seat|null)[4] }        // array always length 4, null = empty seat
Seat = { seat:int, playerId:string, name:string, isBot:boolean,
         ready:boolean, connected:boolean }   // connected already folds in !left
```
Note `room.state` has **no rid** and no `loadout` field. It is broadcast to the room on every visible change, or sent to one requester (join same room, plain resync).

### 3.3 `room.closed` push

`{ t:'room.closed', reason:string }`. Reasons: `'timeout'` (removed after lobby grace / reconnect window), `'shutdown'`, `'empty'` — but `'empty'` is only used internally (room emptied by departures; the last member leaving doesn't get a frame) (`server/lobby.js:50, 297-301, 544-547, 804-822`).

### 3.4 Reconnect tokens — semantics

- Issued in `welcome.token` at first hello; stored server-side in a `Session` keyed by `playerId` and `token` (`server/net.js:Session/SessionRegistry`, 90-185).
- Client persistence (`public/js/net.js` identity block, ~line 640+): token in `sessionStorage` (survives reload) + last 4 tokens in `localStorage` (`sp.name`, `sp.token`, `sp.tokens`); a duplicated tab drops the copied token (BroadcastChannel liveness check) so it becomes a new player. For Swift: store the token in the Keychain/UserDefaults and resend it in every `hello`; the server resumes the session (same playerId, room seat, match state) as long as it hasn't expired.
- Reconnect windows: default 10 min; **a session in a running solo match gets 24 h** (data `singleReconnectTime`, fallback 86400 s; `server/lobby.js:81, 713-719`, set at every disconnect `server/lobby.js:273`). Expired sessions are swept; the next hello with that token creates a **new** session (new playerId!) — the client must handle `welcome.playerId` changing.
- On resume (`onHello` with `resumed`, `server/lobby.js:216-250`): server sends `room.state` (or broadcasts if connectivity/name/host visibly changed), then the full match resync (`Match.onReconnect`, `server/match/Match.js:443-462`): fresh `m.public`, fresh `m.private`, then either re-sent `b.start` (client combat) or the watched `m.field`+`b.snap`, or, if the match already ended, the `m.result` frame. A pending `room.closed` notice and/or result frames buffered while away are delivered here (`session.notice`/`session.pendingResult`).
- Repeated hello on a *live* socket = rename + resync, throttled to ≥1 s apart (`resyncMinGapMs`).

### 3.5 Room→match transition

`room.start` → `room.state{inMatch:true}` broadcast → `Match.start()` → phase `INFO_CHECK` (`server/lobby.js:479-526`, `server/match/Match.js:370-388`). Seats carried into the match: `{ seat, playerId, name, isBot, connected, loadout }`.

---

## 4. Match phase state machine & message shapes

### 4.1 Phases — `shared/constants.js:20-34` (`PHASE`, exact enum strings)

```
LOBBY, INFO_CHECK, BAND_DRAFT, BATTLE_CHECK, ROUND_START, SP_DRAFT,
PREP, COMBAT, UNITE, SETTLE, FINAL_ASSAULT, HIDDEN_CORE, RESULT
```
(Chinese labels in `PHASE_NAMES :36`.) Flow: `INFO_CHECK (g.infoReady) → BAND_DRAFT (g.band/g.bandSkip/g.bandFocus, turn-based) → BATTLE_CHECK → [loop: ROUND_START → SP_DRAFT (on sp rounds, g.choice) → PREP (shop/board, g.ready / auto after deadline) → COMBAT (normal fields) → UNITE (if anyone leaked) → SETTLE] → FINAL_ASSAULT (round 14 boss) → optional HIDDEN_CORE (round 15) → RESULT`. Solo skips SP_DRAFT shuffling/skips (`isSolo` checks `server/match/Match.js:239,1172-1173,1318`).

### 4.2 `m.public` (broadcast to all, throttled ≤1/10 s, `server/match/Match.js:792-868`)

```
{ t:'m.public',
  phase:string, round:int, lastRound:int, deadline:number|null,   // epoch ms, 0/absent when untimed
  serverNow:number, modeId:string, difficulty:string, stageId:string,
  factions:string[], disabledBonds:string[], drawnDisabledBonds:string[], bannedChess:string[],
  bossId:string|null, hiddenBossId:string|null, bossRound:int, hiddenRound:int,
  spRound:boolean,                  // this round is an SP_DRAFT round
  combatMode:'client'|'server',     // 'client' = browsers simulate (b.start specs)
  paused:boolean,                   // solo pause
  players: Player[], fields: FieldView[],
  teamLp?:int,                      // Final Assault shared LP (present when bossPool exists)
  overtimeAt?:number,               // FINAL_ASSAULT/HIDDEN_CORE overtime drain start (epoch ms)
  bossHp?: { hp:int, max:int },
  draft?: { order:string[], turn:string, picks:{[pid]:bandId}, skipsLeft:{[pid]:int},
            turnDeadline:number, turnSeconds:number, untimed:boolean },        // BAND_DRAFT only
  sp?: { family,name,desc,eventId, cards:CardView[], order:string[], turn:string,
         picks:{[pid]:int}, taken:{[cardIdx]:pid}, untimed:boolean },          // SP_DRAFT only
  unite?: { helpers:string[], leakers:string[] } }                             // UNITE only

Player = { playerId, seat:int, name, isBot, connected, alive,
           lp:int, bandId:string|null, shopLevel:int, boardCount:int,
           ready:boolean, bonds:BondEntry[],          // [] once eliminated
           fieldId:string|null, status:string,        // left|dead|ready|deciding|acting|combat|done|helping
           autoplay:boolean,
           pendingLp?:int,                            // LP this round's own battle will cost so far (omitted when 0)
           pendingLeft?:{[pid]:int} }                 // (unite, same condition — see _pendingLpView)

FieldView = { fieldId:string, kind:'normal'|'unite'|'boss'|'hidden',
              players:string[], live:boolean, progress?: { gt:number, killed:int, total:int } }

BondEntry = { bondId:string, count:int, active:boolean, tier:int, layers:int, harmony?:int }
             // m.public variant omits thresholds/countsHand (server/match/bondsMeta.js:157-172)
```
`statusOf` logic: `server/match/Match.js:765-785`. Field ids: own normal field = `"n:"+playerId`, unite = `"u"`, boss fields = their own ids.

### 4.3 `m.private` (per player, only on change, `server/match/PlayerState.js:1608-1652`)

```
{ t:'m.private', playerId, seat:int, alive:boolean, lp:int, funds:int,
  bandId:string|null, ready:boolean,
  canReady:boolean,               // alive && temp empty && phase PREP
  shop: { level:int, maxLevel:int, upgradePrice:int, refreshPrice:int,
          freeRefreshes:int, frozen:boolean,
          slots: (ShopSlot|null)[],           // shop slots
          rewardOffer?: { tier, source:'merge'|'special', label:string|null,
                          queued:int, slots:[{kind:'chess'|'item', id, price, sold}] } | null },
  hand: (Piece|null)[], temp: (Piece|null)[], board: Piece[],
  deployCap:int, deployCount:int,
  bonds: BondEntryFull[],         // + thresholds:number[], countsHand:boolean
  effects: [{ id, name, desc, iconKind, iconId, counter?:int }],
  nextEnemies: Preview[],         // coming enemies of own board
  loadout: { [chessId]: { skill:int, module:string|null } } | null,
  stats: { dmgDealt:int, kills:int, leaks:int, gold:int, refreshes:int, merges:int } }

Piece  = { uid:int, kind:'chess'|'item'|'token', id:string, golden:boolean, tier:int|null,
           items:[{uid:int,id:string}] (chess only), count:int (token), ownerUid:int|null (token),
           row?:int, col?:int, dir?:'UP'|'RIGHT'|'DOWN'|'LEFT' }   // row/col/dir only on board entries
ShopSlot = { kind:'chess'|'item', id:string, price:int, basePrice:int, sold:boolean, frozen:boolean }
Preview = { enemyKey:string, count:int, gate:'upper'|'lower', t:number,
            fly:boolean, elite:boolean, boss:boolean, source:'wave'|'bounty', tag:string|null }
```
(`server/match/waves.js:564-585` for `previewOf`.)

### 4.4 `m.field` (answer to `g.watch` / prep scouting / server-combat watch, `server/match/Match.js:884-921`)

Two shapes:
- **Live battle field** (`battle.fieldMeta()`, `server/sim/Battle.js:2340-2347`): `{ t:'m.field', fieldId, kind, rect:{r0,r1,c0,c1}, stageId, units:UnitInfo[] }` plus `live:boolean` added by the match. Followed immediately by one `b.snap`.
- **Prep scouting** (`fieldId = "n:<playerId>"`): same plus `prep:true`, `nextEnemies:Preview[]`; `units` are UnitInfo of the scouted board with `skillIndex`/`moduleId`/`items` included.

`UnitInfo` (sim `unitInfo`, fields per `prepFieldMeta` at `Match.js:893-906`): `{ id:int, uid:int, kind:'op'|'token'|'enemy', side:'ally'|'enemy', ownerId:string, defId:string, name:string, tier:int, golden:boolean, spine:string, avatar:string, x:int, y:int, dir:string, facing:1|-1, maxHp:int, skillIndex?:int, moduleId?:string, items?:string[], … }`.

### 4.5 Other S2C pushes

- `m.toast { kind, text }` (per player; `Match.js:683-686`).
- `m.ticker { text, id:string|null, type, priority:int, playerId }` (`Match.js:689-708`).
- `m.emote { playerId, id }` (`Match.js:970-977`; cooldown 1 s → `ERR.RATE`; ids = the 36 whitelisted `EMOTES`).
- `m.result` — see §5.
- `m.unitStats { seq:int|null, round:int, units:unitStatsEntry[] }` — reply to `g.unitStats`; `unitStatsEntry` = `{ id, uid, defId, hp, alive, maxHp, atk, def, res, interval:number|null, blockCnt, moveSpeed, base:{maxHp,atk,def,res,interval,blockCnt,moveSpeed}, range?:[[dr,dc]] }` (`shared/protocol.js:190-238`).

---

## 5. Client-side battle contract (DESIGN §14 — the part that constrains your Swift sim)

`m.public.combatMode` is `'client'` by default (`envClientCombat()`, `Match.js:254`): the **browser of the field's authoritative player simulates the battle** from a spec the server sends.

### 5.1 `b.start` (per field, per recipient, `server/match/Match.js:_startMsg`, 2085-2093)

```
{ t:'b.start', battleId:string, fieldId:string, kind:'normal'|'unite'|'boss'|'hidden',
  spec:BattleSpec,
  authoritative:boolean,     // true ⇒ THIS client must simulate and report
  startAt:number,            // server epoch ms the field started
  serverNow:number, elapsed:number,   // elapsed = field game-seconds so far (display replicas fast-forward)
  speed:number,              // game speed (2)
  watch:boolean, done:boolean }
```
Authority = the lowest-seat connected human among the field's players (`_authorityFor`, 2073-2083); spectators (`watch:true`) get a display-only replica. A re-connect/resync re-sends `b.start` with current `elapsed` (`_resendBattle`, 2448).

**`spec` is a serialized Battle spec** (`server/sim/spec.js:buildBattleSpec`, 46-76, `SPEC_VERSION=1` at :28):
```
BattleSpec = {
  v:1, battleId:string|null, fieldId:string|null, kind:string,
  seed:uint32, modeId:string, round:int, stageId:string|null,
  rect:{ r0,r1,c0,c1 }|null,
  timeLimit:number|null,      // null for boss/hidden (they end by pool/match)
  players: BattlePlayer[],    // NOTE: JSON-serialized — ±Infinity became ±1e308, NaN became null
  spawns: SpawnSpec[],        // entries scheduled at time Infinity are dropped
  routes: Route[], flags:object, enemyOverrides:object,
  waveId:string|null, bossId:string|null, content:'full',
  boss:{ poolHp:number, poolMax:number }|null }   // boss/hidden only

BattlePlayer = { playerId:string, seat:int, side:'L'|'R', colOffset:int,
                 units: BattleUnit[], bonds:{[bondId]:{count,active,tier,layers}},
                 bandId:string|null,
                 playerEffects:[{ id, key:string|null, source:string|null, params, counter, data }],
                 deviceOverrides:object }
BattleUnit (chess) = { uid:int, kind:'chess', chessId:string, row:int, col:int,
                       dir:string, items:string[], skillIndex:int, moduleId:string|null, carryState? }
BattleUnit (token) = { uid:int, kind:'token', tokenId:string, row:int, col:int,
                       dir:string, ownerUid:int }
SpawnSpec = { time:number, enemyKey:string, routeIndex:int, count:int, interval:number,
              mods:{ hpMul?,atkMul?,speedMul?,slot?,bountyId?,... }|null,
              tag?:'boss'|'part'|'bounty'|null, ownerPlayerId?:string,
              sourcePlayerId?:string,           // unite fields: whose leak re-enters
              bounty?:{ coins:int, ownerPlayerId:string },
              actionIndex?:int, preview?:{gate,start,fly,elite,boss} }
```
(producer shapes: `PlayerState.battleInput`, `server/match/PlayerState.js:1532-1558`; spawn building `server/match/waves.js:322-330, 525-538, 648-655`.)

### 5.2 Reporting (`public/js/battle/runner.js:485-560`)

- `b.progress` **without rid**, ~1 Hz (boss/hidden fields 250 ms = 4 Hz), from the authoritative client only:
```
{ t:'b.progress', battleId:string, gt:number(0..1e5), killed:int, total:int,
  leaks?:number, bossDmg?:number,          // boss/hidden: cumulative pool damage + LP meter value
  by?:{[playerId]:number},                 // per-player cumulative boss damage
  done?:boolean, left?:{[playerId]:int},   // unite: each leaker's enemies still standing
  replay?:{ segment:string, seq:int, tick:int, inputs:[...] } }   // account mode only
```
(`shared/protocol.js:277-289`.)
- `b.result` — the authoritative client sends **once**, right after the final progress, `{ t:'b.result', battleId, result:BattleResult, replay? }`; sent with a rid; duplicate deliveries are idempotent on the server; lost ones (`DISCONNECTED/OFFLINE/TIMEOUT`) are re-sent on the next session or next `b.start`.

**BattleResult wire shape** (`isBattleResult`, `shared/protocol.js:54-59`; limits `RESULT_LIMITS :29`; produced by sim `compactResult`, `server/sim/spec.js:314`):
```
BattleResult = {
  reason:'cleared'|'timeout'|'forced', time:number(0..1e5),
  killed?:int, total?:int, errors?:int, bossHpLeft?:number,
  perPlayer: { [playerId]: PerPlayer },        // 1..4 entries, must cover exactly the spec players
  unspawned?: [ { enemyKey, sourcePlayerId:string|null, tag?:string|null, time?:number } ] }  // unite only

PerPlayer = {
  killed:int, total:int,                       // 0 ≤ killed ≤ total ≤ 1e5
  leaked: [ Leak ], perfect:boolean,
  layerGains: { [bondId]: number ≤1e4 },       // ≤40 bonds
  coins:number, damageDealt:number, bossDamage:number, healingDone:number, deaths:number,
  unitsEnd: [ { uid:int|null, hpPct:number 0..1, sp:number, alive:boolean,
                skillActive?:boolean, defId:string|null } ],        // ≤64
  unitStats?: [ { uid:int|null, defId:string|null, kind?:string,
                  dmg?,kills?,heal?,taken?,attacks?:number } ] }    // ≤160

Leak = { enemyKey:string, mods?:{[k:string(32)]: number|null|bool|string}|null,   // ≤16 mods
         lpr?:number 0..1000, sourcePlayerId:string|null, tag?:string|null,
         counted?:boolean, boss?:boolean, spawned?:boolean }
```

### 5.3 `b.pool` (boss/hidden fields, broadcast ≤4 Hz, `server/match/Match.js:_broadcastPool`, 2686-2712)

```
{ t:'b.pool', hp:number, max:number, teamLp:int|null,
  acked:{ [fieldId]: number } }   // per field: cumulative boss damage the server has counted
```
Client math: display `hp − (its own cumulative damage − its field's acked)`; report cumulative damage in `b.progress.bossDmg/by`; end as `'cleared'` when the displayed value reaches 0. (`LocalBossPool`, `server/sim/spec.js:171-215`.)

### 5.4 `b.end` (server-initiated kill of a client battle)

`{ t:'b.end', battleId, fieldId, reason }` — force end / takeover (e.g. `_endFinal`, `Match.js:2652-2684`). The client stops simulating; the server re-runs or accepts a held result.

### 5.5 Exactly what the server validates on `b.result` (`server/match/fields.js:validateClientResult`, ~line 456-580)

Structural validation first (`isBattleResult`, types/sizes). Then semantic checks — a failure ⇒ the server **re-simulates the battle itself** (`_runOnServer`) or hands the boss field to the partner; the sender is not punished. The checks, in order:

1. `spec`/`perPlayer` object shape present.
2. `reason ∈ {cleared, timeout, forced}`.
3. `time` within `0 .. (spec.timeLimit>0 ? timeLimit+5 : HARD_CAP_SECONDS=3700)`.
4. **Players**: `perPlayer` keys exactly equal the spec's player ids (every spec player reported, nobody else).
5. **Counts**: `0 ≤ killed ≤ total ≤ maxTotal` where `maxTotal = spawnCount*4 + 100` (spawnCount = Σ spec spawn counts, count clamped 1..10000).
6. **Leaks** (non-boss fields): every `leak.enemyKey` must exist in the spec spawns or be a *derived* key (a key the enemy's data record mentions via `enemy_…` patterns — summons/splits/transformations, bounded); per-key leak count ≤ spec spawn count for that key (multiset bound; derived keys bounded by `maxTotal`); a leak with `counted:false` is only legal for enemies that never count (data `notCountInTotal`, spawn `countInTotal:false`, tag `boss`/`part`, or derived keys); `countedLeaks ≤ total + spawnCount`; `perfect === (countedLeaks === 0)`.
7. **Unite leaks** (`spec.kind==='unite'`): each `(enemyKey, sourcePlayerId)` pair ≤ what that leaker sent into the unite (budget from `keySourceCounts`), and content-spawned children only on a leaker who sent in a parent, ≤ the parent's data offspring bound (`offspringPerParent`: talent `<X>.enemy_key` + `<X>.cnt`, DeathRattle=1). `unspawned` entries likewise consume the same per-leaker budgets and ≤ `spawnCount`.
8. **Layer gains**: for each `layerGains[bondId]` — `0 ≤ n ≤ min(60 + 4*round + layerAllowance(bond), room-left-under-999-from-starting-layers)`; zero gains required when `spec.flags.layerGainsEnabled === false`; bond must exist in game data; **a nonzero gain is only allowed on bonds the player's own lineup/band/effects/units/items can name** (`layerBondsOf`).
9. **Coins**: per-player `coins` and the sum over players ≤ total bounty coins derivable from the spec spawns (`bounty.coins`/`mods.bountyCoins` × count).
10. **unitsEnd**: only uids on that player's own board (`own.chess`), each once, `0 ≤ hpPct ≤ 1`, `0 ≤ sp ≤ 1e5`; `alive` recomputed as `alive && hpPct > 0`. Unknown/summon uids are silently dropped.
11. **unitStats**: uid must be on the board, or (battle-created unit) defId must be fieldable by this player's lineup (own units' summons + ownerless summons); `dmg/kills/heal/taken/attacks` clamped ≥ 0; unknown records dropped.
12. All numeric stats clamped to `0..1e13`; the accepted result is **rebuilt from whitelisted fields only** (never the raw payload).
13. Boss-specific acceptance (`Match._onResult`, 2339-2396): the result must be consistent with the server's shared pool — `'cleared'` accepted only when the pool is empty or the client's cumulative report covers the remaining pool HP (`reported − bossAcked ≥ pool.hp − 1`; the result is then *held* until the boss clock drains the budget); each player's `bossDamage` is floored to what the server already credited them.
14. **SP_VERIFY re-simulation** (`_verifyResult`, 2406-2432): mode `'all'` (every accepted result re-simulated; a digest mismatch replaces the client result with the server's) or `'sample'` (≈1 in 8, hash of battleId % 8, log-only). `resultDigest` in `server/sim/spec.js:270`.

**Implication for your Swift sim port:** your simulator must reproduce, per battle: kill/total counts, leak list with `lpr`/`mods`/`counted` flags matching the spawn schedule, per-bond layer gains within `60+4·round` (+ trait allowances) and the 999 cap, bounty coins, and end-of-battle unit states — all derivable from the same data files the server serves at `/data/`.

---

## 6. Solo vs coop differences

- **Rooms**: solo rooms seat exactly 1 human, no bots (`room.join` on solo → `ROOM_FULL 'solo room'`, `addBot` refused, `server/lobby.js:352-354, 398-399`); coop seats up to 4 with bots.
- **Reconnect window**: solo match 24 h vs 10 min default (`server/lobby.js:273, 713-719`).
- **Pause**: `g.pause { on:boolean }` — solo only (`ERR.WRONG_PHASE 'co-op battles never pause'`, `Match.js:1071-1123`). While paused the field clock, deadlines, boss budget and server pacers freeze; `m.public.paused:true`; disconnect/leave/phase end resumes; on resume every clock is shifted by the paused duration.
- **Autoplay**: `g.autoplay { on:boolean }` — any mode; marks the seat bot-controlled (`kickBot` acts for it in the current phase) and updates `m.public.players[].autoplay` (`Match.js:1006-1011, 1128`).
- **Watch**: `g.watch { fieldId }` (heavy bucket 2/s). Rules: while your own normal battle runs you cannot watch (`_watchClient`); a fighting player sees only its own boss field (other group hidden); eliminated/departed players may watch anything; `fieldId:"n:<pid>"` during prep = one-shot scouting board (refused while battle fields are live, `Match.js:979-1003`). Response: `b.start{watch:true}` + fast-forwarded local replica (client combat) or `m.field` + `b.snap` (server combat).
- **Band draft**: solo has 0 skips (`g.bandSkip` → `WRONG_PHASE 'no skip in solo'`), no turn shuffle (`Match.js:1172-1173, 1318`).
- Final Assault pairing, boss pool and `teamLp` are coop concepts (solo also fights the boss alone, `bossRound` solo variant at `Match.js:1390`).

---

## 7. Versioning

- **`PROTOCOL_VERSION = 1`** (`shared/constants.js:3`) — the wire-format number sent in `hello.version` and returned in `welcome.version`. If a hello carries a version ≠ 1, the server answers `error BAD_MSG detail:"version mismatch: server 1"` and creates **no session** (`server/net.js:578-581`). Omitting `version` is accepted by the server, but the browser always sends it; send it.
- **`APP_VERSION = '0.1.2'`** (`shared/constants.js:6`) — release version; only informational (`/healthz.app`, server banner). A test keeps it equal to `package.json` "version".
- **Build guard** (`public/js/ui/buildGuard.js`): the browser polls `/healthz` every 60 s and compares `healthz.build` (hash of `public/index.html`, `public/js`, `public/css`, `server/index.js:127-186`). A new tag (confirmed twice) ⇒ outside a match the page reloads itself; during a match it only warns until the match ends. `/healthz.build` unreadable ⇒ never reloads. A native client does not need this, but it is the deployment's staleness signal.
- `replay-versions.json` / `worker/match-versions.js`: replay compatibility pinning for the account/archive mode (Workers-hosted "online lobby" — a separate transport in `public/js/room-net.js` with its own close codes 4003/4004 and `room.join` approvals; the plain self-hosted server described above ignores that path).

---

## Quick Swift mapping notes

- Envelope: `enum Frame` keyed on `t` with `rid: Int?` on C2S; every S2C frame may carry `rid` (only `ok`/`error`/`pong`/`welcome` actually do).
- `null` vs absent matters: views omit optional fields (`bossHp`, `draft`, `sp`, `unite`, `teamLp`, `pendingLp`, `progress`, `overtimeAt`); use `Optionals` + `decodeIfPresent` everywhere. `m.private.shop.slots` / `hand` / `temp` contain explicit `null`s for empty slots.
- Numbers: JSON numbers everywhere (no strings); IDs are strings matching `[A-Za-z0-9_\-.:]{1,64}`.
- The three big nested payloads are `m.public` (§4.2), `m.private` (§4.3) and `b.start.spec` (§5.1) — those plus `BattleResult` (§5.2) cover ~all state you need to render; the rest are small notifications.
