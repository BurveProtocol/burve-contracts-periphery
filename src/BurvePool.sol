// SPDX-License-Identifier: UNLICENSED
import "burve-contracts/src/interfaces/IBurveFactory.sol";
import "burve-contracts/src/interfaces/IBondingCurve.sol";
import "openzeppelin/token/ERC20/ERC20.sol";
import "openzeppelin/token/ERC20/utils/SafeERC20.sol";
pragma solidity ^0.8.13;

contract BurvePool {
    using SafeERC20 for ERC20;
    struct PoolInfo {
        address raisingToken;
        address token;
        address bondingCurveAddr;
        address owner;
        uint256 tokenToSell;
        uint256 tokenSold;
        uint256 raisingAmount;
        uint256 endTime;
        uint256 gap;
        bytes parameters;
    }

    IBurveFactory public immutable factory;
    PoolInfo[] public pools;
    mapping(address => uint256) private _platformFee;

    event NewPools(address indexed raisingToken, address indexed token, uint256 poolIndex);

    constructor(address _factory) {
        factory = IBurveFactory(_factory);
    }

    /**
     * @dev create a pool, then user can use 'raisingToken' to buy the `token`. when the pool is ended, the pool owner can claim all `raisingToken` that are raised by the pool.
     * @param raisingToken the address of the raising token.
     * @param token the address of the token that want to sell.
     * @param bondingCurveType the type of bonding curve. 'linear' or 'exponential'
     * @param sellAmount the amount of the `token` that want to sell
     * @param endTime the end time of selling. if you want to end the pool when all sold out (sold amount bigger than sellAmount * 99.9999%), set to 0. otherwise set to the timestamp that you want to end the pool
     * @param bondingCurveParameters the parameters encoded. abi.encode(k,p) for 'linear'. abi.encode(a,b) for 'exponential'. for more informartion, please refer to https://docs.burve.io
     */
    function createPool(
        address raisingToken,
        address token,
        string calldata bondingCurveType,
        uint256 sellAmount,
        uint256 endTime,
        bytes memory bondingCurveParameters
    ) public returns (uint256 poolIndex) {
        address bondingCurve = factory.getBondingCurveImplement(bondingCurveType);
        PoolInfo memory info = PoolInfo({
            raisingToken: raisingToken,
            token: token,
            bondingCurveAddr: bondingCurve,
            parameters: bondingCurveParameters,
            tokenToSell: sellAmount,
            tokenSold: 0,
            raisingAmount: 0,
            endTime: endTime,
            gap: 10 ** (18 - ERC20(raisingToken).decimals()),
            owner: msg.sender
        });
        poolIndex = pools.length;
        emit NewPools(raisingToken, token, poolIndex);
        pools.push(info);
        _transferFromInternal(token, msg.sender, sellAmount);
    }

    function buy(uint256 poolIndex, uint256 amountPay) public payable {
        PoolInfo storage info = pools[poolIndex];
        uint256 actualPay = _transferFromInternal(info.raisingToken, msg.sender, amountPay);
        (uint256 tokenAmount, uint256 fee) = estimateBuy(poolIndex, actualPay);
        _platformFee[info.raisingToken] += fee;
        require(info.tokenSold + tokenAmount <= info.tokenToSell && (info.endTime == 0 || block.timestamp <= info.endTime), "mint limited");
        info.tokenSold += tokenAmount;
        info.raisingAmount += (actualPay - fee);
        _transferInternal(info.token, msg.sender, tokenAmount);
        if (info.endTime == 0 && info.tokenSold > info.tokenToSell - info.tokenToSell / 1e6) {
            info.endTime = block.timestamp - 1;
        }
    }

    function buyExact(uint256 poolIndex, uint256 tokenWant) public payable {
        (uint256 amountPay, ) = estimateBuyNeed(poolIndex, tokenWant);
        buy(poolIndex, amountPay);
    }

    function sell(uint256 poolIndex, uint256 tokenAmount) public {
        PoolInfo storage info = pools[poolIndex];
        require(info.endTime == 0 || block.timestamp <= info.endTime, "burn limited");
        uint256 actualSell = _transferFromInternal(info.token, msg.sender, tokenAmount);
        (uint256 returnAmount, uint256 fee) = estimateSell(poolIndex, actualSell);
        _platformFee[info.raisingToken] += fee;
        info.tokenSold -= actualSell;
        info.raisingAmount -= (returnAmount + fee);
        _transferInternal(info.raisingToken, msg.sender, returnAmount);
    }

    function endPools(uint256 poolIndex) public {
        PoolInfo memory info = pools[poolIndex];
        require(info.owner == msg.sender, "only owner");
        require(info.endTime != 0 && block.timestamp > info.endTime, "not end");
        _transferInternal(info.raisingToken, msg.sender, info.raisingAmount);
        delete pools[poolIndex];
    }

    function changeOwner(uint256 poolIndex, address newOwner) public {
        PoolInfo storage info = pools[poolIndex];
        require(info.owner == msg.sender, "only owner");
        require(newOwner != address(0), "can not transfer to address(0)");
        info.owner = newOwner;
    }

    function estimateBuy(uint256 poolIndex, uint256 amountPay) public view returns (uint256 tokenReceived, uint256 platformFee) {
        PoolInfo memory info = pools[poolIndex];
        (uint256 tax, ) = factory.getTaxRateOfPlatform();
        platformFee = (amountPay * tax) / 10000;
        amountPay -= platformFee;
        (tokenReceived, ) = _calculateBuyAmountFromBondingCurve(info, amountPay, info.tokenSold);
    }

    function estimateBuyNeed(uint256 poolIndex, uint256 tokenWant) public view returns (uint256 amountPay, uint256 platformFee) {
        PoolInfo memory info = pools[poolIndex];
        if (tokenWant + info.tokenSold > info.tokenToSell) {
            tokenWant = info.tokenToSell - info.tokenSold;
        }
        (, amountPay) = _calculateSellAmountFromBondingCurve(info, tokenWant, info.tokenSold + tokenWant);
        (uint256 tax, ) = factory.getTaxRateOfPlatform();
        amountPay = (amountPay * 10000) / (10000 - tax);
        platformFee = (amountPay * tax) / 10000;
    }

    function estimateSell(uint256 poolIndex, uint256 tokenAmount) public view returns (uint256 returnAmount, uint256 platformFee) {
        PoolInfo memory info = pools[poolIndex];
        (, returnAmount) = _calculateSellAmountFromBondingCurve(info, tokenAmount, info.tokenSold);
        (, uint256 tax) = factory.getTaxRateOfPlatform();
        platformFee = (returnAmount * tax) / 10000;
        returnAmount -= platformFee;
    }

    function claimPlatformFee(address raisingToken) public {
        address treasury = factory.getPlatformTreasury();
        require(msg.sender == treasury, "only treasury");
        uint256 amount = _platformFee[raisingToken];
        _platformFee[raisingToken] = 0;
        _transferInternal(raisingToken, treasury, amount);
    }

    function _transferFromInternal(address token, address account, uint256 amount) internal virtual returns (uint256 actualAmount) {
        if (token == address(0)) {
            require(amount <= msg.value, "invalid value");
            return amount;
        } else {
            uint256 balanceBefore = ERC20(token).balanceOf(address(this));
            ERC20(token).safeTransferFrom(account, address(this), amount);
            actualAmount = ERC20(token).balanceOf(address(this)) - balanceBefore;
        }
    }

    function _transferInternal(address token, address account, uint256 amount) internal virtual {
        if (token == address(0)) {
            require(address(this).balance >= amount, "not enough balance");
            (bool success, ) = account.call{value: amount}("");
            require(success, "Transfer: failed");
        } else {
            ERC20(token).safeTransfer(account, amount);
        }
    }

    function _calculateBuyAmountFromBondingCurve(PoolInfo memory info, uint256 tokens, uint256 totalSupply) internal view virtual returns (uint256, uint256) {
        (uint256 x, uint256 y) = IBondingCurve(info.bondingCurveAddr).calculateMintAmountFromBondingCurve(tokens * info.gap, totalSupply, info.parameters);
        return (x, y);
    }

    function _calculateSellAmountFromBondingCurve(PoolInfo memory info, uint256 tokens, uint256 totalSupply) internal view virtual returns (uint256, uint256) {
        (uint256 x, uint256 y) = IBondingCurve(info.bondingCurveAddr).calculateBurnAmountFromBondingCurve(tokens, totalSupply, info.parameters);
        return (x, y / info.gap);
    }
}
