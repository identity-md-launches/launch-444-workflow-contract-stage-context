# Pacts

A public, deterministic guild strategy game on Sepolia, played with its own launch token **Pact
($PACT)**. Guilds hold tiles on a shared 12x12 map, attack each other in the open, vote on every
move, and sign pacts backed by token bonds that are slashed to the victim if a guild betrays a
partner. Seasons pay the top guilds and mint trophy NFTs.

There is no randomness, no hidden information and **no admin power anywhere**: no owner, pauser,
minter, upgrader or fee switch. Every token the game ever pays out was paid in by a player.

## Contracts

| Contract | File | Role |
|---|---|---|
| `LaunchToken` | `src/LaunchToken.sol` | Fixed-supply ERC-20 "Pact" / "PACT", 18 decimals, 10^27 minor units minted to the deployer. No admin functions. |
| `Guilds` | `src/Guilds.sol` | Founding, joining, leaving, expulsion; one-member-one-vote proposals; pooled treasuries; the shared epoch clock. |
| `Realm` | `src/Realm.sol` | The 144-tile map, troop purchases, attack declarations, epoch settlement, tile income, season standings. |
| `Diplomacy` | `src/Diplomacy.sol` | Pacts between two guilds backed by bonds; automatic slashing on betrayal; bond return on expiry. |
| `Season` | `src/Season.sol` | Prize pool from purchase fees, season close, 50/30/20 claims, trophy minting. |
| `Banners` | `src/Banners.sol` | ERC-721 trophies that only `Season` can mint. On-chain metadata. |

ABI files for each contract are in `docs/abi/<Contract>.json`.

### Deployment topology

The five game contracts depend on each other in both directions (Realm must report attacks to
Diplomacy, Diplomacy must read pending attacks from Realm; Realm must forward fees to Season, Season
must read standings from Realm; Season must mint Banners, Banners must trust Season). Because the
launch allows constructor wiring only, with no post-deployment calls, the cycles are closed inside
constructors:

```
launch.json           constructor creates
-----------           -------------------
Guilds($token, 3600)
Realm($token, $contract:Guilds, 3600, 604800, 1e18, 500)
   └── Diplomacy(token, guilds)      realm = msg.sender
   └── Season(token, guilds, diplomacy)   realm = msg.sender
         └── Banners()                minter = msg.sender
```

`Realm.diplomacy()`, `Realm.season()` and `Season.banners()` return the addresses; `Realm`'s
deployment receipt also contains the three creation traces. Each nested contract records its
creator as an immutable and trusts only that address, so no binding step, no initializer and no
front-running window exist. Nothing here uses DELEGATECALL, CALLCODE or SELFDESTRUCT; the nested
contracts are created with plain CREATE from Realm's init code, and Realm's runtime is 10,290 bytes.

`$owner` is not used by any contract. The game has no owner.

## Manifest guidance (for the launch.json step)

Two application contracts, in this order:

| Name | Source | constructorArgs |
|---|---|---|
| `Guilds` | `src/Guilds.sol:Guilds` | `["$token", 3600]` |
| `Realm` | `src/Realm.sol:Realm` | `["$token", "$contract:Guilds", 3600, 604800, "1000000000000000000", 500]` |

Constructor parameters:

| Parameter | Value | Meaning |
|---|---|---|
| `epochLength` | `3600` | One epoch is one hour. Passed to both Guilds and Realm; Realm reverts if they differ. |
| `seasonLength` | `604800` | One season is seven days (168 epochs). Must be a multiple of `epochLength`. |
| `troopPrice` | `1e18` | One troop costs 1 PACT. **Deployment choice, not fixed by the brief.** |
| `feeBps` | `500` | 5% of every troop purchase goes to the season prize pool. **Deployment choice, not fixed by the brief.** |

The launch token is `LaunchToken` (`src/LaunchToken.sol`), 18 decimals, supply
1,000,000,000 × 10^18. The contracts receive no token allocation.

Constructors do not accept ETH, make no external calls other than reading Guilds' clock and setting
token approvals to Guilds, and take only `address` and `uint256` arguments.

## Game rules as implemented

### Clock

`genesis` is Guilds' deployment timestamp. Epoch `e` covers `[genesis + e·epochLength,
genesis + (e+1)·epochLength)`. Season `s` covers epochs `[s·168, s·168 + 167]`.

### Guilds and votes

- Anyone can found a guild (name of 1–32 bytes) or join an existing one. An address is in at most one
  guild at a time and may leave at any time. Leaving forfeits nothing personally; the treasury is
  pooled and stays with the guild.
- A proposal is created by a member and carries a kind, a `target` address, a treasury `amount`
  and three data words. The proposer's yes vote is cast at creation.
- Only members who joined **before the proposal was created** may vote (tracked by a per-guild join
  sequence number; leaving and rejoining gives a new number). One vote per member, votes cannot be
  changed, and the denominator is the member count at creation. A proposal is approved when
  `yes × 2 > eligibleVoters` (a strict majority). A single-member guild approves its own proposals
  immediately.
- A proposal created in epoch E can be voted on and executed until the end of epoch E+1, then it
  expires.
- Kinds and who acts on them:

| Kind | Fields | Executed by |
|---|---|---|
| `Expel` | `target` = member | `Guilds.execute` — anyone, after approval |
| `Payout` | `target` = recipient, `amount` | `Guilds.execute` — transfers from the treasury |
| `TreasuryTroops` | `target` = Realm, `amount` | `Realm.buyTroopsFromTreasury` |
| `Attack` | `target` = Realm, `data1` = tile, `data2` = holder guild at proposal time, `data3` = troops | `Realm.declareAttack` |
| `Pact` | `target` = Diplomacy, `amount` = bond, `data1` = other guild, `data2` = epochs | `Diplomacy.sign` |

- Spending the pooled treasury (payout, troops, bond) always goes through a proposal, and Guilds
  releases the `amount` only to the `target` the majority approved, once. **Voters must check the
  target address**: a proposal naming any other contract as target is a payout to that contract.
  The frontend fills in the Realm and Diplomacy addresses.

### Troops and income

- `Realm.buyTroops(n)` charges `n × troopPrice` from the caller and credits `n` troops to the
  caller's guild reserve. `feeBps` of the payment is forwarded to Season for the current season; the
  rest is the income pool of the current epoch.
- When an epoch is settled, its income pool (plus any carry) is divided equally per held tile among
  the guilds that held tiles during that epoch. Income accrues per guild in Realm and
  `Realm.collectIncome(guild)` (anyone) moves it into the guild's treasury in Guilds. Rounding dust and
  the income of epochs with no held tiles carry into the next epoch. Nothing is ever minted.

### Attacks and settlement

- `Realm.declareAttack(proposalId)` (anyone, once the proposal is approved) commits the proposal's
  troops from the guild reserve to the named tile in the **current** epoch. It fails if the tile's
  holder differs from the holder named when the proposal was created, if the guild would attack its
  own tile, if the reserve is too small, or if the guild already attacks that tile this epoch.
  **Exception:** an attack that would break an active pact (the named holder is a pact partner and
  the pact has not run out) can only be declared by a current member of the attacking guild whose
  join sequence is at most the proposal's `seqAtCreation` (`BetrayalRequiresMember`). This matches
  voting eligibility; joining or rejoining after proposal creation cannot grant permission to
  trigger a betrayal. An eligible member need not have personally voted on the approved proposal.
- `Realm.settle()` (anyone) settles the next unsettled epoch once it has ended. Epochs settle in
  order; `settlePending(max)` catches up several at once. Settlement first distributes the epoch's
  income, then resolves every attacked tile, then (for the last epoch of a season) records standings.
- `Realm.settleStep(maxAttacks)` (anyone) does the same work in bounded pieces: it visits at most
  `maxAttacks` attack entries (each attack is visited once to compare forces and once to apply
  losses) and returns `true` when the epoch is complete. Income is distributed on the first step,
  tiles are resolved one after another, standings are recorded on the last step, and
  `settledEpochs` advances only then. `settle()` finishes a settlement that `settleStep` started.
  `settlementProgress()` reports where a settlement stands and returns `(false, 0, 0)` whenever
  no settlement has started, including when attacks are queued. This keeps every settlement
  transaction inside a block however many attacks were declared, so settlement can never be
  frozen by spam.
- **Void attacks.** An attack names the holder it was declared against. If, when its epoch is
  resolved, the tile is held by someone else (an earlier epoch that was settled later changed
  hands), the attack is void: it does not fight, its troops return to the guild reserve, and
  `AttackVoided` is emitted. An attack therefore never hits a guild it did not name, which is what
  keeps the pact rules exact when settlement lags. The consumed proposal is not restored.
- Resolution on a tile with defending garrison D and (non-void) attackers c₁..cₙ, total T = D + Σcᵢ:
  - the **unique largest** force wins; if that is an attacker it takes the tile, otherwise (the
    holder is largest, or there is a tie for largest) the holder keeps it. Two tied attackers on an
    empty tile leave it empty.
  - every participant loses `force × (T − force) / T` troops (integer division). The winner's
    survivors become the garrison; every other side's survivors return to their guild reserve.
- Garrisons cannot be reinforced; the only way to add troops to a tile is to retake it.

### Pacts

- Each guild passes a `Pact` proposal naming the other guild, its own non-zero bond and the number of
  epochs. `Diplomacy.sign(proposalA, proposalB)` (anyone) checks that they name each other with the
  same length, that no pact is already active between the two, and that neither guild has an attack
  on the other in an epoch that is not yet settled. Both bonds are pulled from the treasuries.
- The pact covers epochs `[signing epoch, signing epoch + epochs − 1]`.
- If a guild declares an attack on a tile held by its partner during that window, Realm reports it
  in the same transaction and Diplomacy pays the attacker's bond **and** the victim's own bond into
  the victim's treasury. The attack itself still resolves. The betrayal is counted in the season of
  the attack. Only a current member eligible for the proposal's vote can declare such an attack (see above);
  `Diplomacy.wouldBreakPact(attacker, defender, epoch)` tells whether a declaration would be one.
- A guild that has approved an attack on another guild and then signs a pact with it should let the
  proposal expire (end of the next epoch) or declare it before signing: while the pact is active the
  proposal can only be declared by current members who joined before its creation, and doing so
  is a betrayal.
- If the window has passed, anyone can call `Diplomacy.expire(pactId)` to return both bonds. An
  attack after the window that arrives before `expire` simply expires the pact.

### Seasons and trophies

- `Realm` records the top three guilds by tiles held when it settles the last epoch of a season.
  Ties rank the older guild (lower id) higher. Later settlements never change a recorded season.
- `Season.close(season)` (anyone, after the season ended and its last epoch is settled) allocates
  50/30/20 of the season's pool to the recorded guilds. Each guild's share is divided equally among
  the members it had at the season's last second (`Guilds.memberCountAt`). Unfilled ranks, guilds
  with no members, and division dust roll into the next season's pool. Seasons close **in order**
  (`PreviousSeasonNotClosed`), so the pool a rollover lands in is always still open; Realm records
  standings in order, so every closable season has closable predecessors.
- `Season.claim(season, guild)` pays the caller's share if they were a member of that guild at
  season end (`Guilds.wasMemberAt`; joining later earns nothing, leaving later loses nothing) and
  mints a Winner banner with the rank. One claim per member per guild per season.
- `Season.mintPeaceBanner(season, guild)` (anyone, after the season ended) mints one Peace banner
  for a guild that existed at season end and broke no pact during the season. It is minted to the
  Guilds contract on the guild's behalf and is recorded with the guild id; it is not transferable
  out of Guilds.
- Prize money that is never claimed stays in Season.

## Events for the frontend

Every state change emits an event, so the map, guilds, pending votes, pacts, betrayals, standings
and banners can be rebuilt from logs:

- Guilds: `GuildFounded`, `MemberJoined`, `MemberLeft`, `MemberExpelled`, `ProposalCreated`,
  `VoteCast`, `ProposalApproved`, `ProposalExecuted`, `ProposalConsumed`, `TreasuryDeposited`,
  `TreasuryPaid`.
- Realm: `TroopsBought`, `AttackDeclared`, `AttackResolved`, `AttackVoided`, `TileResolved`,
  `EpochSettled`, `IncomeCollected`, `StandingsRecorded`. `Realm.map()` returns all 144 holders and
  garrisons. During a stepwise settlement `AttackResolved`/`AttackVoided`/`TileResolved` arrive over
  several transactions and `EpochSettled` closes the epoch.
- Diplomacy: `PactSigned`, `PactBroken`, `PactExpired`.
- Season: `FeeRecorded`, `SeasonClosed`, `PrizeClaimed`, `PeaceBannerMinted`.
- Banners: `Transfer`, `Approval`, `ApprovalForAll`, `BannerMinted`.

## Operational responsibilities

Nothing needs an operator, but somebody has to send the permissionless transactions:

- **Settle epochs**: `Realm.settle()` / `settlePending(max)` after each epoch ends. Attacks resolve
  and income is distributed only on settlement. The website should offer a "settle" button and a
  keeper may call it. If an epoch holds too many attacks for one transaction (`settle()` runs out
  of gas), call `settleStep(maxAttacks)` repeatedly (a few hundred per call is comfortable) until
  it returns `true`; `settlementProgress()` shows how far it got. Use
  `currentEpoch() > settledEpochs()` to detect ended epochs needing settlement; the progress view
  reports only a settlement already in progress.
- **Collect income**: `Realm.collectIncome(guild)` moves accrued income to the treasury before it
  can be spent by vote.
- **Expire pacts**: `Diplomacy.expire(pactId)` after the last epoch of the pact to return bonds.
- **Close seasons and claim**: `Season.close(season)` after the season's last epoch is settled, in
  season order, then each winning member calls `Season.claim`, and anyone calls
  `Season.mintPeaceBanner` for eligible guilds.
- **Publish source, attest, admit and deploy** are done by the network services after this stage.
  Explorer verification and the GitHub/IPFS publication are open items for them.

Gas note: settling the last epoch of a season scans all 144 tiles (roughly 0.4–0.6M gas); other
settlements cost about 30k gas per attack (measured: 1000 one-troop attacks on one tile take about
33M gas in one `settle()` call, and 12 `settleStep(50)` calls of under 3M gas each settle 300).
Founding a guild is free, so anyone can declare many one-troop attacks from throwaway guilds; the
stepwise settlement exists so that this can only make settlement slower, never impossible.

## Assumptions and trust

- The launch token is the only token used; it returns `true` and reverts on failure, has no hooks
  and no fee on transfer. All transfers are still checked.
- Realm is created with Guilds and trusts it as the source of membership and approvals. Diplomacy,
  Season and Banners trust only their creator (Realm, Realm, Season respectively).
- Approval semantics are fixed at proposal creation (eligible voters and denominator). Members who
  leave after creation still count in the denominator; expelled members lose their vote.
- Membership is permissionless and does not prove an independent identity. The betrayal gate
  excludes wallets that joined after the attack proposal, but an adversary already eligible at
  proposal creation can declare an approved betrayal. Check outstanding proposals before signing
  a pact; approval is not revoked by a later pact.
- Membership at season end is determined from join/leave stints, so leaving and rejoining across the
  season boundary is handled exactly.
- The peace banner is awarded to every guild that existed at season end without a betrayal, whether
  or not it held a pact. Founding a guild is free apart from gas.
- Proposal `target` addresses are chosen by the proposer and approved by the majority; the contracts
  cannot tell a legitimate Realm address from a wrong one, because Guilds is deployed before Realm
  and Diplomacy and the launch allows no post-deployment registration (a first-come registration
  call could be front-run and brick the launch). A `TreasuryTroops` or `Pact` proposal whose target
  is any other address is therefore a payout of `amount` to that address, with exactly the same
  majority authority as a `Payout`. Voters must check the target; the frontend fills in the real
  Realm and Diplomacy addresses and should flag any proposal whose target differs.
- A majority can also vote a `Payout` to one of the game contracts themselves (Guilds, Realm,
  Diplomacy, Season). The transfer succeeds and the tokens are unrecoverable by design, because no
  contract has an admin path; that contract's balance then exceeds its accounting by that amount.
  Nothing forces this, and it harms only the guild that voted it.
- `vote()` stays callable on an already executed proposal; the extra vote has no effect.
- There is no reinforcement action and troops are never refunded to a player except when an attack
  is void (its named holder changed before its epoch resolved); the game is intentionally simple
  and all value flows are described above.
- Tests are not an audit. The contracts hold player funds and must go through the independent
  adversarial review before the launch is admitted. No Slither or Mythril run was part of this
  assignment; `forge build`, `forge test` (111 permanent tests, including fuzzing on the token) and
  `forge fmt --check` were run, and the protected launch floor tests were exercised locally against
  the real init code with computed CREATE2 addresses.

## Revision history

Second round, after the independent review of the first accepted version:

- An attack can no longer resolve against a holder it did not name. When settlement lagged, an
  attack declared against the storage holder could fight whoever took the tile in an earlier,
  later-settled epoch, including a pact partner, without slashing. Such attacks are now void and
  refunded (`AttackVoided`).
- Seasons close in order, so a rollover can never land in an already closed season's pool.
- An attack that breaks an active pact must be declared by a member of the attacking guild; before,
  the partner could declare a stale approved proposal and collect both bonds.
- Settlement can be split over several transactions (`settleStep`) so an epoch with any number of
  attacks can always be settled.

Third round, after reproducing both follow-up findings:

- Pact-breaking declarations now require current membership and eligibility at proposal creation.
  Late joins and rejoining cannot trigger stale approved attacks; eligible members can still
  declare them, and attacks that break no pact remain permissionless.
- `settlementProgress()` now returns zeros whenever no settlement is in progress, even if the
  next epoch to settle already contains attacks.

## Development

```
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"`, `bytecode_hash = "none"`; `ffi`
and filesystem access are off. `forge-std` is vendored under `lib/forge-std` as plain files. The
`script/Deploy.s.sol` script deploys the same wiring locally; its `deploy(token, config)` function
is what the tests call, and `run()` uses constants only.
