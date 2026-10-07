// SPDX-License-Identifier: LicenseRef-PolygonLabs-Open-Attribution OR LicenseRef-PolygonLabs-Source-Available
pragma solidity 0.8.29;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IERC20Lite {
    function balanceOf(address) external view returns (uint256);
}

interface IERC4626Lite {
    function asset() external view returns (address);
    function balanceOf(address) external view returns (uint256);
    function previewRedeem(uint256) external view returns (uint256);
    function previewWithdraw(uint256) external view returns (uint256);
    function maxWithdraw(address) external view returns (uint256);
}

interface IVaultV2 {
    function liquidityAdapter() external view returns (address);
    function liquidityData() external view returns (bytes memory);
}

interface IMorphoMarketV1AdapterV2 {
    function morpho() external view returns (address);
    function supplyShares(bytes32 id) external view returns (uint256);
}

interface IMorphoVaultV1Adapter {
    function morphoVaultV1() external view returns (address);
}

interface IMorpho {
    function market(bytes32 id)
        external
        view
        returns (
            uint128 totalSupplyAssets,
            uint128 totalSupplyShares,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares,
            uint128 lastUpdate,
            uint128 fee
        );
}

/// @title VaultBridgeLiquidityLens
/// @notice Stateless capacity oracle for ERC-4626 yield vaults whose own `max*` functions are
///         uninformative. Morpho Vaults V2 hardcode all four to zero by design.
/// @dev Adapted from morpho-org/morpho-snippets `VaultV2LiquidityLib`.
/// @dev HOLDS NO FUNDS AND NO PRIVILEGES. Every function is `view`.
/// @dev Returns 0 to mean "UNKNOWN", never "no liquidity". Callers MUST treat 0 as unknown
///      and fall back to their own conservative floor, otherwise an unrecognised adapter
///      family silently reads as a fully illiquid vault.
contract VaultBridgeLiquidityLens {
    /// @dev Morpho Blue SharesMathLib virtual amounts.
    uint256 private constant VIRTUAL_SHARES = 1e6;
    uint256 private constant VIRTUAL_ASSETS = 1;

    /// @dev abi.encode(MarketParams) is exactly 5 words.
    uint256 private constant MARKET_PARAMS_LENGTH = 160;

    /// @notice Assets `owner` could withdraw from `vault` right now. 0 means unknown.
    function maxWithdraw(address vault, address owner) external view returns (uint256) {
        uint256 shares = IERC4626Lite(vault).balanceOf(owner);
        if (shares == 0) return 0;

        uint256 liquidity = availableLiquidity(vault);
        if (liquidity == 0) return 0;

        uint256 ownerAssets = IERC4626Lite(vault).previewRedeem(shares);
        return ownerAssets < liquidity ? ownerAssets : liquidity;
    }

    /// @notice Shares `owner` could redeem from `vault` right now. 0 means unknown.
    function maxRedeem(address vault, address owner) external view returns (uint256) {
        uint256 shares = IERC4626Lite(vault).balanceOf(owner);
        if (shares == 0) return 0;

        uint256 liquidity = availableLiquidity(vault);
        if (liquidity == 0) return 0;

        uint256 liquidityShares = IERC4626Lite(vault).previewWithdraw(liquidity);
        return shares < liquidityShares ? shares : liquidityShares;
    }

    /// @notice Assets withdrawable from `vault` in one transaction: idle + what the
    ///         liquidity adapter can deallocate. Mirrors `VaultV2.exit()`.
    function availableLiquidity(address vault) public view returns (uint256) {
        address asset = IERC4626Lite(vault).asset();
        uint256 idle = IERC20Lite(asset).balanceOf(vault);

        address adapter;
        bytes memory data;
        try IVaultV2(vault).liquidityAdapter() returns (address a) {
            if (a == address(0)) return idle;
            adapter = a;
            data = IVaultV2(vault).liquidityData();
        } catch {
            return idle; // not a V2 vault
        }

        return idle + _adapterLiquidity(adapter, data);
    }

    /// @dev Only the single market encoded in `liquidityData` is considered, because that is
    ///      all `exit()` deallocates from. Unknown adapter families contribute 0.
    function _adapterLiquidity(address adapter, bytes memory data) private view returns (uint256) {
        try IMorphoMarketV1AdapterV2(adapter).morpho() returns (address morpho) {
            return _marketLiquidity(adapter, morpho, data);
        } catch {
            try IMorphoVaultV1Adapter(adapter).morphoVaultV1() returns (address inner) {
                // A MetaMorpho V1 answers maxWithdraw honestly. A nested V2 returns 0,
                // which we surface as unknown rather than recursing.
                try IERC4626Lite(inner).maxWithdraw(adapter) returns (uint256 v) {
                    return v;
                } catch {
                    return 0;
                }
            } catch {
                return 0;
            }
        }
    }

    function _marketLiquidity(address adapter, address morpho, bytes memory data)
        private
        view
        returns (uint256)
    {
        if (data.length != MARKET_PARAMS_LENGTH) return 0;

        // liquidityData IS abi.encode(MarketParams), so its hash is MarketParamsLib.id().
        bytes32 id = keccak256(data);
        (address loanToken,,,,) = abi.decode(data, (address, address, address, address, uint256));

        uint256 supplyShares = IMorphoMarketV1AdapterV2(adapter).supplyShares(id);
        if (supplyShares == 0) return 0;

        (uint128 totalSupplyAssets, uint128 totalSupplyShares, uint128 totalBorrowAssets,,,) =
            IMorpho(morpho).market(id);
        if (totalSupplyShares == 0) return 0;

        // Interest accrual adds the same amount to supply and borrow, so the liquidity term
        // is near-invariant under it; `market()` is used instead of accruing, deliberately.
        uint256 adapterAssets = Math.mulDiv(
            supplyShares, uint256(totalSupplyAssets) + VIRTUAL_ASSETS, uint256(totalSupplyShares) + VIRTUAL_SHARES
        );

        uint256 marketLiquidity =
            totalSupplyAssets > totalBorrowAssets ? uint256(totalSupplyAssets) - uint256(totalBorrowAssets) : 0;

        uint256 held = IERC20Lite(loanToken).balanceOf(morpho);
        if (held < marketLiquidity) marketLiquidity = held;

        return adapterAssets < marketLiquidity ? adapterAssets : marketLiquidity;
    }
}
