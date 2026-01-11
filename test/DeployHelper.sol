// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

abstract contract DeployHelper is Test {
    function _deploy(bytes memory bytecode) internal returns (address deployed) {
        assembly {
            deployed := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(deployed != address(0), "DEPLOY_FAILED");
    }

    function _artifact(string memory path) internal view returns (bytes memory) {
        return vm.getCode(path);
    }
}
