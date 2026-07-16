// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.25;

import { FHE, euint64, euint128 } from "@fhenixprotocol/cofhe-contracts/FHE.sol";

import { IConfidentialUniswapV2Pair } from "./interfaces/IConfidentialUniswapV2Pair.sol";

/// @title ConfidentialUniswapV2Library
/// @notice Confidential analogue of vanilla `UniswapV2Library`: deterministic pool addressing
/// (CREATE2, no external call) + the pair's exact constant-product math, reusable by the router
/// and by off-chain/backend quoting.
library ConfidentialUniswapV2Library {
    uint256 private constant FEE_NUMERATOR = 997;
    uint256 private constant FEE_DENOMINATOR = 1000;

    /// @dev CREATE2 init-code hash of `ConfidentialUniswapV2Pair` (v2-core `confidential/`, solc
    /// 0.8.25, via_ir=true, code_size_limit=400000), computed via
    /// `forge inspect src/ConfidentialUniswapV2Pair.sol:ConfidentialUniswapV2Pair bytecode | xargs cast keccak`.
    /// Recompute and patch here if that contract (or its compiler/optimizer settings) ever changes --
    /// same failure mode as the vanilla `UniswapV2Library.pairFor` init-code-hash constraint.
    bytes32 internal constant PAIR_INIT_CODE_HASH = 0xbddd7e3b13fcfdd503dbfa9b6f130c4aebb95b364cd7d77becc51237aff76126;

    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, "ConfidentialUniswapV2Library: IDENTICAL_ADDRESSES");
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "ConfidentialUniswapV2Library: ZERO_ADDRESS");
    }

    /// @notice Deterministic pool address for the (tokenA, tokenB) pair, computed purely off the
    /// factory address + sorted tokens + the pair's init-code hash -- no external call, matching
    /// `ConfidentialUniswapV2Factory.createPair`'s create2 salt scheme (FR-R1).
    function pairFor(address factory, address tokenA, address tokenB) internal pure returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(hex"ff", factory, keccak256(abi.encodePacked(token0, token1)), PAIR_INIT_CODE_HASH)
                    )
                )
            )
        );
    }

    /// @notice Encrypted reserves of `pairFor(factory, tokenA, tokenB)`, returned in (reserveA,
    /// reserveB) order matching the (tokenA, tokenB) argument order (not necessarily sorted
    /// token0/token1 order).
    /// @dev Reading these handles does not by itself grant the caller decrypt or compute rights on
    /// them -- the pair only ever ACL-grants itself and its configured backend quote address
    /// (`_allowBackendReserves`). Callers must already hold ACL rights (e.g. the backend service)
    /// to do anything further with the returned handles.
    function getReserves(address factory, address tokenA, address tokenB) internal view returns (euint64 reserveA, euint64 reserveB) {
        (address token0, ) = sortTokens(tokenA, tokenB);
        IConfidentialUniswapV2Pair pair = IConfidentialUniswapV2Pair(pairFor(factory, tokenA, tokenB));
        (euint64 reserve0, euint64 reserve1) = (pair.confidentialReserve0(), pair.confidentialReserve1());
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    /// @notice out = reserveOut * amountInWithFee / (reserveIn + amountInWithFee), 0.3% fee --
    /// matches `ConfidentialUniswapV2Pair.swap`'s math exactly (SR-1: euint128 intermediates, since
    /// a pure-euint64 product overflows at trivial pool sizes).
    function getAmountOut(euint64 amountIn, euint64 reserveIn, euint64 reserveOut) internal returns (euint64 amountOut) {
        euint128 amountIn128 = FHE.asEuint128(amountIn);
        euint128 reserveIn128 = FHE.asEuint128(reserveIn);
        euint128 reserveOut128 = FHE.asEuint128(reserveOut);

        euint128 amountInWithFee = FHE.div(FHE.mul(amountIn128, FHE.asEuint128(FEE_NUMERATOR)), FHE.asEuint128(FEE_DENOMINATOR));
        euint128 numerator = FHE.mul(reserveOut128, amountInWithFee);
        euint128 denominator = FHE.add(reserveIn128, amountInWithFee);
        amountOut = FHE.asEuint64(FHE.div(numerator, denominator));
    }
}
