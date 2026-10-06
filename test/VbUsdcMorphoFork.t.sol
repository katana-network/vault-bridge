// SPDX-License-Identifier: LicenseRef-PolygonLabs-Open-Attribution OR LicenseRef-PolygonLabs-Source-Available
pragma solidity 0.8.29;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {GenericVaultBridgeToken} from "src/vault-bridge-tokens/GenericVaultBridgeToken.sol";
import {VaultBridgeTokenPart2} from "src/VaultBridgeTokenPart2.sol";
import {VaultBridgeLiquidityLens} from "src/etc/VaultBridgeLiquidityLens.sol";

interface IProxyAdmin {
    function owner() external view returns (address);
    function upgradeAndCall(address proxy, address implementation, bytes calldata data) external payable;
}

interface IVbUsdc {
    error NoYield();

    function paused() external view returns (bool);
    function version() external view returns (string memory);
    function name() external view returns (string memory);
    function asset() external view returns (address);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function reservedAssets() external view returns (uint256);
    function stakedAssets() external view returns (uint256);
    function yield() external view returns (uint256);
    function yieldVault() external view returns (address);
    function yieldRecipient() external view returns (address);
    function migrationManager() external view returns (address);
    function lxlyBridge() external view returns (address);
    function minimumReservePercentage() external view returns (uint256);
    function minimumYieldVaultDeposit() external view returns (uint256);
    function yieldVaultMaximumSlippagePercentage() external view returns (uint256);
    function convertToAssets(uint256 shares) external pure returns (uint256);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function maxWithdraw(address owner) external view returns (uint256);
    function setVaultBridgeTokenPart2(address part2) external;
    function setLiquidityLens(address lens) external;
    function pause() external;
    function collectYield() external;
    function drainYieldVault(uint256 shares, bool exact) external;
    function setYieldVault(address vault) external;
    function unpause() external;
    function rebalanceReserve() external;
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
}

interface IYieldVault {
    function asset() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function maxWithdraw(address owner) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function receiveSharesGate() external view returns (address);
    function sendSharesGate() external view returns (address);
    function receiveAssetsGate() external view returns (address);
    function sendAssetsGate() external view returns (address);
}

/// @notice Forks mainnet, upgrades live vbUSDC, and runs the vault-swap checklist against Steakhouse USDC V2.
/// @dev A V1 liquidity shortfall is logged and does not stop the drain. The drain reverting still fails the test.
contract VbUsdcMorphoForkTest is Test {
    // Live vbUSDC proxy.
    address internal constant VB_USDC = 0x53E82ABbb12638F09d9e624578ccB666217a765e;
    // ProxyAdmin for vbUSDC. The USDC Safe owns this contract.
    address internal constant PROXY_ADMIN = 0x8970650CF3f1E57cA804C65B4DBcFf698789FE30;
    // Safe that owns the ProxyAdmin and holds the four vbUSDC roles.
    address internal constant USDC_SAFE = 0xf4F2f5F6bAdBE05433C4604320ecC56BbECBC04E;
    // MetaMorpho V1 vault that currently holds the vbUSDC position.
    address internal constant V1_VAULT = 0xBEefb9f61CC44895d8AEc381373555a64191A9c4;
    // Steakhouse Morpho Vault V2 used as the new yield vault.
    address internal constant STEAKHOUSE_USDC = 0xbeef088055857739C12CD3765F20b7679Def0f51;
    // Underlying asset.
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    // LxLy bridge. It holds most of the vbUSDC supply and is the withdraw caller.
    address internal constant LXLY_BRIDGE = 0x2a3DD3EB832aF982ec71669E178424b10Dca2EDe;
    // Part2 singleton the proxy points at before this upgrade.
    address internal constant CURRENT_PART2 = 0x1C8565F454F8239B854fe62C99B90b3FC9298E80;

    // OpenZeppelin AccessControl default admin.
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    // Role that may pause the proxy.
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    // Role that may call rebalanceReserve.
    bytes32 internal constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");
    // Role that may call collectYield.
    bytes32 internal constant YIELD_COLLECTOR_ROLE = keccak256("YIELD_COLLECTOR_ROLE");

    // ERC-7201 base slot for VaultBridgeToken storage.
    bytes32 internal constant VB_STORAGE = hex"f082fbc4cfb4d172ba00d34227e208a31ceb0982bc189440d519185302e44700";
    // Part2 address. There is no public getter.
    bytes32 internal constant PART2_SLOT = bytes32(uint256(VB_STORAGE) + 11);
    // Liquidity lens address.
    bytes32 internal constant LENS_SLOT = bytes32(uint256(VB_STORAGE) + 12);
    // EIP-1967 implementation slot.
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // Sum of the six vault-swap calls must stay under this. The block gas limit is 60M.
    uint256 internal constant SWAP_GAS_CEILING = 45_000_000;
    // USDC withdrawn after seeding Steakhouse. Deposit allocates it, so this exits through the adapter.
    uint256 internal constant EXIT_ASSETS = 1_000e6;

    struct PriorState {
        uint256 totalSupply;
        uint256 reservedAssets;
        address yieldVault;
        address asset;
        string name;
        uint256 minimumReservePercentage;
        uint256 minimumYieldVaultDeposit;
        uint256 slippage;
        address yieldRecipient;
        address migrationManager;
        address lxlyBridge;
        address part2;
        address lens;
    }

    PriorState internal prior;
    address internal lens;
    address internal part2;
    address internal genericImpl;
    uint256 internal swapGas;
    uint256 internal swapCalls;

    error CallFailed(address target);

    function setUp() public {
        vm.createSelectFork(vm.envOr("FORK_URL", string("mainnet")));
        vm.label(VB_USDC, "vbUSDC");
        vm.label(PROXY_ADMIN, "vbUSDC ProxyAdmin");
        vm.label(USDC_SAFE, "vbUSDC Safe");
        vm.label(V1_VAULT, "MetaMorpho V1 USDC");
        vm.label(STEAKHOUSE_USDC, "Steakhouse USDC V2");
        vm.label(USDC, "USDC");
        vm.label(LXLY_BRIDGE, "LxLy Bridge");
    }

    function test_rehearseVbUsdcVaultSwap() public {
        _discoverSafe();
        _deployImplementations();
        _upgrade();
        _pause();
        _collectYield();
        _drainYieldVault();
        _switchYieldVault();
        _unpause();
        _rebalanceReserve();
        _withdrawFromV2();
        _assertSwapGas();
    }

    function _discoverSafe() internal {
        assertEq(IProxyAdmin(PROXY_ADMIN).owner(), USDC_SAFE);
        _assertSafeHoldsRoles();

        IVbUsdc token = _token();
        assertFalse(token.paused());
        assertEq(token.version(), "0.5.0");
        assertEq(token.asset(), USDC);

        prior = _capture();
        assertEq(prior.yieldVault, V1_VAULT);
        assertEq(prior.part2, CURRENT_PART2);
        assertEq(prior.lens, address(0));
        assertEq(prior.lxlyBridge, LXLY_BRIDGE);
        assertGt(token.balanceOf(LXLY_BRIDGE), 0, "LxLy bridge holds no vbUSDC");
        console.log("ok discover: Safe owns ProxyAdmin, holds four roles, unpaused 0.5.0, V1 vault");
        console.log("  supply", prior.totalSupply);
        console.log("  reserved", prior.reservedAssets);
        console.log("  bridge vbUSDC", token.balanceOf(LXLY_BRIDGE));
    }

    function _deployImplementations() internal {
        lens = address(new VaultBridgeLiquidityLens());
        part2 = address(new VaultBridgeTokenPart2());
        genericImpl = address(new GenericVaultBridgeToken());
        vm.label(lens, "LiquidityLens");
        vm.label(part2, "VaultBridgeTokenPart2");
        vm.label(genericImpl, "GenericVaultBridgeToken");
    }

    function _upgrade() internal {
        address implBefore = _implementation();
        _call(
            USDC_SAFE, PROXY_ADMIN, abi.encodeCall(IProxyAdmin.upgradeAndCall, (VB_USDC, genericImpl, bytes(""))), false
        );

        IVbUsdc token = _token();
        assertEq(token.version(), "0.6.0");
        assertEq(_implementation(), genericImpl);
        assertTrue(implBefore != genericImpl);
        _assertStatePreserved();
        _assertSafeHoldsRoles();
        console.log("ok upgrade: version 0.6.0, storage and roles unchanged, still on V1");

        _call(USDC_SAFE, VB_USDC, abi.encodeCall(IVbUsdc.setVaultBridgeTokenPart2, (part2)), false);
        _call(USDC_SAFE, VB_USDC, abi.encodeCall(IVbUsdc.setLiquidityLens, (lens)), false);

        assertEq(_loadAddress(PART2_SLOT), part2);
        assertEq(_loadAddress(LENS_SLOT), lens);
        assertEq(token.yieldVault(), prior.yieldVault);
        assertFalse(token.paused());
        assertGt(token.maxWithdraw(LXLY_BRIDGE), 0);
        console.log("ok setters: new Part2 and lens, maxWithdraw", token.maxWithdraw(LXLY_BRIDGE));
    }

    function _pause() internal {
        _swap(abi.encodeCall(IVbUsdc.pause, ()));
        assertTrue(_token().paused());
        assertEq(_token().maxWithdraw(LXLY_BRIDGE), 0);
        console.log("ok pause: paused, maxWithdraw is 0");
    }

    function _collectYield() internal {
        IVbUsdc token = _token();
        uint256 outstanding = token.yield();
        address recipient = token.yieldRecipient();
        uint256 balanceBefore = token.balanceOf(recipient);

        if (outstanding == 0) {
            vm.expectRevert(IVbUsdc.NoYield.selector);
            vm.prank(USDC_SAFE);
            token.collectYield();
            console.log("ok collectYield: no yield, call reverts NoYield");
            return;
        }

        _swap(abi.encodeCall(IVbUsdc.collectYield, ()));
        assertEq(token.balanceOf(recipient), balanceBefore + outstanding);
        assertEq(token.yield(), 0);
        console.log("ok collectYield: minted", outstanding);
    }

    function _drainYieldVault() internal {
        _warnV1Liquidity();

        IVbUsdc token = _token();
        address vault = token.yieldVault();
        uint256 reservedBefore = token.reservedAssets();

        _swap(abi.encodeCall(IVbUsdc.drainYieldVault, (type(uint256).max, true)));

        assertEq(IYieldVault(vault).balanceOf(VB_USDC), 0);
        assertEq(token.stakedAssets(), 0);
        assertGt(token.reservedAssets(), reservedBefore);
        assertGe(IERC20(USDC).balanceOf(VB_USDC), token.reservedAssets());
        console.log("ok drain: V1 shares 0, reserved", token.reservedAssets());
    }

    function _switchYieldVault() internal {
        _assertV2GatesOpen();
        address oldVault = _token().yieldVault();

        _swap(abi.encodeCall(IVbUsdc.setYieldVault, (STEAKHOUSE_USDC)));

        assertEq(_token().yieldVault(), STEAKHOUSE_USDC);
        assertEq(IERC20(USDC).allowance(VB_USDC, oldVault), 0);
        assertEq(IERC20(USDC).allowance(VB_USDC, STEAKHOUSE_USDC), type(uint256).max);
        console.log("ok setYieldVault: Steakhouse, old allowance 0, new allowance max");
    }

    function _unpause() internal {
        _swap(abi.encodeCall(IVbUsdc.unpause, ()));
        assertFalse(_token().paused());
        console.log("ok unpause");
    }

    function _rebalanceReserve() internal {
        IVbUsdc token = _token();
        uint256 reservedBefore = token.reservedAssets();
        uint256 minimumReserve = _minimumReserve();
        uint256 deposited = reservedBefore - minimumReserve;
        uint256 idleBefore = IERC20(USDC).balanceOf(STEAKHOUSE_USDC);
        uint256 stakedBefore = token.stakedAssets();

        _swap(abi.encodeCall(IVbUsdc.rebalanceReserve, ()));

        // Vault V2 enter() allocates the new assets to the liquidity adapter before returning,
        // so the vault's idle USDC balance does not keep the deposit.
        assertEq(token.reservedAssets(), minimumReserve);
        assertGt(IYieldVault(STEAKHOUSE_USDC).balanceOf(VB_USDC), 0);
        assertEq(IERC20(USDC).balanceOf(STEAKHOUSE_USDC), idleBefore);
        assertGe(token.stakedAssets() - stakedBefore, Math.mulDiv(deposited, 1e18 - prior.slippage, 1e18));
        console.log("ok rebalance: deposited", deposited);
        console.log("  reserved", token.reservedAssets());
        console.log("  staked", token.stakedAssets());
        console.log("  idle unchanged", idleBefore);
    }

    function _withdrawFromV2() internal {
        IVbUsdc token = _token();
        assertGt(token.balanceOf(LXLY_BRIDGE), EXIT_ASSETS, "LxLy bridge holds no vbUSDC");

        address receiver = makeAddr("exitReceiver");
        uint256 receiverBefore = IERC20(USDC).balanceOf(receiver);
        uint256 idleBefore = IERC20(USDC).balanceOf(STEAKHOUSE_USDC);
        uint256 sharesBefore = IYieldVault(STEAKHOUSE_USDC).balanceOf(VB_USDC);
        assertLt(idleBefore, EXIT_ASSETS);
        console.log("ok withdraw preconditions: bridge covers exit, idle", idleBefore);

        _call(LXLY_BRIDGE, VB_USDC, abi.encodeCall(IVbUsdc.withdraw, (EXIT_ASSETS, receiver, LXLY_BRIDGE)), false);

        assertEq(IERC20(USDC).balanceOf(receiver), receiverBefore + EXIT_ASSETS);
        assertEq(IERC20(USDC).balanceOf(STEAKHOUSE_USDC), idleBefore);
        assertLt(IYieldVault(STEAKHOUSE_USDC).balanceOf(VB_USDC), sharesBefore);
        console.log("ok withdraw: receiver got", EXIT_ASSETS);
        console.log("  V2 shares before", sharesBefore);
        console.log("  V2 shares after", IYieldVault(STEAKHOUSE_USDC).balanceOf(VB_USDC));
    }

    function _assertSwapGas() internal view {
        assertLt(swapGas, SWAP_GAS_CEILING);
        console.log("ok gas: calls", swapCalls);
        console.log("  gas", swapGas);
        console.log("  ceiling", SWAP_GAS_CEILING);
    }

    /// @dev Logs whether the V1 vault can pay a full redeem. Does not revert.
    function _warnV1Liquidity() internal view {
        address vault = _token().yieldVault();
        uint256 shares = IYieldVault(vault).balanceOf(VB_USDC);
        (bool redeemOk, bytes memory redeemData) = vault.staticcall(abi.encodeCall(IYieldVault.previewRedeem, (shares)));
        (bool withdrawOk, bytes memory withdrawData) =
            vault.staticcall(abi.encodeCall(IYieldVault.maxWithdraw, (VB_USDC)));

        if (!redeemOk || !withdrawOk || redeemData.length < 32 || withdrawData.length < 32) {
            console.log("WARNING: could not read V1 liquidity; continuing to drain");
            return;
        }

        uint256 owed = abi.decode(redeemData, (uint256));
        uint256 liquid = abi.decode(withdrawData, (uint256));
        if (liquid >= owed) {
            console.log("vbUSDC V1 position is fully liquid");
        } else {
            console.log("WARNING: vbUSDC V1 position is illiquid");
        }
        console.log("maxWithdraw", liquid);
        console.log("previewRedeem", owed);
    }

    function _assertV2GatesOpen() internal view {
        IYieldVault vault = IYieldVault(STEAKHOUSE_USDC);
        assertEq(vault.asset(), USDC);
        assertEq(vault.receiveSharesGate(), address(0));
        assertEq(vault.sendSharesGate(), address(0));
        assertEq(vault.receiveAssetsGate(), address(0));
        assertEq(vault.sendAssetsGate(), address(0));
        console.log("ok gates: Steakhouse asset is USDC, all four gates open");
    }

    function _assertSafeHoldsRoles() internal view {
        IVbUsdc token = _token();
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, USDC_SAFE));
        assertTrue(token.hasRole(PAUSER_ROLE, USDC_SAFE));
        assertTrue(token.hasRole(REBALANCER_ROLE, USDC_SAFE));
        assertTrue(token.hasRole(YIELD_COLLECTOR_ROLE, USDC_SAFE));
    }

    function _assertStatePreserved() internal view {
        PriorState memory state = _capture();
        assertEq(state.totalSupply, prior.totalSupply);
        assertEq(state.reservedAssets, prior.reservedAssets);
        assertEq(state.yieldVault, prior.yieldVault);
        assertEq(state.asset, prior.asset);
        assertEq(state.name, prior.name);
        assertEq(state.minimumReservePercentage, prior.minimumReservePercentage);
        assertEq(state.minimumYieldVaultDeposit, prior.minimumYieldVaultDeposit);
        assertEq(state.slippage, prior.slippage);
        assertEq(state.yieldRecipient, prior.yieldRecipient);
        assertEq(state.migrationManager, prior.migrationManager);
        assertEq(state.lxlyBridge, prior.lxlyBridge);
        assertEq(state.part2, prior.part2);
        assertEq(state.lens, prior.lens);
    }

    function _capture() internal view returns (PriorState memory state) {
        IVbUsdc token = _token();
        state.totalSupply = token.totalSupply();
        state.reservedAssets = token.reservedAssets();
        state.yieldVault = token.yieldVault();
        state.asset = token.asset();
        state.name = token.name();
        state.minimumReservePercentage = token.minimumReservePercentage();
        state.minimumYieldVaultDeposit = token.minimumYieldVaultDeposit();
        state.slippage = token.yieldVaultMaximumSlippagePercentage();
        state.yieldRecipient = token.yieldRecipient();
        state.migrationManager = token.migrationManager();
        state.lxlyBridge = token.lxlyBridge();
        state.part2 = _loadAddress(PART2_SLOT);
        state.lens = _loadAddress(LENS_SLOT);
    }

    /// @dev Same minimum the token uses in `_rebalanceReserve`.
    function _minimumReserve() internal view returns (uint256) {
        IVbUsdc token = _token();
        return token.convertToAssets(Math.mulDiv(token.totalSupply(), token.minimumReservePercentage(), 1e18));
    }

    function _swap(bytes memory data) internal {
        _call(USDC_SAFE, VB_USDC, data, true);
    }

    function _call(address caller, address target, bytes memory data, bool countGas) internal {
        uint256 gasBefore = gasleft();
        vm.prank(caller);
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) _bubble(target, ret);
        if (countGas) {
            swapGas += gasBefore - gasleft();
            swapCalls += 1;
        }
    }

    function _bubble(address target, bytes memory ret) private pure {
        if (ret.length == 0) revert CallFailed(target);
        assembly {
            revert(add(ret, 32), mload(ret))
        }
    }

    function _token() private pure returns (IVbUsdc) {
        return IVbUsdc(VB_USDC);
    }

    function _implementation() private view returns (address) {
        return _loadAddress(IMPLEMENTATION_SLOT);
    }

    function _loadAddress(bytes32 slot) private view returns (address) {
        return address(uint160(uint256(vm.load(VB_USDC, slot))));
    }
}
