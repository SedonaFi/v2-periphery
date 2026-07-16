// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.25;

import { CofheTest } from "@cofhe/foundry-plugin/contracts/CofheTest.sol";
import { CofheClient } from "@cofhe/foundry-plugin/contracts/CofheClient.sol";
import { InEuint64, euint64, EncryptedInput, Utils } from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import { Vm } from "forge-std/Vm.sol";

import { ConfidentialUniswapV2Factory } from "../src/test/fixtures/ConfidentialUniswapV2Factory.sol";
import { ConfidentialUniswapV2Pair } from "../src/ConfidentialUniswapV2Pair.sol";
import { MockFHERC20 } from "../src/test/MockFHERC20.sol";
import { ConfidentialUniswapV2Router } from "../src/ConfidentialUniswapV2Router.sol";
import { ConfidentialUniswapV2Library } from "../src/ConfidentialUniswapV2Library.sol";

/// @notice Verifies the router against the REAL `ConfidentialUniswapV2Pair`/`Factory` (vendored,
/// byte-identical copies of v2-core's committed sources -- see `src/test/fixtures/`), including
/// that `ConfidentialUniswapV2Library.pairFor`'s hardcoded init-code hash resolves to the actual
/// deployed pair address.
contract ConfidentialUniswapV2RouterTest is CofheTest {
    uint256 constant LP_PKEY = 0xA11CE;
    uint256 constant TRADER_PKEY = 0xB0B;
    uint256 constant BACKEND_PKEY = 0xBEE5;

    CofheClient lp;
    CofheClient trader;
    CofheClient backend;

    MockFHERC20 tokenA;
    MockFHERC20 tokenB;
    MockFHERC20 tokenC;

    ConfidentialUniswapV2Factory factory;
    ConfidentialUniswapV2Router router;

    address pairAB;
    address pairBC;

    function setUp() public {
        deployMocks();

        lp = createCofheClient();
        lp.connect(LP_PKEY);
        trader = createCofheClient();
        trader.connect(TRADER_PKEY);
        backend = createCofheClient();
        backend.connect(BACKEND_PKEY);

        tokenA = new MockFHERC20("Token A", "TKA");
        tokenB = new MockFHERC20("Token B", "TKB");
        tokenC = new MockFHERC20("Token C", "TKC");

        factory = new ConfidentialUniswapV2Factory(backend.account());
        router = new ConfidentialUniswapV2Router(address(factory));

        pairAB = factory.createPair(address(tokenA), address(tokenB));
        pairBC = factory.createPair(address(tokenB), address(tokenC));

        _seedPool(pairAB, tokenA, tokenB, 1_000_000e6, 1_000_000e6);
        _seedPool(pairBC, tokenB, tokenC, 1_000_000e6, 1_000_000e6);

        tokenA.mint(trader.account(), 10_000e6);

        // FR-R4: trader authorizes the ROUTER (not the pairs) as operator on the input token, so
        // the router can pull real custody of it (`confidentialTransferFrom(trader, router, ...)`).
        // The router authorizes each pair as its own operator internally, per hop (see
        // `swapExactTokensForTokens`).
        address traderAddr = trader.account();
        vm.prank(traderAddr);
        tokenA.setOperator(address(router), type(uint48).max);
    }

    function _seedPool(address pairAddr, MockFHERC20 t0Unsorted, MockFHERC20 t1Unsorted, uint64 amt0, uint64 amt1) internal {
        ConfidentialUniswapV2Pair pair = ConfidentialUniswapV2Pair(pairAddr);
        (address token0Addr, ) = ConfidentialUniswapV2Library.sortTokens(address(t0Unsorted), address(t1Unsorted));
        MockFHERC20 token0 = MockFHERC20(token0Addr);
        MockFHERC20 token1 = token0Addr == address(t0Unsorted) ? t1Unsorted : t0Unsorted;

        token0.mint(lp.account(), amt0);
        token1.mint(lp.account(), amt1);

        address lpAddr = lp.account();
        vm.prank(lpAddr);
        token0.setOperator(pairAddr, type(uint48).max);
        vm.prank(lpAddr);
        token1.setOperator(pairAddr, type(uint48).max);

        InEuint64 memory seed0 = lp.createInEuint64(amt0);
        InEuint64 memory seed1 = lp.createInEuint64(amt1);
        vm.prank(lpAddr);
        pair.mint(seed0, seed1, lpAddr);
    }

    /// @dev Builds an `InEuint64` attested for an ARBITRARY `sender` (not necessarily the connected
    /// CofheClient's own account) -- needed because every hop's amount must be attested for
    /// `sender = address(router)` (the router is the direct caller of each pair's `swap`), which
    /// `CofheClient.createInEuint64` cannot produce (it always targets its own connected account).
    /// Uses the same low-level mock primitives `CofheClient.createEncryptedInput` calls internally.
    function _createInEuint64For(uint64 value, address sender) internal returns (InEuint64 memory) {
        EncryptedInput memory input = mockZkVerifier.zkVerify(uint256(value), Utils.EUINT64_TFHE, sender, 0, block.chainid);
        input = mockZkVerifierSigner.zkVerifySign(input, sender);
        return abi.decode(abi.encode(input), (InEuint64));
    }

    function _quote(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        uint256 amountInWithFee = (amountIn * 997) / 1000;
        return (reserveOut * amountInWithFee) / (reserveIn + amountInWithFee);
    }

    /// @notice FR-R1: `ConfidentialUniswapV2Library.pairFor`'s hardcoded init-code hash resolves to
    /// the REAL deployed pair address for both pools.
    function test_pairFor_matchesDeployedPairAddress() public view {
        address computedAB = ConfidentialUniswapV2Library.pairFor(address(factory), address(tokenA), address(tokenB));
        address computedBC = ConfidentialUniswapV2Library.pairFor(address(factory), address(tokenB), address(tokenC));
        assertEq(computedAB, pairAB, "pairFor(A,B) != actual deployed pair");
        assertEq(computedBC, pairBC, "pairFor(B,C) != actual deployed pair");
    }

    /// @notice Single-hop swap (A -> B) executes against the real pair, resolved purely via
    /// `pairFor`, and the output matches the pair's own constant-product math.
    function test_singleHopSwap_hitsRealPairAtComputedAddress() public {
        uint64 swapAmount = 1_000e6;
        address traderAddr = trader.account();

        InEuint64[] memory hopAmountIns = new InEuint64[](1);
        hopAmountIns[0] = _createInEuint64For(swapAmount, address(router));
        InEuint64 memory zeroMinOut = _createInEuint64For(0, address(router));
        InEuint64 memory amountOutMin = trader.createInEuint64(0);

        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        vm.recordLogs();
        vm.prank(traderAddr);
        euint64 out = router.swapExactTokensForTokens(hopAmountIns, zeroMinOut, amountOutMin, path, traderAddr, block.timestamp);

        uint256 expectedOut = _quote(swapAmount, 1_000_000e6, 1_000_000e6);
        expectPlaintext(out, uint64(expectedOut));
        expectPlaintext(tokenB.confidentialBalanceOf(traderAddr), uint64(expectedOut));

        // Plaintext swap amount never appears in any emitted event's data.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertFalse(_bytesContainUint64(logs[i].data, swapAmount), "plaintext swap amount leaked into an event");
        }
    }

    /// @notice Multi-hop swap (A -> B -> C) executes against both real pools, resolved via
    /// `pairFor`, chaining the router's own custody between hops. The intermediate B amount is
    /// never emitted or decoded in plaintext.
    function test_multiHopSwap_twoHops_privateIntermediateAmount() public {
        uint64 swapAmount = 1_000e6;
        address traderAddr = trader.account();

        uint256 expectedB = _quote(swapAmount, 1_000_000e6, 1_000_000e6);
        uint256 expectedC = _quote(expectedB, 1_000_000e6, 1_000_000e6);

        InEuint64[] memory hopAmountIns = new InEuint64[](2);
        hopAmountIns[0] = _createInEuint64For(swapAmount, address(router));
        hopAmountIns[1] = _createInEuint64For(uint64(expectedB), address(router));
        InEuint64 memory zeroMinOut = _createInEuint64For(0, address(router));
        InEuint64 memory amountOutMin = trader.createInEuint64(0);

        address[] memory path = new address[](3);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        path[2] = address(tokenC);

        vm.recordLogs();
        vm.prank(traderAddr);
        euint64 out = router.swapExactTokensForTokens(hopAmountIns, zeroMinOut, amountOutMin, path, traderAddr, block.timestamp);

        expectPlaintext(out, uint64(expectedC));
        expectPlaintext(tokenC.confidentialBalanceOf(traderAddr), uint64(expectedC));
        // No intermediate tokenB balance stranded with the trader -- it only ever sat in the
        // router. Trader's tokenB balance handle was never touched (no ConfidentialTransfer ever
        // named trader), so it's the raw uninitialized (zero) handle -- not a registered mock
        // ciphertext `expectPlaintext` can decode -- assert the raw handle directly instead.
        assertEq(euint64.unwrap(tokenB.confidentialBalanceOf(traderAddr)), 0, "trader unexpectedly holds tokenB");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertFalse(_bytesContainUint64(logs[i].data, swapAmount), "plaintext amountIn leaked into an event");
            assertFalse(_bytesContainUint64(logs[i].data, uint64(expectedB)), "plaintext intermediate amount leaked into an event");
        }
    }

    /// @notice FR-R3 all-or-nothing: a multi-hop route that would under-deliver vs `amountOutMin`
    /// zeroes the ENTIRE route's payout to the user -- not a partial amount, and no intermediate
    /// token (tokenB) is ever left with the user either.
    function test_multiHopSwap_slippageViolation_zeroesEntireRoute() public {
        uint64 swapAmount = 1_000e6;
        address traderAddr = trader.account();

        uint256 expectedB = _quote(swapAmount, 1_000_000e6, 1_000_000e6);
        uint256 expectedC = _quote(expectedB, 1_000_000e6, 1_000_000e6);
        uint64 impossibleMin = uint64(expectedC) * 100;

        InEuint64[] memory hopAmountIns = new InEuint64[](2);
        hopAmountIns[0] = _createInEuint64For(swapAmount, address(router));
        hopAmountIns[1] = _createInEuint64For(uint64(expectedB), address(router));
        InEuint64 memory zeroMinOut = _createInEuint64For(0, address(router));
        InEuint64 memory amountOutMin = trader.createInEuint64(impossibleMin);

        address[] memory path = new address[](3);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        path[2] = address(tokenC);

        vm.prank(traderAddr);
        euint64 out = router.swapExactTokensForTokens(hopAmountIns, zeroMinOut, amountOutMin, path, traderAddr, block.timestamp);

        // User receives nothing on the output leg...
        expectPlaintext(out, uint64(0));
        expectPlaintext(tokenC.confidentialBalanceOf(traderAddr), uint64(0));
        // ...and nothing stranded on the intermediate leg either (it stayed in router custody).
        // Trader's tokenB balance handle was never touched (see note in the two-hop success test).
        assertEq(euint64.unwrap(tokenB.confidentialBalanceOf(traderAddr)), 0, "trader unexpectedly holds tokenB");
        // The route's real proceeds ended up in the router (documented limitation -- see contract
        // docstring's "All-or-nothing adaptation": true per-hop refund needs a pair-side change).
        expectPlaintext(tokenC.confidentialBalanceOf(address(router)), uint64(expectedC));
    }

    /// @notice Regression test for a commingled-custody theft vector: `confidentialTransferFrom`
    /// never reverts on an under-funded caller with an already-initialized balance handle (FHERC20
    /// clamps the pull to whatever the caller actually has), so an attacker who merely
    /// self-authorizes the router as their own operator (permissionless) and holds only a tiny real
    /// tokenA balance could otherwise ride on tokenA the router happens to have stranded from an
    /// earlier caller's failed/slippage-violating route (see
    /// `test_multiHopSwap_slippageViolation_zeroesEntireRoute`). The router's `noCommingledSpend`
    /// guard must zero the attacker's entire payout instead of letting them extract value from
    /// tokens they never actually contributed.
    function test_singleHopSwap_underfundedAttacker_cannotSpendStrandedRouterFunds() public {
        // Stage stranded router custody, exactly like a prior failed route would leave behind.
        uint64 strandedAmount = 5_000e6;
        tokenA.mint(address(router), strandedAmount);

        address attackerAddr = vm.addr(0xDEAD);
        // A trivial real balance (NOT the stranded amount) -- just enough to have an initialized
        // FHERC20 balance handle, so the under-funded pull clamps silently instead of reverting on
        // an uninitialized-balance check.
        uint64 attackerRealBalance = 1e6;
        tokenA.mint(attackerAddr, attackerRealBalance);
        // Permissionless self-authorization -- costs the attacker nothing.
        vm.prank(attackerAddr);
        tokenA.setOperator(address(router), type(uint48).max);

        InEuint64[] memory hopAmountIns = new InEuint64[](1);
        // Attacker claims to be pulling in the FULL stranded amount, despite holding far less.
        hopAmountIns[0] = _createInEuint64For(strandedAmount, address(router));
        InEuint64 memory zeroMinOut = _createInEuint64For(0, address(router));
        InEuint64 memory amountOutMin = _createInEuint64For(0, attackerAddr);

        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        vm.prank(attackerAddr);
        euint64 out = router.swapExactTokensForTokens(hopAmountIns, zeroMinOut, amountOutMin, path, attackerAddr, block.timestamp);

        // Attacker gets nothing -- the all-or-nothing gate catches the commingled spend. (Their
        // tokenB balance handle IS a real, registered ciphertext -- the `confidentialTransfer` call
        // did execute, just with a `FHE.select`-zeroed amount -- so this checks decrypted value,
        // not raw-handle identity; see the raw-handle checks elsewhere for genuinely untouched
        // balances.)
        expectPlaintext(out, uint64(0));
        expectPlaintext(tokenB.confidentialBalanceOf(attackerAddr), uint64(0));
    }

    function _bytesContainUint64(bytes memory haystack, uint64 needle) internal pure returns (bool) {
        if (needle == 0 || haystack.length < 32) return false;
        bytes32 word = bytes32(uint256(needle));
        for (uint256 i = 0; i + 32 <= haystack.length; i++) {
            bytes32 chunk;
            assembly {
                chunk := mload(add(add(haystack, 32), i))
            }
            if (chunk == word) return true;
        }
        return false;
    }
}
