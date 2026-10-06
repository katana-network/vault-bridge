// SPDX-License-Identifier: LicenseRef-PolygonLabs-Open-Attribution OR LicenseRef-PolygonLabs-Source-Available
pragma solidity 0.8.29;

/// @dev Configurable lens for unit tests. `0` means unknown, matching production.
contract MockLiquidityLens {
    uint256 public ret;
    bool public doRevert;

    function set(uint256 ret_, bool doRevert_) external {
        ret = ret_;
        doRevert = doRevert_;
    }

    function maxWithdraw(address, address) external view returns (uint256) {
        require(!doRevert, "MockLiquidityLens: revert");
        return ret;
    }

    function maxRedeem(address, address) external view returns (uint256) {
        require(!doRevert, "MockLiquidityLens: revert");
        return ret;
    }
}
