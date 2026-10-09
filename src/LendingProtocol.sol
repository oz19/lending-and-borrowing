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

    function withdraw(address token, uint256 amount) external nonReentrant marketIsActive(token) whenNotPaused {
        require(token != address(0), "Invalid token address");
        require(amount > 0, "Amount must be greater than zero");
        require(users[msg.sender].isActive, "User is not active");
        require(users[msg.sender].totalDeposited >= amount, "Not enough balance");
        require(canWithdraw(msg.sender, token, amount), "User would make the position unsafe");

        users[msg.sender][token] -= amount;

        User storage user = users[msg.sender];
        user.totalDeposited -= amount;
        user.lastUpdateTime = block.timestamp;

        if(user.totalDeposited == 0) {
            user.isActive = false;
        }

        Market storage market = markets[token];
        market.totalSupply -= amount;

        IERC20(token).safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, token, amount);
    }

    /**
     * @dev Check if a user can withdraw without making position unsafe
     * @param user The user address
     * @param token The token to withdraw
     * @param amount The amount to withdraw
     * @return True if withdrawal is safe
     */
    function canWithdraw(address user, address token, uint256 amount) public view returns (bool) {
        uint256 currentRatio = getCollateralizationRatio(user);
        if (currentRatio == type(uint256).max) return true;
        
        // Calculate new ratio after withdrawal
        uint256 newCollateralValue = 0;
        uint256 totalBorrowValue = 0;
        
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            address supportedToken = supportedTokens[i];
            if (markets[supportedToken].isActive) {
                uint256 depositAmount = userDeposits[user][supportedToken];
                uint256 borrowAmount = userBorrows[user][supportedToken];
                
                if (supportedToken == token) {
                    depositAmount = depositAmount > amount ? depositAmount - amount : 0;
                }
                
                if (depositAmount > 0) {
                    newCollateralValue += (depositAmount * markets[supportedToken].collateralFactor) / BASIS_POINTS;
                }
                
                if (borrowAmount > 0) {
                    totalBorrowValue += borrowAmount;
                }
            }
        }
        
        if (totalBorrowValue == 0) return true;
        uint256 newRatio = (newCollateralValue * BASIS_POINTS) / totalBorrowValue;
        return newRatio >= LIQUIDATION_THRESHOLD;
    }

    /**
     * @dev Get user's current collateralization ratio
     * @param user The user address
     * @return ratio The collateralization ratio in basis points
     */
    function getCollateralizationRatio(address user) public view returns (uint256 ratio) {
        uint256 totalCollateralValue = 0;
        uint256 totalBorrowValue = 0;
        
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            address token = supportedTokens[i];
            if (markets[token].isActive) {
                uint256 depositAmount = userDeposits[user][token];
                uint256 borrowAmount = userBorrows[user][token];
                
                if (depositAmount > 0) {
                    totalCollateralValue += (depositAmount * markets[token].collateralFactor) / BASIS_POINTS;
                }
                
                if (borrowAmount > 0) {
                    totalBorrowValue += borrowAmount;
                }
            }
        }
        
        if (totalBorrowValue == 0) return type(uint256).max;
        return (totalCollateralValue * BASIS_POINTS) / totalBorrowValue;
    }

    function borrow(
        address token,
        uint256 amount
    ) external nonReentrant whenNotPaused onlyActiveMarket(token) {
        require(amount > 0, "Amount must be greater than zero");
        require(markets[token].totalSupply >= amount, "Insufficient liquidity");
        require(canBorrow(msg.sender, token, amount), "Borrow would exceed collateral limit");

        userBorrows[msg.sender][token] += amount;
        users[msg.sender].totalBorrowed += amount;
        users[msg.sender].lastUpdateTime = block.timestamp;
        users[msg.sender].isActive = true;

        markets[token].totalBorrow += amount;

        IERC20(token).safeTransfer(msg.sender, amount);

        emit Borrow(msg.sender, token, amount);
    }

    function repay(
        address token,
        uint256 amount
    ) external nonReentrant whenNotPaused onlyActiveMarket(token) {
        require(amount > 0, "Amount must be greater than zero");
        require(userBorrows[msg.sender][token] >= amount, "Insufficient borrow");

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        userBorrows[msg.sender][token] -= amount;
        users[msg.sender].totalBorrowed -= amount;
        users[msg.sender].lastUpdateTime = block.timestamp;
        
        if (user[msg.sender].totalBorrowed == 0) {
            users[msg.sender].isActive = false;
        }

        markets[token].totalBorrow -= amount;

        emit Repay(msg.sender, token, amount);
    }

    function liquidate(address user, address token, uint256 amount) 
        external 
        nonReentrant 
        whenNotPaused 
        onlyActiveMarket(token) 
    {
        require(amount > 0, "Amount must be greater than 0");
        require(userBorrows[user][token] >= amount, "Insufficient borrow to liquidate");
        require(isLiquidatable(user), "Position is not liquidatable");
        
        uint256 collateralToSeize = (amount * (BASIS_POINTS + LIQUIDATION_PENALTY)) / BASIS_POINTS;
        
        address collateralToken = findBestCollateral(user);
        require(collateralToken != address(0), "No collateral to seize");
        require(userDeposits[user][collateralToken] >= collateralToSeize, "Insufficient collateral");
        
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        
        userBorrows[user][token] -= amount;
        users[user].totalBorrowed -= amount;
        markets[token].totalBorrow -= amount;
        
        userDeposits[user][collateralToken] -= collateralToSeize;
        users[user].totalDeposited -= collateralToSeize;
        markets[collateralToken].totalSupply -= collateralToSeize;
        
        IERC20(collateralToken).safeTransfer(msg.sender, collateralToSeize);
        
        emit Liquidate(msg.sender, user, token, amount);
    }

    function isLiquidatable(address user) public view returns (bool) {
        uint256 ratio = getCollateralizationRatio(user);
        return ratio < LIQUIDATION_THRESHOLD;
    }

    function findBestCollateral(address user) internal view returns (address) {
        address bestToken = address(0);
        uint256 bestValue = 0;
        
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            address token = supportedTokens[i];
            if (markets[token].isActive && userDeposits[user][token] > 0) {
                uint256 value = (userDeposits[user][token] * markets[token].collateralFactor) / BASIS_POINTS;
                if (value > bestValue) {
                    bestValue = value;
                    bestToken = token;
                }
            }
        }
        
        return bestToken;
    }

}