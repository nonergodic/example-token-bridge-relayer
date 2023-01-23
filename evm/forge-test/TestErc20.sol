// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TestToken is ERC20 {
    uint8 decimals_;

    constructor(
        address mintToAddress,
        uint8 tokenDecimals_,
        uint256 supply
    ) ERC20("tester", "tkn"){
        decimals_ = tokenDecimals_;
        _mint(mintToAddress, supply*10**decimals_);
    }

    function decimals() public view override returns (uint8) {
        return decimals_;
    }
}