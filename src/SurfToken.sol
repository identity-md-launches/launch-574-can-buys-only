// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title SurfToken
/// @notice The Surf launch token: a plain fixed-supply ERC-20.
/// @dev No owner, no mint after construction, no pause, no blocklist, no fee, no upgrade path.
/// The whole supply (1,000,000,000 tokens, 18 decimals) is minted to the deployer, which at launch is
/// the IMD launch factory. Every trading rule the brief asks for lives in `BuyOnlyVoteHook`.
contract SurfToken is ERC20 {
    /// @notice Fixed total supply: exactly 10^27 minor units.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    constructor() ERC20("Surf", "SURF") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
