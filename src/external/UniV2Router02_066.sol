// SPDX-License-Identifier: MIT
pragma solidity =0.6.6;

import "../../lib/v2-periphery/contracts/UniswapV2Router02.sol";

contract UniV2Router02_066 is UniswapV2Router02 {
    constructor(address factory, address WETH) public UniswapV2Router02(factory, WETH) {}
}
