// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {DeployHelper} from "./DeployHelper.sol";

import {IUniswapV2Factory06} from "../src/interfaces/IUniswapV2Factory06.sol";
import {IUniswapV2PairMinimal} from "../src/interfaces/IUniswapV2PairMinimal.sol";

import {MockERC20} from "../src/tokens/MockERC20.sol";
import {FeeOnTransferERC20} from "../src/tokens/FeeOnTransferERC20.sol";

import {IERC20Minimal} from "../src/interfaces/IERC20Minimal.sol";

contract FeeOnTransfer_AssumptionBreaker is DeployHelper {
    IUniswapV2Factory06 factory;
    IUniswapV2PairMinimal pair;

    MockERC20 normal;
    FeeOnTransferERC20 feeToken;

    address lp = address(this);
    address trader = address(0xBEEF);

    uint256 constant FEE_BPS = 200; // 2%
    uint256 constant BPS_DENOM = 10_000;

    function setUp() external {
        bytes memory factoryBytecode = _artifact("out/UniV2Factory_0516.sol/UniV2Factory_0516.json");
        address factoryAddr = _deploy(bytes.concat(factoryBytecode, abi.encode(address(this))));
        factory = IUniswapV2Factory06(factoryAddr);

        normal = new MockERC20("Normal", "NORM");
        feeToken = new FeeOnTransferERC20("FeeToken", "FEE", FEE_BPS);

        normal.mint(lp, 1_000_000 ether);
        feeToken.mint(lp, 1_000_000 ether);
        normal.mint(trader, 100_000 ether);
        feeToken.mint(trader, 100_000 ether);

        address pairAddr = factory.createPair(address(feeToken), address(normal));
        pair = IUniswapV2PairMinimal(pairAddr);

        // Liquidity: fee token + normal
        feeToken.transfer(pairAddr, 100_000 ether);
        normal.transfer(pairAddr, 100_000 ether);
        pair.mint(lp);
    }

    // -------- helpers --------

    function _getReservesFor(address tokenIn) internal view returns (uint reserveIn, uint reserveOut) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        if (tokenIn == pair.token0()) {
            reserveIn = uint(r0);
            reserveOut = uint(r1);
        } else {
            reserveIn = uint(r1);
            reserveOut = uint(r0);
        }
    }



function _swapExactOutQuoted(uint256 quotedOut) external {
    // only allow internal test contract to call this
    require(msg.sender == address(this), "only self");

    if (address(feeToken) == pair.token0()) {
        pair.swap(0, quotedOut, trader, "");
    } else {
        pair.swap(quotedOut, 0, trader, "");
    }
}

// -------- helpers --------

function _actualInIfTransfer(uint256 amountIn) internal pure returns (uint256) {
    // fee-on-transfer: amountIn minus fee
    return amountIn - (amountIn * FEE_BPS / BPS_DENOM);
}


    function _getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) internal pure returns (uint amountOut) {
        uint amountInWithFee = amountIn * 997;
        uint numerator = amountInWithFee * reserveOut;
        uint denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    function _pairBalances() internal view returns (uint bal0, uint bal1) {
        bal0 = IERC20Minimal(pair.token0()).balanceOf(address(pair));
        bal1 = IERC20Minimal(pair.token1()).balanceOf(address(pair));
    }


    /// @dev Performs a swap in the "supporting fee-on-transfer" style and returns:
    ///      (actualIn received by pair, amountOut sent to trader)
    function _swapSupportingFeeOnTransfer(uint256 amountIn) internal returns (uint256 actualIn, uint256 amountOut) {
        uint balBefore = normal.balanceOf(trader);

        // 1) transfer input to pair (fee applies here)
        feeToken.transfer(address(pair), amountIn);

        // 2) actualIn = balanceIn - reserveIn
        (uint reserveIn, uint reserveOut) = _getReservesFor(address(feeToken));
        uint balIn = feeToken.balanceOf(address(pair));
        actualIn = balIn - reserveIn;

        // 3) compute output from actualIn
        amountOut = _getAmountOut(actualIn, reserveIn, reserveOut);

        // 4) swap
        if (address(feeToken) == pair.token0()) {
            pair.swap(0, amountOut, trader, "");
        } else {
            pair.swap(amountOut, 0, trader, "");
        }

        uint balAfter = normal.balanceOf(trader);
        uint actualOut = balAfter - balBefore;

        // amountOut is what we asked the pair to send; actualOut should match in this setup
        assertEq(actualOut, amountOut, "unexpected: actualOut != amountOut");
    }

    // -------- tests --------

    function test_fee_math_actualIn_equals_amountIn_minus_fee() external {
        uint256 amountIn = 1_000 ether;

        vm.startPrank(trader);
        (uint reserveIn,) = _getReservesFor(address(feeToken));

        feeToken.transfer(address(pair), amountIn);

        uint balIn = feeToken.balanceOf(address(pair));
        uint actualIn = balIn - reserveIn;

        uint expected = amountIn - (amountIn * FEE_BPS / BPS_DENOM);
        assertEq(actualIn, expected, "actualIn should match fee math");
        vm.stopPrank();
    }

    function test_quote_assumption_breaks_actualOut_is_lower() external {
        uint256 amountIn = 1_000 ether;

        (uint reserveInBefore, uint reserveOutBefore) = _getReservesFor(address(feeToken));
        uint256 quotedOut = _getAmountOut(amountIn, reserveInBefore, reserveOutBefore);

        vm.startPrank(trader);
        (, uint256 amountOut) = _swapSupportingFeeOnTransfer(amountIn);
        vm.stopPrank();

        assertLt(amountOut, quotedOut, "expected actualOut < quote due to fee-on-transfer");
    }

    function test_reserves_update_after_swap_sanity() external {
        uint256 amountIn = 1_000 ether;

        (uint rIn0, uint rOut0) = _getReservesFor(address(feeToken));

        vm.startPrank(trader);
        (uint actualIn, uint amountOut) = _swapSupportingFeeOnTransfer(amountIn);
        vm.stopPrank();

        (uint rIn1, uint rOut1) = _getReservesFor(address(feeToken));

        // input reserve should increase, output reserve should decrease
        assertEq(rIn1, rIn0 + actualIn, "reserveIn did not increase by actualIn");
        assertEq(rOut1, rOut0 - amountOut, "reserveOut did not decrease by amountOut");
    }

    function test_control_no_fee_token_matches_quote() external {
        // Deploy a new zero-fee token & fresh pair as a control group.
        // This is a very strong "audit narrative" test: same swap flow, but without fee.
        MockERC20 noFee = new MockERC20("NoFee", "NOFEE");
        noFee.mint(lp, 1_000_000 ether);
        noFee.mint(trader, 100_000 ether);

        address pair2Addr = factory.createPair(address(noFee), address(normal));
        IUniswapV2PairMinimal pair2 = IUniswapV2PairMinimal(pair2Addr);

        // Add liquidity (no fee token)
        noFee.transfer(pair2Addr, 100_000 ether);
        normal.transfer(pair2Addr, 100_000 ether);
        pair2.mint(lp);

        // Quote vs actual should be much closer (ignoring rounding)
        uint256 amountIn = 1_000 ether;

        // reserves in/out
        (uint112 r0, uint112 r1,) = pair2.getReserves();
        uint reserveIn;
        uint reserveOut;
        if (address(noFee) == pair2.token0()) {
            reserveIn = uint(r0);
            reserveOut = uint(r1);
        } else {
            reserveIn = uint(r1);
            reserveOut = uint(r0);
        }

        uint256 quotedOut = _getAmountOut(amountIn, reserveIn, reserveOut);

        vm.startPrank(trader);

        uint balBefore = normal.balanceOf(trader);
        noFee.transfer(address(pair2), amountIn);

        // actualIn == amountIn because no fee
        uint balIn = noFee.balanceOf(address(pair2));
        uint actualIn = balIn - reserveIn;
        assertEq(actualIn, amountIn, "control: actualIn should equal amountIn");

        uint amountOut = _getAmountOut(actualIn, reserveIn, reserveOut);

        if (address(noFee) == pair2.token0()) {
            pair2.swap(0, amountOut, trader, "");
        } else {
            pair2.swap(amountOut, 0, trader, "");
        }

        uint balAfter = normal.balanceOf(trader);
        uint actualOut = balAfter - balBefore;

        vm.stopPrank();

        // allow tiny rounding differences
        assertApproxEqAbs(actualOut, quotedOut, 2, "control: actualOut should approx equal quotedOut");
    }
function test_donation_to_pair_makes_balance_diff_from_reserves() external {
    // --- Baseline: measure reserves and balances ---
    (uint112 r0Before, uint112 r1Before,) = pair.getReserves();
    (uint b0Before, uint b1Before) = _pairBalances();

    uint gapBefore =
        (b0Before > uint(r0Before) ? b0Before - uint(r0Before) : uint(r0Before) - b0Before) +
        (b1Before > uint(r1Before) ? b1Before - uint(r1Before) : uint(r1Before) - b1Before);

    // --- Donate NORMAL token directly to the pair (avoid fee noise) ---
    normal.transfer(address(pair), 123 ether);

    // --- After donation ---
    (uint112 r0After, uint112 r1After,) = pair.getReserves();
    (uint b0After, uint b1After) = _pairBalances();

    // Reserves must be unchanged (no sync / mint / swap)
    assertEq(uint(r0After), uint(r0Before), "reserve0 should not change on donation");
    assertEq(uint(r1After), uint(r1Before), "reserve1 should not change on donation");

    uint gapAfter =
        (b0After > uint(r0After) ? b0After - uint(r0After) : uint(r0After) - b0After) +
        (b1After > uint(r1After) ? b1After - uint(r1After) : uint(r1After) - b1After);

    // Core security point: donation increased balance/reserve mismatch
    assertGt(gapAfter, gapBefore, "donation should increase balance/reserve mismatch");

    emit log_named_uint("gapBefore", gapBefore);
    emit log_named_uint("gapAfter", gapAfter);
}

function test_naive_swap_using_quotedOut_is_unsafe_or_overly_optimistic() external {
    uint256 amountIn = 1_000 ether;

    // Naive quote assumes full amountIn reaches the pair
    (uint reserveInBefore, uint reserveOutBefore) = _getReservesFor(address(feeToken));
    uint256 quotedOut = _getAmountOut(amountIn, reserveInBefore, reserveOutBefore);

    vm.startPrank(trader);

    // Transfer in (fee applies)
    feeToken.transfer(address(pair), amountIn);

    // Compute actualIn (what pair really received)
    (uint reserveIn, uint reserveOut) = _getReservesFor(address(feeToken));
    uint balIn = feeToken.balanceOf(address(pair));
    uint actualIn = balIn - reserveIn;

    uint256 safeOut = _getAmountOut(actualIn, reserveIn, reserveOut);

    // Deterministic claim:
    // quotedOut is computed from amountIn, safeOut from actualIn.
    // Since actualIn < amountIn, safeOut <= quotedOut (usually strictly less).
    assertLt(safeOut, quotedOut, "safeOut should be < quotedOut due to transfer fee");

    // And if someone *tries* to take quotedOut, it may revert OR it may succeed,
    // but in either case it is an unsafe assumption.
    // We demonstrate it by attempting the swap and just logging the outcome.
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


function test_donation_can_be_extracted_with_skim() external {
    address attacker = address(0xCAFE);

    // Donate normal token to pair
    normal.transfer(address(pair), 123 ether);

    uint beforeBal = normal.balanceOf(attacker);

    // Anyone can skim extra balances
    vm.prank(attacker);
    pair.skim(attacker);

    uint afterBal = normal.balanceOf(attacker);

    assertGt(afterBal, beforeBal, "attacker should receive skimmed tokens");
}

function testFuzz_quote_is_always_over_optimistic_for_fee_on_transfer(uint256 amountIn) external view {
    // keep it in a sane range to avoid overflow + “too small” rounding noise
    amountIn = bound(amountIn, 1e6, 10_000 ether);

    (uint reserveIn, uint reserveOut) = _getReservesFor(address(feeToken));

    // naive quote assumes full amountIn arrives
    uint256 naiveOut = _getAmountOut(amountIn, reserveIn, reserveOut);

    // safe quote uses actualIn (after transfer fee)
    uint256 actualIn = _actualInIfTransfer(amountIn);
    uint256 safeOut = _getAmountOut(actualIn, reserveIn, reserveOut);

    assertGe(naiveOut, safeOut, "naiveOut must be >= safeOut");
}

function test_monotonicity_larger_input_gives_more_output() external view {
    (uint reserveIn, uint reserveOut) = _getReservesFor(address(feeToken));

    uint aIn = 10 ether;
    uint bIn = 100 ether;

    uint aActual = _actualInIfTransfer(aIn);
    uint bActual = _actualInIfTransfer(bIn);

    uint aOut = _getAmountOut(aActual, reserveIn, reserveOut);
    uint bOut = _getAmountOut(bActual, reserveIn, reserveOut);

    assertGt(bOut, aOut, "larger input should give larger output");
}



}
