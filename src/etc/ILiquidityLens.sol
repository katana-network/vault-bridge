// SPDX-License-Identifier: LicenseRef-PolygonLabs-Open-Attribution OR LicenseRef-PolygonLabs-Source-Available
pragma solidity 0.8.29;

/// @notice Stateless capacity oracle. Returns 0 when the vault's adapter family is unrecognised,
///         which callers MUST treat as "unknown", never as "no liquidity".
interface ILiquidityLens {
    function maxWithdraw(address vault, address owner) external view returns (uint256);
    function maxRedeem(address vault, address owner) external view returns (uint256);
}
