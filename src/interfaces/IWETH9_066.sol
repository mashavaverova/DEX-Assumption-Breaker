// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IWETH9_066 {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
    function approve(address guy, uint256 wad) external returns (bool);
}
