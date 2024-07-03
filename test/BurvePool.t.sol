// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "burve-contracts/utils/BaseTest.sol";
import "openzeppelin/token/ERC20/presets/ERC20PresetFixedSupply.sol";
import "../src/BurvePool.sol";

contract BurvePoolTest is BaseTest {
    BurvePool pool;

    function setUp() public override {
        super.setUp();
        pool = new BurvePool(address(factory));
    }

    function testPool() public {
        vm.warp(block.timestamp + 1 days);
        ERC20PresetFixedSupply tokenA = new ERC20PresetFixedSupply("Token A", "TA", 1000000 ether, address(this));
        ERC20PresetFixedSupply tokenB = new ERC20PresetFixedSupply("Token B", "TB", 100000000 ether, address(this));
        vm.label(address(tokenA), "raisingToken");
        vm.label(address(tokenB), "tokenToSell");
        uint256 a = 0.00001 ether;
        uint256 b = ((1000 * 1e18) / a) * 1e18;
        bytes memory data = abi.encode(a, b);
        tokenB.approve(address(pool), type(uint256).max);
        uint256 tokenToSell = tokenB.balanceOf(address(this));
        uint256 poolIndex = pool.createPool(address(tokenA), address(tokenB), bondingCurveType, tokenToSell, 0, data);
        tokenA.approve(address(pool), type(uint256).max);
        pool.buyExact(poolIndex, tokenToSell);
        vm.startPrank(platformTreasury);
        pool.claimPlatformFee(address(tokenA));
        vm.stopPrank();
        (, , , , , uint256 tokenToSell2, uint256 tokenSold, uint256 endTime, , ) = pool.pools(poolIndex);
        console.log(tokenToSell2, tokenSold, tokenToSell2 - tokenToSell2 / 1e6);
        console.log(block.timestamp, endTime);
        pool.endPools(poolIndex);
        // pool.mint(poolIndex, 1000 ether);
        // vm.startPrank(platformTreasury);
        // pool.claimPlatformFee(address(tokenA));
    }
}
