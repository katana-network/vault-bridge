// SPDX-License-Identifier: LicenseRef-PolygonLabs-Open-Attribution OR LicenseRef-PolygonLabs-Source-Available
pragma solidity 0.8.29;

import {Test, console} from "forge-std/Test.sol";
import {VaultBridgeLiquidityLens} from "src/etc/VaultBridgeLiquidityLens.sol";

interface IVaultV2Lite {
    function withdraw(uint256, address, address) external returns (uint256);
    function totalAssets() external view returns (uint256);
}

/// @notice Fork tests proving the lens equals what a real withdrawal delivers.
/// @dev Set FORK_URL to override the `mainnet` rpc alias from foundry.toml.
/// @dev These read live state. The vault addresses are third-party public Morpho Vaults V2.
contract LensForkTest is Test {
    VaultBridgeLiquidityLens lens;

    address constant STEAK_USDC = 0xbeef088055857739C12CD3765F20b7679Def0f51; // V2, deep
    address constant GAUNT_USDC = 0x8c106EEDAd96553e64287A5A6839c3Cc78afA3D0; // V2, different adapter, same Blue market
    address constant YV_USDC_V1 = 0xBEefb9f61CC44895d8AEc381373555a64191A9c4; // MetaMorpho V1 (not a VaultV2)

    function setUp() public {
        vm.createSelectFork(vm.envOr("FORK_URL", string("mainnet")));
        lens = new VaultBridgeLiquidityLens();
    }

    /// @dev Binary-search the true maximum withdrawal to single-wei resolution by
    ///      simulating the real call and rolling back with state snapshots.
    function _trueMax(address vault, address holder) internal returns (uint256) {
        uint256 lo = 0;
        uint256 hi = IVaultV2Lite(vault).totalAssets();
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            vm.prank(holder);
            (bool ok,) = vault.call(abi.encodeWithSelector(IVaultV2Lite.withdraw.selector, mid, holder, holder));
            vm.revertToState(snap);
            if (ok) lo = mid;
            else hi = mid;
        }
        return lo;
    }

    function _assertLensMatchesReality(address vault, address whale) internal {
        deal(vault, whale, 1e30); // more shares than any liquidity, so liquidity is the binding term
        uint256 lensVal = lens.maxWithdraw(vault, whale);
        uint256 realVal = _trueMax(vault, whale);
        console.log("lens =", lensVal);
        console.log("real =", realVal);
        // The lens must NEVER over-report: over-reporting is the unsafe direction.
        assertLe(lensVal, realVal, "lens over-reported");
        assertApproxEqRel(lensVal, realVal, 1e14, "lens diverges from reality by more than 1e-4");
    }

    function test_lens_matches_reality_steakhouse() public {
        _assertLensMatchesReality(STEAK_USDC, address(0xBEEF01));
    }

    function test_lens_matches_reality_gauntlet() public {
        _assertLensMatchesReality(GAUNT_USDC, address(0xBEEF02));
    }

    /// @dev MetaMorpho V1 has no liquidityAdapter(); the lens must not revert, and must report idle only.
    function test_lens_does_not_revert_on_v1_vault() public view {
        uint256 v = lens.availableLiquidity(YV_USDC_V1);
        assertLt(v, 1e12, "V1 idle should be negligible");
    }
}
