# Security Policy

## Status

Gambiarra Finance v2 is **pre-deploy and unaudited**. No v2 contract holds real
funds. The legacy MasterChef is live on BNB Smart Chain, is owned by
`0x0000000000000000000000000000000000000000`, and cannot be modified by anyone —
including this project.

Do not send funds to any address claiming to be a v2 deployment until an
official address is published in [`/agents.json`](https://gambiarra.finance/agents.json).

## Reporting a vulnerability

Please **do not open a public issue** for a security problem.

- Email: **codingsh@pm.me**
- Include: affected contract/file, a minimal reproduction (Foundry test if
  possible), impact, and any suggested mitigation.
- You will get an acknowledgement as soon as possible. Please allow time for a
  fix before public disclosure.

## Scope

In scope:

- `contracts/src/GambVault.sol`
- `contracts/src/GambTwapOracle.sol`
- `contracts/src/GambLendingPool.sol`
- `contracts/src/GambLeverageZap.sol`
- `contracts/src/interfaces/*`
- The agent-facing endpoints (`/llms.txt`, `/agents.json`, `/api/stats`) for
  injection, spoofing or data-integrity issues.

Out of scope:

- The legacy MasterChef and GAMB token (immutable, owned by `0x0`).
- Third-party protocols (PancakeSwap, OpenZeppelin, BSC RPC providers).
- Economic risk inherent to leverage or LP positions.
- The site's visual design.

## Known limitations

- No third-party audit has been completed.
- `GambVault` and `GambLeverageZap` do not yet have unit tests; they depend on
  mocks of MasterChef, Pancake router and flash pairs.
- No fork tests against BSC mainnet state.
- x402 is a roadmap item. No facilitator, stablecoin or payment contract has
  been selected; treat any payment address as untrusted until published here.

## Safe-harbor

Good-faith research that respects this policy, avoids privacy violations,
avoids degrading service, and gives reasonable time to fix before disclosure
will not be pursued legally.
