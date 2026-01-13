// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {DeployHelper} from "./DeployHelper.sol";

import {IUniswapV2Factory06} from "../src/interfaces/IUniswapV2Factory06.sol";
import {IUniswapV2PairMinimal} from "../src/interfaces/IUniswapV2PairMinimal.sol";

import {MockERC20} from "../src/tokens/MockERC20.sol";
import {FeeOnTransferERC20} from "../src/tokens/FeeOnTransferERC20.sol";

contract FeeOnTransfer_AssumptionBreaker is DeployHelper {
    IUniswapV2Factory06 factory;
    IUniswapV2PairMinimal pair;

    MockERC20 normal;
    FeeOnTransferERC20 feeToken;

    address lp = address(this);
    address trader = address(0xBEEF);

    function setUp() external {
        // Deploy Factory (0.5.16 wrapper artifact)
        bytes memory factoryBytecode = _artifact("out/UniV2Factory_0516.sol/UniV2Factory_0516.json");
        address factoryAddr = _deploy(bytes.concat(factoryBytecode, abi.encode(address(this))));
        factory = IUniswapV2Factory06(factoryAddr);

        // Deploy tokens (0.8.20)
        normal = new MockERC20("Normal", "NORM");
        feeToken = new FeeOnTransferERC20("FeeToken", "FEE", 200); // 2% (200 bps)

        // Mint balances
        normal.mint(lp, 1_000_000 ether);
        feeToken.mint(lp, 1_000_000 ether);
        normal.mint(trader, 100_000 ether);
        feeToken.mint(trader, 100_000 ether);

        // Create pair
        address pairAddr = factory.createPair(address(feeToken), address(normal));
        pair = IUniswapV2PairMinimal(pairAddr);

        // Add liquidity manually (token transfers -> pair -> mint)
        // Note: feeToken transfer reduces the amount actually received by the pair
        feeToken.transfer(pairAddr, 100_000 ether);
        normal.transfer(pairAddr, 100_000 ether);
        pair.mint(lp);
    }

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

    function _getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) internal pure returns (uint amountOut) {
        // Uniswap V2: amountOut = (amountIn*997*reserveOut) / (reserveIn*1000 + amountIn*997)
        uint amountInWithFee = amountIn * 997;
        uint numerator = amountInWithFee * reserveOut;
        uint denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    function test_fee_on_transfer_breaks_quote_vs_actual() external {
        uint256 amountIn = 1_000 ether;

        // "Quote" assumes full amountIn reaches the pair
        (uint reserveInBefore, uint reserveOutBefore) = _getReservesFor(address(feeToken));
        uint256 quotedOut = _getAmountOut(amountIn, reserveInBefore, reserveOutBefore);

        vm.startPrank(trader);

        uint balBefore = normal.balanceOf(trader);

        // 1) fee-on-transfer token in
        feeToken.transfer(address(pair), amountIn);

        // 2) compute actualIn = balanceIn - reserveIn (supporting-fee style)
        (uint reserveIn, uint reserveOut) = _getReservesFor(address(feeToken));
        uint balIn = feeToken.balanceOf(address(pair));
        uint actualIn = balIn - reserveIn;

        // extra assertion: verify fee math (2% of amountIn)
        uint expectedActualIn = amountIn - (amountIn * 200 / 10_000);
        assertEq(actualIn, expectedActualIn, "actualIn should equal amountIn minus transfer fee");

        // 3) output from actualIn
        uint amountOut = _getAmountOut(actualIn, reserveIn, reserveOut);

        // 4) swap direction depends on token0/token1 ordering
        if (address(feeToken) == pair.token0()) {
            pair.swap(0, amountOut, trader, "");
        } else {
            pair.swap(amountOut, 0, trader, "");
        }

        uint balAfter = normal.balanceOf(trader);
        uint actualOut = balAfter - balBefore;

        vm.stopPrank();

        // Core point: actualOut < quotedOut because actualIn < amountIn
        assertLt(actualOut, quotedOut, "expected actualOut < quotedOut due to transfer fee");

        emit log_named_uint("amountIn (intended)", amountIn);
        emit log_named_uint("actualIn (pair received)", actualIn);
        emit log_named_uint("quotedOut (assumes no fee)", quotedOut);
        emit log_named_uint("actualOut", actualOut);
    }
}
