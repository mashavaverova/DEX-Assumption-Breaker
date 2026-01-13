// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {DeployHelper} from "./DeployHelper.sol";

import {IUniswapV2Factory06} from "../src/interfaces/IUniswapV2Factory06.sol";
import {IUniswapV2PairMinimal} from "../src/interfaces/IUniswapV2PairMinimal.sol";

import {IERC20Minimal} from "../src/interfaces/IERC20Minimal.sol";

import {MockERC20} from "../src/tokens/MockERC20.sol";
import {FeeOnTransferERC20} from "../src/tokens/FeeOnTransferERC20.sol";

/// @title FeeOnTransfer_AssumptionBreaker
/// @notice Security lab: shows why "quotes" and "exact-out" assumptions break for fee-on-transfer tokens,
///         and why Uniswap V2 accounting (reserves) can differ from ERC20 balances (donations / skim / sync).
contract FeeOnTransfer_AssumptionBreaker is DeployHelper {
    // =============================================================
    //                         CONFIG
    // =============================================================

    uint256 internal constant FEE_BPS = 200; // 2%
    uint256 internal constant BPS_DENOM = 10_000;

    // =============================================================
    //                      TEST FIXTURES
    // =============================================================

    IUniswapV2Factory06 internal factory;
    IUniswapV2PairMinimal internal pair;

    MockERC20 internal normal;
    FeeOnTransferERC20 internal feeToken;

    address internal lp = address(this);
    address internal trader = address(0xBEEF);

    // =============================================================
    //                          SETUP
    // =============================================================

    function setUp() external {
        // Deploy Factory (0.5.16 wrapper artifact)
        bytes memory factoryBytecode = _artifact("out/UniV2Factory_0516.sol/UniV2Factory_0516.json");
        address factoryAddr = _deploy(bytes.concat(factoryBytecode, abi.encode(address(this))));
        factory = IUniswapV2Factory06(factoryAddr);

        // Deploy tokens (0.8.20)
        normal = new MockERC20("Normal", "NORM");
        feeToken = new FeeOnTransferERC20("FeeToken", "FEE", FEE_BPS);

        // Mint balances
        normal.mint(lp, 1_000_000 ether);
        feeToken.mint(lp, 1_000_000 ether);
        normal.mint(trader, 100_000 ether);
        feeToken.mint(trader, 100_000 ether);

        // Create pair and seed liquidity (fee applies on feeToken transfer)
        address pairAddr = factory.createPair(address(feeToken), address(normal));
        pair = IUniswapV2PairMinimal(pairAddr);

        feeToken.transfer(pairAddr, 100_000 ether);
        normal.transfer(pairAddr, 100_000 ether);
        pair.mint(lp);
    }

    // =============================================================
    //                          HELPERS
    // =============================================================

    /// @dev Reserves from the perspective of tokenIn -> tokenOut (based on token0 ordering).
    function _getReservesFor(address tokenIn) internal view returns (uint256 reserveIn, uint256 reserveOut) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        if (tokenIn == pair.token0()) {
            reserveIn = uint256(r0);
            reserveOut = uint256(r1);
        } else {
            reserveIn = uint256(r1);
            reserveOut = uint256(r0);
        }
    }

    /// @dev Uniswap V2 amountOut math (0.3% fee): amountOut = (amountIn*997*reserveOut) / (reserveIn*1000 + amountIn*997)
    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountOut)
    {
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    /// @dev Reads ERC20 balances for token0/token1 held by the pair.
    function _pairBalances() internal view returns (uint256 bal0, uint256 bal1) {
        bal0 = IERC20Minimal(pair.token0()).balanceOf(address(pair));
        bal1 = IERC20Minimal(pair.token1()).balanceOf(address(pair));
    }

    /// @dev Fee-on-transfer: how much the pair should receive after the fee is taken.
    function _actualInIfTransfer(uint256 amountIn) internal pure returns (uint256) {
        return amountIn - (amountIn * FEE_BPS / BPS_DENOM);
    }

    /// @dev Performs a swap in the "supporting fee-on-transfer" style and returns:
    ///      (actualIn received by pair, amountOut sent to trader).
    function _swapSupportingFeeOnTransfer(uint256 amountIn) internal returns (uint256 actualIn, uint256 amountOut) {
        uint256 balBefore = normal.balanceOf(trader);

        // 1) transfer input to pair (fee applies here)
        feeToken.transfer(address(pair), amountIn);

        // 2) actualIn = balanceIn - reserveIn
        (uint256 reserveIn, uint256 reserveOut) = _getReservesFor(address(feeToken));
        uint256 balIn = feeToken.balanceOf(address(pair));
        actualIn = balIn - reserveIn;

        // 3) compute output from actualIn
        amountOut = _getAmountOut(actualIn, reserveIn, reserveOut);

        // 4) swap (direction depends on token0 ordering)
        if (address(feeToken) == pair.token0()) {
            pair.swap(0, amountOut, trader, "");
        } else {
            pair.swap(amountOut, 0, trader, "");
        }

        // sanity: output actually arrived
        uint256 balAfter = normal.balanceOf(trader);
        uint256 actualOut = balAfter - balBefore;
        assertEq(actualOut, amountOut, "unexpected: actualOut != amountOut");
    }

    /// @dev External wrapper so we can try/catch a "take quotedOut" swap attempt.
    function _swapExactOutQuoted(uint256 quotedOut) external {
        require(msg.sender == address(this), "only self");

        if (address(feeToken) == pair.token0()) {
            pair.swap(0, quotedOut, trader, "");
        } else {
            pair.swap(quotedOut, 0, trader, "");
        }
    }

    // =============================================================
    //                        TESTS: FEES
    // =============================================================

    function test_fee_math_actualIn_equals_amountIn_minus_fee() external {
        uint256 amountIn = 1_000 ether;

        vm.startPrank(trader);

        (uint256 reserveIn,) = _getReservesFor(address(feeToken));

        feeToken.transfer(address(pair), amountIn);

        uint256 balIn = feeToken.balanceOf(address(pair));
        uint256 actualIn = balIn - reserveIn;

        uint256 expected = _actualInIfTransfer(amountIn);
        assertEq(actualIn, expected, "actualIn should match fee math");

        vm.stopPrank();
    }

    function test_quote_assumption_breaks_actualOut_is_lower() external {
        uint256 amountIn = 1_000 ether;

        (uint256 reserveInBefore, uint256 reserveOutBefore) = _getReservesFor(address(feeToken));
        uint256 quotedOut = _getAmountOut(amountIn, reserveInBefore, reserveOutBefore);

        vm.startPrank(trader);
        (, uint256 actualOut) = _swapSupportingFeeOnTransfer(amountIn);
        vm.stopPrank();

        assertLt(actualOut, quotedOut, "expected actualOut < quote due to fee-on-transfer");
    }

    function test_reserves_update_after_swap_sanity() external {
        uint256 amountIn = 1_000 ether;

        (uint256 rIn0, uint256 rOut0) = _getReservesFor(address(feeToken));

        vm.startPrank(trader);
        (uint256 actualIn, uint256 amountOut) = _swapSupportingFeeOnTransfer(amountIn);
        vm.stopPrank();

        (uint256 rIn1, uint256 rOut1) = _getReservesFor(address(feeToken));

        assertEq(rIn1, rIn0 + actualIn, "reserveIn did not increase by actualIn");
        assertEq(rOut1, rOut0 - amountOut, "reserveOut did not decrease by amountOut");
    }

    // =============================================================
    //                   TESTS: CONTROL GROUP
    // =============================================================

    function test_control_no_fee_token_matches_quote() external {
        MockERC20 noFee = new MockERC20("NoFee", "NOFEE");
        noFee.mint(lp, 1_000_000 ether);
        noFee.mint(trader, 100_000 ether);

        address pair2Addr = factory.createPair(address(noFee), address(normal));
        IUniswapV2PairMinimal pair2 = IUniswapV2PairMinimal(pair2Addr);

        noFee.transfer(pair2Addr, 100_000 ether);
        normal.transfer(pair2Addr, 100_000 ether);
        pair2.mint(lp);

        uint256 amountIn = 1_000 ether;

        (uint112 r0, uint112 r1,) = pair2.getReserves();
        uint256 reserveIn;
        uint256 reserveOut;
        if (address(noFee) == pair2.token0()) {
            reserveIn = uint256(r0);
            reserveOut = uint256(r1);
        } else {
            reserveIn = uint256(r1);
            reserveOut = uint256(r0);
        }

        uint256 quotedOut = _getAmountOut(amountIn, reserveIn, reserveOut);

        vm.startPrank(trader);

        uint256 balBefore = normal.balanceOf(trader);

        noFee.transfer(address(pair2), amountIn);

        uint256 balIn = noFee.balanceOf(address(pair2));
        uint256 actualIn = balIn - reserveIn;
        assertEq(actualIn, amountIn, "control: actualIn should equal amountIn");

        uint256 amountOut = _getAmountOut(actualIn, reserveIn, reserveOut);

        if (address(noFee) == pair2.token0()) {
            pair2.swap(0, amountOut, trader, "");
        } else {
            pair2.swap(amountOut, 0, trader, "");
        }

        uint256 balAfter = normal.balanceOf(trader);
        uint256 actualOut = balAfter - balBefore;

        vm.stopPrank();

        assertApproxEqAbs(actualOut, quotedOut, 2, "control: actualOut should approx equal quotedOut");
    }

    // =============================================================
    //                 TESTS: BALANCE vs RESERVES
    // =============================================================

    function test_donation_to_pair_makes_balance_diff_from_reserves() external {
        (uint112 r0Before, uint112 r1Before,) = pair.getReserves();
        (uint256 b0Before, uint256 b1Before) = _pairBalances();

        uint256 gapBefore = (b0Before > uint256(r0Before) ? b0Before - uint256(r0Before) : uint256(r0Before) - b0Before)
            + (b1Before > uint256(r1Before) ? b1Before - uint256(r1Before) : uint256(r1Before) - b1Before);

        // donate NORMAL token (avoid fee noise)
        normal.transfer(address(pair), 123 ether);

        (uint112 r0After, uint112 r1After,) = pair.getReserves();
        (uint256 b0After, uint256 b1After) = _pairBalances();

        // reserves unchanged after a plain transfer
        assertEq(uint256(r0After), uint256(r0Before), "reserve0 should not change on donation");
        assertEq(uint256(r1After), uint256(r1Before), "reserve1 should not change on donation");

        uint256 gapAfter = (b0After > uint256(r0After) ? b0After - uint256(r0After) : uint256(r0After) - b0After)
            + (b1After > uint256(r1After) ? b1After - uint256(r1After) : uint256(r1After) - b1After);

        assertGt(gapAfter, gapBefore, "donation should increase balance/reserve mismatch");

        emit log_named_uint("gapBefore", gapBefore);
        emit log_named_uint("gapAfter", gapAfter);
    }

    function test_donation_can_be_extracted_with_skim() external {
        address attacker = address(0xCAFE);

        normal.transfer(address(pair), 123 ether);

        uint256 beforeBal = normal.balanceOf(attacker);

        vm.prank(attacker);
        pair.skim(attacker);

        uint256 afterBal = normal.balanceOf(attacker);

        assertGt(afterBal, beforeBal, "attacker should receive skimmed tokens");
    }

    // =============================================================
    //             TESTS: "NAIVE EXACT-OUT" ASSUMPTION
    // =============================================================

    function test_naive_swap_using_quotedOut_is_unsafe_or_overly_optimistic() external {
        uint256 amountIn = 1_000 ether;

        // naive quote assumes full amountIn reaches the pair
        (uint256 reserveInBefore, uint256 reserveOutBefore) = _getReservesFor(address(feeToken));
        uint256 quotedOut = _getAmountOut(amountIn, reserveInBefore, reserveOutBefore);

        vm.startPrank(trader);

        // transfer in (fee applies)
        feeToken.transfer(address(pair), amountIn);

        // actualIn (what pair really received)
        (uint256 reserveIn, uint256 reserveOut) = _getReservesFor(address(feeToken));
        uint256 balIn = feeToken.balanceOf(address(pair));
        uint256 actualIn = balIn - reserveIn;

        // "safe" bound computed from actualIn
        uint256 safeOut = _getAmountOut(actualIn, reserveIn, reserveOut);
        assertLt(safeOut, quotedOut, "safeOut should be < quotedOut due to transfer fee");

        // Try to take quotedOut: might revert or succeed; either outcome shows it's an unsafe assumption.
        bool reverted;
        try this._swapExactOutQuoted(quotedOut) {
            reverted = false;
        } catch {
            reverted = true;
        }

        emit log_named_uint("amountIn intended", amountIn);
        emit log_named_uint("actualIn received", actualIn);
        emit log_named_uint("quotedOut (naive)", quotedOut);
        emit log_named_uint("safeOut (actualIn)", safeOut);
        emit log_named_uint("naive swap reverted? 1=yes 0=no", reverted ? 1 : 0);

        vm.stopPrank();
    }

    // =============================================================
    //                    TESTS: PROPERTIES
    // =============================================================

    function testFuzz_quote_is_always_over_optimistic_for_fee_on_transfer(uint256 amountIn) external view {
        amountIn = bound(amountIn, 1e6, 10_000 ether);

        (uint256 reserveIn, uint256 reserveOut) = _getReservesFor(address(feeToken));

        uint256 naiveOut = _getAmountOut(amountIn, reserveIn, reserveOut);

        uint256 actualIn = _actualInIfTransfer(amountIn);
        uint256 safeOut = _getAmountOut(actualIn, reserveIn, reserveOut);

        assertGe(naiveOut, safeOut, "naiveOut must be >= safeOut");
    }

    function test_monotonicity_larger_input_gives_more_output() external view {
        (uint256 reserveIn, uint256 reserveOut) = _getReservesFor(address(feeToken));

        uint256 aIn = 10 ether;
        uint256 bIn = 100 ether;

        uint256 aActual = _actualInIfTransfer(aIn);
        uint256 bActual = _actualInIfTransfer(bIn);

        uint256 aOut = _getAmountOut(aActual, reserveIn, reserveOut);
        uint256 bOut = _getAmountOut(bActual, reserveIn, reserveOut);

        assertGt(bOut, aOut, "larger input should give larger output");
    }
}
