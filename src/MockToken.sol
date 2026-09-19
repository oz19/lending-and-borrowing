// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

/**
 * @title MockToken
 * @dev A simple ERC20 token for testing the lending protocol
 */
contract MockToken is ERC20, Ownable {
    uint8 private _decimals;

    /**
     * @dev Constructor to initialize the token
     * @param name The name of the token
     * @param symbol The symbol of the token
     * @param decimals_ The number of decimals
     * @param initialSupply The initial supply of tokens
     */
    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals_,
        uint256 initialSupply
    ) ERC20(name, symbol) Ownable(msg.sender) {
        _decimals = decimals_;
        _mint(msg.sender, initialSupply);
    }

    /**
     * @dev Mint new tokens (only owner)
     * @param to The address to mint tokens to
     * @param amount The amount to mint
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /**
     * @dev Burn tokens from caller
     * @param amount The amount to burn
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /**
     * @dev Get the number of decimals
     * @return The number of decimals
     */
    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }
}