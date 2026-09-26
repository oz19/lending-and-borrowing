// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import "lib/openzeppelin-contracts/contracts/utils/cryptography/MessageHashUtils.sol";


/**
 * @title LendingProtocol
 * @dev A DeFi lending and borrowing protocol that allows users to:
 * - Deposit tokens to earn interest
 * - Borrow tokens against their deposited collateral
 * - Use off-chain signatures for gasless operations
 * - Manage collateralization ratios and liquidation
 */
contract LendingProtocol is ReentrancyGuard, Ownable, Pausable {

    using SafeERC20 for IERC20;
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    struct Market {
        IERC20 token;
        uint256 totalSupply;
        uint256 totalBorrow;
        uint256 supplyRate;
        uint256 borrowRate;
        uint256 collateralFactor;
        bool isActive;
    }

    struct User {
        uint256 totalDeposited;
        uint256 totalBorrowed;
        uint256 lastUpdateTime;
        bool isActive;
    }

    struct SignatureDate {
        uint256 nonce;
        uint256 deadline;
        bytes signature;
    }

    mapping(address => User) public users;
    mapping(address => mapping(address => uint256)) public userDeposits;
    mapping(address => mapping(address => uint256)) public userBorrows;
    mapping(address => Market) public markets;
    mapping(address => uint256) public userNonces;

    address[] public supportedTokens;
    uint256 public constant LIQUIDATION_THRESHOLD = 8000;  // 80% in basis points
    uint256 public constant LIQUIDATION_PENALTY = 500;  // 5% in basis points
    uint256 public constant BASIS_POINTS = 10000;  // 100% in basis points

    event MarketAdded(address indexed token, uint256 collateralFactor);
    event MarketUpdated(address indexed token, uint256 collateralFactor);
    event Deposit(address indexed user, address indexed token, uint256 amount);
    event Withdraw(address indexed user, address indexed token, uint256 amount);
    event Borrow(address indexed user, address indexed token, uint256 amount);
    event Repay(address indexed user, address indexed token, uint256 amount);
    event Liquidate(address indexed liquidator, address indexed user, address indexed token, uint256 amount);
    event RatesUpdated(address indexed token, uint256 supplyRate, uint256 borrowRate);

    modifier marketIsActive(address token) {
        require(markets[token].isActive, "Market is not active");
        _;
    }

    constructor() Ownable(msg.sender){}

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function addMarket(
        address token,
        uint256 collateralFactor,
        uint256 initialSupplyRate,
        uint256 initialBorrowRate
    ) external onlyOwner {
        require(token != address(0), "Invalid token address");
        require(collateralFactor <= BASIS_POINTS, "Invalid collateral factor");
        require(!markets[token].isActive, "Market already exists");

        markets[token] = Market({
            token: IERC20(token),
            totalSupply: 0,
            totalBorrow: 0,
            supplyRate: initialSupplyRate,
            borrowRate: initialBorrowRate,
            collateralFactor: collateralFactor,
            isActive: true
        });

        supportedTokens.push(token);
        emit MarketAdded(token, collateralFactor);
    }

    function updateMarket(
        address token,
        uint256 newCollateralFactor,
        uint256 newSupplyRate,
        uint256 newBorrowRate
    ) external onlyOwner marketIsActive(token) {
        require(token != address(0), "Invalid token address");
        require(collateralFactor <= BASIS_POINTS, "Invalid collateral factor");

        Market storage market = markets[token];
        market.supplyRate = newSupplyRate;
        market.borrowRate = newBorrowRate;
        market.collateralFactor = newCollateralFactor;

        emit MarketUpdated(token, collateralFactor);
        emit RatesUpdated(token, newSupplyRate, newBorrowRate);
    }

    function deposit(address token, uint256 amount) external nonReentrant marketIsActive(token) whenNotPaused {
        require(token != address(0), "Invalid token address");
        require(amount > 0, "Amount must be greater than zero");

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        userDeposits[msg.sender][token] += amount;
        
        User storage user = users[msg.sender];
        user.totalDeposited += amount;
        user.lastUpdateTime = block.timestamp;
        user.isActive = true;

        Market storage market = markets[token];
        market.totalSupply += amount;

        emit Deposit(msg.sender, token, amount);
    }

}