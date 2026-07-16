// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.25;

import { FHE, euint64, ebool, InEuint64 } from "@fhenixprotocol/cofhe-contracts/FHE.sol";

import { ConfidentialUniswapV2Library } from "./ConfidentialUniswapV2Library.sol";
import { IConfidentialUniswapV2Pair } from "./interfaces/IConfidentialUniswapV2Pair.sol";
import { IFHERC20Minimal } from "./interfaces/IFHERC20Minimal.sol";

/// @title ConfidentialUniswapV2Router
/// @notice Router for `ConfidentialUniswapV2Pair` pools (v2-core `confidential/`), supporting single-
/// and multi-hop `swapExactTokensForTokens` over encrypted euint64 amounts.
///
/// ## Why every hop needs its own attested `InEuint64`, not a re-forwarded on-chain handle
/// The task this router was built against asked for "multi-hop passes encrypted output handles
/// between pools with `FHE.allowTransient`" so no intermediate amount is ever decrypted on-chain.
/// That is NOT possible against `ConfidentialUniswapV2Pair` as it exists today (v2-core, untouched
/// by this task), for two independent, verified reasons:
///
///  1. `IConfidentialUniswapV2Pair.swap` only accepts `InEuint64` (a client-attested ciphertext:
///     `{ctHash, securityZone, utype, signature}`), never a raw `euint64` handle. There is no
///     `asInEuint64`-style conversion anywhere in cofhe-contracts' FHE.sol --
///     `InEuint64.signature` can only be produced off-chain (by CoFHE's coprocessor / the mock
///     `MockZkVerifierSigner`), so no on-chain contract (including this router) can synthesize one
///     from a value it computed mid-transaction.
///  2. The mock verifier's `extractSigner(input, sender)` (see the cofhe mock-contracts'
///     MockTaskManager.sol) recovers the signer from
///     `keccak256(ctHash, utype, securityZone, sender, chainid)` where `sender == msg.sender` AT
///     THE MOMENT `FHE.asEuint64(...)` executes. That signature is produced off-chain (see
///     `CofheClient.createEncryptedInput` / `zkVerifySign`) targeting a SPECIFIC `sender` address
///     chosen at encryption time. Concretely: whichever contract's code directly calls
///     `FHE.asEuint64(someInEuint64)` must have `msg.sender` equal to whatever address the ciphertext
///     was encrypted for -- there is no way to "hand off" an already-verified value to a second
///     contract's decode of the SAME struct once the caller identity changes.
///
/// Given the pair's ABI is fixed for this task (v2-periphery only, v2-core is out of scope), the
/// adaptation below still keeps every amount ciphertext end-to-end (FR-R2: no plaintext amount ever
/// appears in calldata/events/state) and still enforces one whole-route all-or-nothing gate (FR-R3),
/// but each hop's `InEuint64` input must be independently produced off-chain (by the caller / a
/// backend quote service, per FR-C6a) TARGETING THIS ROUTER's address as `sender` -- since this
/// router is the direct, sole caller of every pair's `swap()` in the loop below. A production
/// deployment closing this gap cleanly would add a `euint64`-accepting `swap` overload to the pair
/// (mirroring `IFHERC20Minimal`'s existing dual `InEuint64`/`euint64` `confidentialTransferFrom`
/// overloads) -- out of scope here since it requires touching `v2-core`.
///
/// ## All-or-nothing adaptation (FR-R3)
/// Every hop pays out to the router itself (`to = address(this)`), never directly to the end user,
/// so the router stays in custody until the whole route settles. After the last hop, the router
/// diffs its own before/after balance of the final output token (a real balance it always holds
/// read/compute rights on) to get `received`, gates `received >= amountOutMin` into a single `ebool`,
/// and `FHE.select`s the ONE final payout to zero on violation -- exactly the pair's own
/// never-revert clamp pattern, applied once across the whole route instead of per-hop. This means a
/// slippage-violating route leaves the user's own wallet balance unaffected (they receive either the
/// full expected output or nothing), though -- unlike a single pair swap, which refunds the puller
/// directly -- the intermediate hop proceeds remain in router custody rather than being returned to
/// the caller; a real per-hop refund would again require the pair-side change described above.
///
/// ## Commingled-custody guard
/// Because failed routes leave real proceeds parked in the router (previous paragraph), the router
/// can end up holding tokenIn dust it never actually received from the CURRENT caller.
/// `confidentialTransferFrom` never reverts on an under-funded (but operator-authorized, which is
/// permissionless to self-grant) caller once that caller's balance handle is already initialized --
/// FHERC20 clamps the pull to whatever they actually have. Without a further check, a caller could
/// claim (via `hopAmountIns[0]`) to be spending far more tokenIn than they pulled in this tx, and
/// hop 0 would silently draw the difference from whatever tokenIn the router happens to be sitting
/// on from an earlier caller's stranded route -- extracting value they never contributed. The
/// `noCommingledSpend` check below closes this: it requires hop 0 to have consumed no more of the
/// router's tokenIn balance than THIS call's custody pull actually added, folded into the same
/// all-or-nothing `ok` gate.
///
/// Deliberately additive/self-contained: new compilation unit (solc 0.8.25, Foundry) living outside
/// `contracts/` so it never touches the vanilla 0.6.6 Waffle build or `UniswapV2Library`'s
/// init-code-hash constant.
contract ConfidentialUniswapV2Router {
    address public immutable factory;

    constructor(address _factory) {
        factory = _factory;
    }

    /// @notice Swaps an exact amount of `path[0]` for `path[path.length - 1]`, across one or more
    /// hops, entirely in ciphertext.
    /// @dev FR-R4: pulls the caller's input via ERC-7984 `confidentialTransferFrom` -- the caller
    /// must have called `path[0].setOperator(address(this), until)` beforehand. No swap callback.
    /// @param hopAmountIns One `InEuint64` per hop (`path.length - 1` total), each attested for
    /// `sender = address(this)` (this router) -- see the contract docstring for why. `hopAmountIns[0]`
    /// is reused both to pull the caller's real tokens into router custody and as the first pair's
    /// `swap` input (verifying the same ciphertext twice, for two different callees, is valid --
    /// verification is stateless).
    /// @param zeroMinOut A trivially-valued (0) `InEuint64`, also attested for `sender = address(this)`,
    /// reused as every hop's own `minAmountOut` -- intermediate hops never self-clamp on slippage;
    /// the router's own end-to-end gate (below) is what enforces FR-R3.
    /// @param amountOutMin The real minimum final output, attested for `sender = msg.sender` (the
    /// caller) -- decoded directly inside this function (`msg.sender` here IS the caller, so this is
    /// the one value in this call that a standard client-side encryption call can produce with no
    /// special target-contract handling).
    /// @param path Plaintext token addresses (pool identity is public, PRD PR-4).
    /// @param to Final recipient of the (possibly zeroed) output.
    /// @param deadline Plaintext expiry check -- leaks nothing.
    function swapExactTokensForTokens(
        InEuint64[] calldata hopAmountIns,
        InEuint64 calldata zeroMinOut,
        InEuint64 calldata amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (euint64 amountOut) {
        require(block.timestamp <= deadline, "ConfidentialUniswapV2Router: EXPIRED");
        require(path.length >= 2, "ConfidentialUniswapV2Router: INVALID_PATH");
        require(hopAmountIns.length == path.length - 1, "ConfidentialUniswapV2Router: INVALID_HOP_AMOUNTS");

        address tokenIn = path[0];
        address tokenOut = path[path.length - 1];
        euint64 tokenOutBalanceBefore = IFHERC20Minimal(tokenOut).confidentialBalanceOf(address(this));
        // Snapshot the router's PRE-EXISTING tokenIn balance too (e.g. dust stranded by an earlier
        // caller's failed route, see "All-or-nothing adaptation" above) -- used below to make sure
        // this route only ever spends what THIS caller actually pulled in, never anyone else's.
        euint64 tokenInBalanceBeforePull = IFHERC20Minimal(tokenIn).confidentialBalanceOf(address(this));

        // Pull real custody of the first-leg input from the caller (FR-R4). Every pair's `swap`
        // below pulls FROM `msg.sender` (this router), so the router must hold real tokenIn before
        // calling the first hop. `confidentialTransferFrom` never reverts on an under-funded caller
        // (FHERC20 clamps to zero) -- the `tokenInBalanceAfterFirstHop` check below is what actually
        // catches that, not this call's return value.
        IFHERC20Minimal(tokenIn).confidentialTransferFrom(msg.sender, address(this), hopAmountIns[0]);

        euint64 tokenInBalanceAfterFirstHop;
        for (uint256 i = 0; i < hopAmountIns.length; i++) {
            address pairAddr = ConfidentialUniswapV2Library.pairFor(factory, path[i], path[i + 1]);
            (address token0, ) = ConfidentialUniswapV2Library.sortTokens(path[i], path[i + 1]);
            bool zeroForOne = path[i] == token0;
            // The pair's own `swap` pulls its input FROM `msg.sender` (this router) -- authorize it
            // as an operator on the router's own tokenIn balance for this hop before calling it.
            IFHERC20Minimal(path[i]).setOperator(pairAddr, type(uint48).max);
            // Every hop pays out to the router itself -- see "All-or-nothing adaptation" above.
            IConfidentialUniswapV2Pair(pairAddr).swap(hopAmountIns[i], zeroForOne, zeroMinOut, address(this));
            if (i == 0) {
                // tokenIn (path[0]) is only ever spent by hop 0 -- capture the router's tokenIn
                // balance right after it, before any later hop can touch a different token.
                tokenInBalanceAfterFirstHop = IFHERC20Minimal(tokenIn).confidentialBalanceOf(address(this));
            }
        }

        euint64 tokenOutBalanceAfter = IFHERC20Minimal(tokenOut).confidentialBalanceOf(address(this));
        euint64 received = FHE.sub(tokenOutBalanceAfter, tokenOutBalanceBefore);

        // Anti-commingling guard: hop 0 must not have spent more of the router's tokenIn balance
        // than THIS caller actually pulled in above -- i.e. it must never dip into tokenIn dust any
        // earlier caller left stranded in router custody (see "All-or-nothing adaptation").
        ebool noCommingledSpend = FHE.gte(tokenInBalanceAfterFirstHop, tokenInBalanceBeforePull);

        // FR-R3: ONE encrypted comparison gates the entire route's payout to `to`.
        ebool ok = FHE.and(FHE.gte(received, FHE.asEuint64(amountOutMin)), noCommingledSpend);
        euint64 zero = FHE.asEuint64(0);
        amountOut = FHE.select(ok, received, zero);

        FHE.allow(amountOut, tokenOut);
        IFHERC20Minimal(tokenOut).confidentialTransfer(to, amountOut);
    }
}
