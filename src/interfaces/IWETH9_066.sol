// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IWETH9_066 {
    function deposit() external payable;
    function withdraw(uint wad) external;
    function approve(address guy, uint wad) external returns (bool);
}
