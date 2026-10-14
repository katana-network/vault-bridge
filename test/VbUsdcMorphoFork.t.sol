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
    function maxDeposit(address receiver) external view returns (uint256);
    function maxMint(address receiver) external view returns (uint256);
    function maxWithdraw(address owner) external view returns (uint256);
    function maxRedeem(address owner) external view returns (uint256);
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
        _assertMaxOnV1();
        _pause();
        _collectYield();
        _drainYieldVault();
        _switchYieldVault();
        _unpause();
        _rebalanceReserve();
        _assertMaxOnV2();
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
        _rule();
        console.log("discover: Safe owns ProxyAdmin, holds the four roles, unpaused 0.5.0");
        console.log("  yield vault is MetaMorpho V1");
        console.log(string.concat("  total supply   ", _usdc(prior.totalSupply)));
        console.log(string.concat("  reserved       ", _usdc(prior.reservedAssets)));
        console.log(string.concat("  bridge balance ", _usdc(token.balanceOf(LXLY_BRIDGE))));
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
        _rule();
        console.log("upgrade: version 0.6.0, storage and roles unchanged, still on MetaMorpho V1");

        _call(USDC_SAFE, VB_USDC, abi.encodeCall(IVbUsdc.setVaultBridgeTokenPart2, (part2)), false);
        _call(USDC_SAFE, VB_USDC, abi.encodeCall(IVbUsdc.setLiquidityLens, (lens)), false);

        assertEq(_loadAddress(PART2_SLOT), part2);
        assertEq(_loadAddress(LENS_SLOT), lens);
        assertEq(token.yieldVault(), prior.yieldVault);
        assertFalse(token.paused());
        console.log("setters: new Part2 and liquidity lens installed, yield vault unchanged");
    }

    /// @dev Ops check before the swap. A non-zero V1 maxWithdraw means the lens is not consulted.
    function _assertMaxOnV1() internal view {
        IVbUsdc token = _token();
        assertEq(token.maxDeposit(LXLY_BRIDGE), type(uint256).max);
        assertEq(token.maxMint(LXLY_BRIDGE), type(uint256).max);
        uint256 maxWithdraw_ = token.maxWithdraw(LXLY_BRIDGE);
        uint256 maxRedeem_ = token.maxRedeem(LXLY_BRIDGE);
        assertGt(maxWithdraw_, 0);
        assertGt(maxRedeem_, 0);

        uint256 v1Liquid = IYieldVault(V1_VAULT).maxWithdraw(VB_USDC);
        _rule();
        console.log("before the swap, still on V1 and unpaused");
        console.log("  maxDeposit and maxMint are unlimited");
        console.log(string.concat("  bridge maxWithdraw ", _usdc(maxWithdraw_)));
        console.log(string.concat("  bridge maxRedeem   ", _usdc(maxRedeem_)));
        console.log(string.concat("  V1 maxWithdraw of the vbUSDC position ", _usdc(v1Liquid)));
        if (v1Liquid > 0) {
            console.log("V1 reported liquidity, so the lens was not consulted");
        } else {
            console.log("V1 reports 0, so a non-zero bridge maxWithdraw came from the lens");
        }
    }

    function _pause() internal {
        _swap(abi.encodeCall(IVbUsdc.pause, ()));
        IVbUsdc token = _token();
        assertTrue(token.paused());
        assertEq(token.maxDeposit(LXLY_BRIDGE), 0);
        assertEq(token.maxMint(LXLY_BRIDGE), 0);
        assertEq(token.maxWithdraw(LXLY_BRIDGE), 0);
        assertEq(token.maxRedeem(LXLY_BRIDGE), 0);
        _rule();
        console.log("pause: token is paused");
        console.log("maxDeposit, maxMint, maxWithdraw, and maxRedeem are 0 because of the pause, not an empty vault");
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
            _rule();
            console.log("collectYield: no yield, call reverts NoYield");
            return;
        }

        _swap(abi.encodeCall(IVbUsdc.collectYield, ()));
        assertEq(token.balanceOf(recipient), balanceBefore + outstanding);
        assertEq(token.yield(), 0);
        _rule();
        console.log(string.concat("collectYield: minted ", _usdc(outstanding), " of vbUSDC to the yield recipient"));
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
        _rule();
        console.log("drain: V1 shares are 0");
        console.log(string.concat("  reserved ", _usdc(token.reservedAssets())));
    }

    function _switchYieldVault() internal {
        _rule();
        _assertV2GatesOpen();
        address oldVault = _token().yieldVault();

        _swap(abi.encodeCall(IVbUsdc.setYieldVault, (STEAKHOUSE_USDC)));

        assertEq(_token().yieldVault(), STEAKHOUSE_USDC);
        assertEq(IERC20(USDC).allowance(VB_USDC, oldVault), 0);
        assertEq(IERC20(USDC).allowance(VB_USDC, STEAKHOUSE_USDC), type(uint256).max);
        console.log("setYieldVault: Steakhouse, old allowance cleared, new allowance is max");
    }

    function _unpause() internal {
        _swap(abi.encodeCall(IVbUsdc.unpause, ()));
        assertFalse(_token().paused());
        _rule();
        console.log("unpause: token is unpaused");
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
        _rule();
        console.log(string.concat("rebalance: deposited ", _usdc(deposited), " into Steakhouse"));
        console.log(string.concat("  reserved ", _usdc(token.reservedAssets())));
        console.log(string.concat("  staked   ", _usdc(token.stakedAssets())));
        console.log(string.concat("  Steakhouse idle unchanged ", _usdc(idleBefore)));
    }

    /// @dev After the swap the vault's own maxWithdraw is 0, so a non-zero bridge reading came from the lens.
    function _assertMaxOnV2() internal view {
        IVbUsdc token = _token();
        assertEq(IYieldVault(STEAKHOUSE_USDC).maxWithdraw(VB_USDC), 0);
        assertEq(token.maxDeposit(LXLY_BRIDGE), type(uint256).max);
        assertEq(token.maxMint(LXLY_BRIDGE), type(uint256).max);
        uint256 maxWithdraw_ = token.maxWithdraw(LXLY_BRIDGE);
        uint256 maxRedeem_ = token.maxRedeem(LXLY_BRIDGE);
        assertGt(maxWithdraw_, 0, "lens did not give the bridge a maxWithdraw");
        assertGt(maxRedeem_, 0, "lens did not give the bridge a maxRedeem");
        uint256 fromLens = VaultBridgeLiquidityLens(lens).maxWithdraw(STEAKHOUSE_USDC, VB_USDC);
        assertLe(maxWithdraw_, fromLens, "bridge maxWithdraw exceeds the lens");
        assertGe(maxWithdraw_, EXIT_ASSETS, "exit is larger than bridge maxWithdraw");

        _rule();
        console.log("after rebalance, on Steakhouse: the vault maxWithdraw is 0, so the lens answers");
        console.log("  maxDeposit and maxMint are unlimited");
        console.log(string.concat("  bridge maxWithdraw ", _usdc(maxWithdraw_)));
        console.log(string.concat("  bridge maxRedeem   ", _usdc(maxRedeem_)));
        console.log(string.concat("  lens maxWithdraw   ", _usdc(fromLens)));
        console.log(string.concat("  exit of ", _usdc(EXIT_ASSETS), " is within bridge maxWithdraw"));
    }

    function _withdrawFromV2() internal {
        IVbUsdc token = _token();
        assertGt(token.balanceOf(LXLY_BRIDGE), EXIT_ASSETS, "LxLy bridge holds no vbUSDC");

        address receiver = makeAddr("exitReceiver");
        uint256 receiverBefore = IERC20(USDC).balanceOf(receiver);
        uint256 idleBefore = IERC20(USDC).balanceOf(STEAKHOUSE_USDC);
        uint256 sharesBefore = IYieldVault(STEAKHOUSE_USDC).balanceOf(VB_USDC);
        assertLt(idleBefore, EXIT_ASSETS);

        _call(LXLY_BRIDGE, VB_USDC, abi.encodeCall(IVbUsdc.withdraw, (EXIT_ASSETS, receiver, LXLY_BRIDGE)), false);

        assertEq(IERC20(USDC).balanceOf(receiver), receiverBefore + EXIT_ASSETS);
        assertEq(IERC20(USDC).balanceOf(STEAKHOUSE_USDC), idleBefore);
        assertLt(IYieldVault(STEAKHOUSE_USDC).balanceOf(VB_USDC), sharesBefore);
        _rule();
        console.log(string.concat("withdraw ", _usdc(EXIT_ASSETS), " through the Steakhouse adapter"));
        console.log(string.concat("  receiver got ", _usdc(EXIT_ASSETS)));
        console.log(string.concat("  V2 shares before ", _grouped(sharesBefore)));
        console.log(string.concat("  V2 shares after  ", _grouped(IYieldVault(STEAKHOUSE_USDC).balanceOf(VB_USDC))));
        console.log(string.concat("  Steakhouse idle unchanged ", _usdc(idleBefore)));
    }

    function _assertSwapGas() internal view {
        assertLt(swapGas, SWAP_GAS_CEILING);
        _rule();
        console.log(string.concat("gas: ", _digits(swapCalls), " vault-swap calls used ", _grouped(swapGas)));
        console.log(string.concat("  ceiling ", _grouped(SWAP_GAS_CEILING)));
    }

    /// @dev Logs whether the V1 vault can pay a full redeem. Does not revert.
    function _warnV1Liquidity() internal view {
        address vault = _token().yieldVault();
        uint256 shares = IYieldVault(vault).balanceOf(VB_USDC);
        (bool redeemOk, bytes memory redeemData) = vault.staticcall(abi.encodeCall(IYieldVault.previewRedeem, (shares)));
        (bool withdrawOk, bytes memory withdrawData) =
            vault.staticcall(abi.encodeCall(IYieldVault.maxWithdraw, (VB_USDC)));

        _rule();
        if (!redeemOk || !withdrawOk || redeemData.length < 32 || withdrawData.length < 32) {
            console.log("WARNING: could not read V1 liquidity; the drain still runs");
            return;
        }

        uint256 owed = abi.decode(redeemData, (uint256));
        uint256 liquid = abi.decode(withdrawData, (uint256));
        if (liquid >= owed) {
            console.log("V1 position is fully liquid");
        } else {
            console.log("WARNING: V1 position is illiquid; the drain still runs");
        }
        console.log(string.concat("  V1 maxWithdraw ", _usdc(liquid)));
        console.log(string.concat("  previewRedeem  ", _usdc(owed)));
    }

    function _assertV2GatesOpen() internal view {
        IYieldVault vault = IYieldVault(STEAKHOUSE_USDC);
        assertEq(vault.asset(), USDC);
        assertEq(vault.receiveSharesGate(), address(0));
        assertEq(vault.sendSharesGate(), address(0));
        assertEq(vault.receiveAssetsGate(), address(0));
        assertEq(vault.sendAssetsGate(), address(0));
        console.log("gates: Steakhouse asset is USDC, all four gates are open");
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

    function _rule() internal pure {
        console.log("-----");
    }

    /// @dev USDC and vbUSDC use 6 decimals. Logs print whole units so the raw base units are not compared by eye.
    function _usdc(uint256 amount) private pure returns (string memory) {
        return string.concat(_grouped(amount / 1e6), ".", _frac6(amount % 1e6), " USDC");
    }

    function _grouped(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        bytes memory digits = bytes(_digits(value));
        uint256 len = digits.length;
        uint256 commas = (len - 1) / 3;
        bytes memory out = new bytes(len + commas);
        uint256 cursor = out.length;
        uint256 sinceComma;
        for (uint256 i = len; i > 0; i--) {
            cursor--;
            out[cursor] = digits[i - 1];
            sinceComma++;
            if (sinceComma == 3 && i > 1) {
                cursor--;
                out[cursor] = ",";
                sinceComma = 0;
            }
        }
        return string(out);
    }

    function _frac6(uint256 frac) private pure returns (string memory) {
        bytes memory out = new bytes(6);
        for (uint256 i = 6; i > 0; i--) {
            out[i - 1] = bytes1(uint8(48 + (frac % 10)));
            frac /= 10;
        }
        return string(out);
    }

    function _digits(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 count;
        while (temp != 0) {
            count++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(count);
        while (value != 0) {
            count--;
            buffer[count] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
        return string(buffer);
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
