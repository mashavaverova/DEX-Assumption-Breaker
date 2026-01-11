// SPDX-License-Identifier: MIT
pragma solidity =0.5.16;

import "../../lib/v2-core/contracts/UniswapV2Factory.sol";

// Wrapper only to produce an artifact in out/
contract UniV2Factory_0516 is UniswapV2Factory {
    constructor(address feeToSetter) public UniswapV2Factory(feeToSetter) {}
}
