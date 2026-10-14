// SPDX-License-Identifier: LicenseRef-PolygonLabs-Open-Attribution OR LicenseRef-PolygonLabs-Source-Available
pragma solidity 0.8.29;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev ERC-4626-shaped vault whose max* functions return 0, like Morpho Vaults V2.
contract ZeroMaxVault {
    using SafeERC20 for IERC20;

    IERC20 public assetToken;
    mapping(address => uint256) public balanceOf;
    bool public withdrawReverts;

    constructor(address asset_) {
        assetToken = IERC20(asset_);
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    function setWithdrawReverts(bool v) external {
        withdrawReverts = v;
    }

    function maxDeposit(address) external pure returns (uint256) {
        return 0;
    }

    function maxMint(address) external pure returns (uint256) {
        return 0;
    }

    function maxWithdraw(address) external pure returns (uint256) {
        return 0;
    }

    function maxRedeem(address) external pure returns (uint256) {
        return 0;
    }

    function convertToAssets(uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function convertToShares(uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function previewRedeem(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function previewWithdraw(uint256 assets) external pure returns (uint256) {
        return assets;
    }

    function deposit(uint256 amount, address user) external returns (uint256) {
        assetToken.safeTransferFrom(user, address(this), amount);
        balanceOf[user] += amount;
        return amount;
    }

    function withdraw(uint256 amount, address receiver, address user) external returns (uint256) {
        require(!withdrawReverts, "ZeroMaxVault: withdraw reverted");
        require(balanceOf[user] >= amount, "ZeroMaxVault: insufficient");
        balanceOf[user] -= amount;
        assetToken.safeTransfer(receiver, amount);
        return amount;
    }

    function redeem(uint256 shares, address receiver, address user) external returns (uint256) {
        require(balanceOf[user] >= shares, "ZeroMaxVault: insufficient");
        balanceOf[user] -= shares;
        assetToken.safeTransfer(receiver, shares);
        return shares;
    }
}
