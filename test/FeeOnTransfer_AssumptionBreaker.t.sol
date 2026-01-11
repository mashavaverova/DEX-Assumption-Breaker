// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {DeployHelper} from "./DeployHelper.sol";

import {IUniswapV2Factory06} from "../src/interfaces/IUniswapV2Factory06.sol";
import {IUniswapV2Router02_066} from "../src/interfaces/IUniswapV2Router02_066.sol";
import {IWETH9_066} from "../src/interfaces/IWETH9_066.sol";

import {MockERC20} from "../src/tokens/MockERC20.sol";
import {FeeOnTransferERC20} from "../src/tokens/FeeOnTransferERC20.sol";

contract FeeOnTransfer_AssumptionBreaker is DeployHelper {
    IUniswapV2Factory06 factory;
    IUniswapV2Router02_066 router;
    IWETH9_066 weth;

    MockERC20 normal;
    FeeOnTransferERC20 feeToken;

    address lp = address(this);
    address trader = address(0xBEEF);

    function setUp() external {
        // 1) Factory (0.5.16) constructor: (address feeToSetter)
bytes memory factoryBytecode = _artifact("out/UniV2Factory_0516.sol/UniV2Factory_0516.json");
        address factoryAddr = _deploy(bytes.concat(factoryBytecode, abi.encode(address(this))));
        factory = IUniswapV2Factory06(factoryAddr);
emit log_string("A: factory deployed");

        // 2) WETH9 (0.6.6) no constructor args
bytes memory wethBytecode    = _artifact("out/WETH9_066.sol/WETH9_066.json");
        address wethAddr = _deploy(wethBytecode);
        weth = IWETH9_066(wethAddr);
emit log_string("B: WETH deployed");

        // 3) Router02 (0.6.6) constructor: (address factory, address WETH)
bytes memory routerBytecode  = _artifact("out/UniV2Router02_066.sol/UniV2Router02_066.json");
        address routerAddr = _deploy(bytes.concat(routerBytecode, abi.encode(factoryAddr, wethAddr)));
        router = IUniswapV2Router02_066(routerAddr);
emit log_string("C: router deployed");

        // Tokens (0.8.20)
        normal = new MockERC20("Normal", "NORM");
        feeToken = new FeeOnTransferERC20("FeeToken", "FEE", 200); // 2%
emit log_string("D: tokens deployed");

        // Mint balances
        normal.mint(lp, 1_000_000 ether);
        feeToken.mint(lp, 1_000_000 ether);
        normal.mint(trader, 100_000 ether);
        feeToken.mint(trader, 100_000 ether);
emit log_string("E: tokens minted");

        // LP approves router
        normal.approve(routerAddr, type(uint256).max);
        feeToken.approve(routerAddr, type(uint256).max);
emit log_string("F: router approved");

        // Add liquidity
emit log_string("G: addLiquidity start");
try router.addLiquidity(
    address(feeToken),
    address(normal),
    100_000 ether,
    100_000 ether,
    0,
    0,
    lp,
    block.timestamp
) returns (uint, uint, uint) {
    emit log_string("H: addLiquidity success");
} catch Error(string memory reason) {
    emit log_string("H: addLiquidity reverted with Error(string):");
    emit log_string(reason);
    revert(reason);
} catch (bytes memory lowLevelData) {
    emit log_string("H: addLiquidity reverted with low-level data:");
    emit log_bytes(lowLevelData);
    revert("addLiquidity reverted (low-level)");
}
emit log_string("I: addLiquidity complete");
    }

    function test_getAmountsOut_is_reserve_math_only() view external {
        address[] memory path = new address[](2);
        path[0] = address(feeToken);
        path[1] = address(normal);

        uint256 amountIn = 1_000 ether;

        uint256[] memory quoted = router.getAmountsOut(amountIn, path);
        assertEq(quoted.length, 2);
        assertGt(quoted[1], 0);
    }

    function test_fee_on_transfer_breaks_router_quote_deterministically() external {
        vm.startPrank(trader);
        feeToken.approve(address(router), type(uint256).max);

        address[] memory path = new address[](2);      
        path[0] = address(feeToken);
        path[1] = address(normal);

        uint256 amountIn = 1_000 ether;

        uint256 quotedOut = router.getAmountsOut(amountIn, path)[1];

        uint256 balBefore = normal.balanceOf(trader);

        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn,
            0,
            path,
            trader,
            block.timestamp
        );

        uint256 balAfter = normal.balanceOf(trader);
        uint256 actualOut = balAfter - balBefore;

        vm.stopPrank();

        assertLt(actualOut, quotedOut, "expected actualOut < quotedOut due to transfer fee");

        emit log_named_uint("router quoted out", quotedOut);
        emit log_named_uint("actual out", actualOut);
        emit log_named_uint("implicit loss", quotedOut - actualOut);
    }
}
