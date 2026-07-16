# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

<!-- SPECKIT START -->
For additional context about technologies to be used, project structure,
shell commands, and other important information, read the current plan
<!-- SPECKIT END -->

This is a Sedona fork of official Uniswap V2 periphery (routers + migrator + libraries), unmodified from upstream so far. It's a prep repo for a future confidential/FHE-integrated V2 DEX on Arbitrum — see `SedonaFi/v2-core` (sibling repo, the pair/factory this router depends on) and the DailyNote vault's `Projects/sedona-fhe/` for integration task tracking.

## Commands

- Install: `yarn`
- Build: `yarn compile` (`rimraf ./build` → `waffle .waffle.json` → copies `buildV1` artifacts into `build`)
- Lint: `yarn lint` (checks `./test/*.ts` only — contracts have no linter); fix with `yarn lint:fix`
- Test (all): `yarn test` (`pretest` auto-runs `yarn compile` first)
- Test (single file/case): `npx mocha --require ts-node/register test/UniswapV2Router02.spec.ts --grep "<test name>"`

CI (`.github/workflows/CI.yml`) runs `yarn && yarn lint && yarn test` on Node 10.x/12.x.

Solidity `0.6.6` (`pragma solidity =0.6.6;` on Router01/Router02/Migrator; libraries use `>=0.5.0`). Waffle config (`.waffle.json`): `evmVersion: istanbul`, optimizer `enabled: true, runs: 999999`. Depends on `@uniswap/v2-core@1.0.0` and `@uniswap/lib@4.0.1-alpha` (npm package, not the local `v2-core` clone — that's how upstream ships it).

## Architecture

- `contracts/UniswapV2Router01.sol` — original router: add/remove liquidity, swap functions, no fee-on-transfer support.
- `contracts/UniswapV2Router02.sol` — superset of Router01 (with `_addLiquidity` marked `virtual`), adds fee-on-transfer-token variants (`removeLiquidityETHSupportingFeeOnTransferTokens`, `swapExactTokensForTokensSupportingFeeOnTransferTokens`, etc. via internal `_swapSupportingFeeOnTransferTokens`). This is the canonical/recommended deployed router.
- `contracts/UniswapV2Migrator.sol` — one-shot migration contract: pulls a user's V1 LP tokens, removes V1 liquidity, deposits into V2 via `router.addLiquidityETH`, refunds leftover dust to the caller.
- `contracts/libraries/` — `UniswapV2Library.sol` (sortTokens, `pairFor`/CREATE2 addressing, getReserves, quote, price-impact helpers), `SafeMath.sol`, `UniswapV2OracleLibrary.sol` (TWAP helpers), `UniswapV2LiquidityMathLibrary.sol`.
- `contracts/interfaces/` — router/migrator/WETH/ERC20 interfaces, plus `V1/` legacy V1 interfaces.
- `contracts/test/` — mock ERC20/WETH9/DeflatingERC20 and `RouterEventEmitter` for test harnesses.
- `contracts/examples/` — sample consumer contracts (flash swap, oracle, sliding-window oracle, swap-to-price, liquidity value), mirrored by `test/Example*.spec.ts`.

**Init-code-hash constraint:** `contracts/libraries/UniswapV2Library.sol:24` hardcodes the CREATE2 init-code hash of the compiled `UniswapV2Pair` bytecode from `SedonaFi/v2-core`:

```
hex'96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f' // init code hash
```

used inside `pairFor` (lines 18-26) to compute pair addresses off-chain without external calls. **If `UniswapV2Pair.sol` in `v2-core` is ever edited — compiler version, optimizer settings, or any FHE-related change — this hash must be recomputed and patched here**, or every router `swap*`/`addLiquidity*`/`removeLiquidity*` call resolves the wrong pair address and reverts. This is the same failure mode that hit the Sedona V3 deploy (`PoolAddress.sol` init-code-hash mismatch).
