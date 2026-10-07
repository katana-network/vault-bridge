// SPDX-License-Identifier: LicenseRef-PolygonLabs-Open-Attribution OR LicenseRef-PolygonLabs-Source-Available
pragma solidity 0.8.29;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GenericVaultBridgeToken} from "src/vault-bridge-tokens/GenericVaultBridgeToken.sol";
import {VaultBridgeTokenPart2} from "src/VaultBridgeTokenPart2.sol";
import {VaultBridgeLiquidityLens} from "src/etc/VaultBridgeLiquidityLens.sol";

interface IProxyAdmin {
    function owner() external view returns (address);
    function upgradeAndCall(address proxy, address implementation, bytes calldata data) external payable;
}

interface IVbUsdc {
    function paused() external view returns (bool);
    function version() external view returns (string memory);
    function name() external view returns (string memory);
    function asset() external view returns (address);
    function totalSupply() external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function reservedAssets() external view returns (uint256);
    function stakedAssets() external view returns (uint256);
    function yield() external view returns (uint256);
    function backingDifference() external view returns (bool positive, uint256 difference);
    function reservePercentage() external view returns (uint256);
    function yieldVault() external view returns (address);
    function yieldRecipient() external view returns (address);
    function migrationManager() external view returns (address);
    function lxlyBridge() external view returns (address);
    function minimumReservePercentage() external view returns (uint256);
    function minimumYieldVaultDeposit() external view returns (uint256);
    function yieldVaultMaximumSlippagePercentage() external view returns (uint256);
    function maxDeposit(address receiver) external view returns (uint256);
    function maxMint(address receiver) external view returns (uint256);
    function maxWithdraw(address owner) external view returns (uint256);
    function maxRedeem(address owner) external view returns (uint256);
    function previewDeposit(uint256 assets) external view returns (uint256 shares);
    function previewMint(uint256 shares) external view returns (uint256 assets);
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
    function setVaultBridgeTokenPart2(address part2) external;
    function setLiquidityLens(address lens) external;
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function mint(uint256 shares, address receiver) external returns (uint256 assets);
    function transfer(address to, uint256 value) external returns (bool);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function rebalanceReserve() external;
    function collectYield() external;
    function donateAsYield(uint256 assets) external;
    function pause() external;
    function unpause() external;
}

interface IYieldVault {
    function maxDeposit(address receiver) external view returns (uint256);
    function maxWithdraw(address owner) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @notice Proves live vbUSDC behavior on MetaMorpho V1 is unchanged by the 0.6.0 upgrade.
/// @dev Two forks of one block. The upgraded fork installs the new implementation, Part2, and liquidity lens.
///      The yield vault stays the live V1 vault. Version, implementation, Part2, and the lens are allowed to differ.
contract VbUsdcV1CompatForkTest is Test {
    address internal constant VB_USDC = 0x53E82ABbb12638F09d9e624578ccB666217a765e;
    address internal constant PROXY_ADMIN = 0x8970650CF3f1E57cA804C65B4DBcFf698789FE30;
    address internal constant USDC_SAFE = 0xf4F2f5F6bAdBE05433C4604320ecC56BbECBC04E;
    address internal constant V1_VAULT = 0xBEefb9f61CC44895d8AEc381373555a64191A9c4;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant LXLY_BRIDGE = 0x2a3DD3EB832aF982ec71669E178424b10Dca2EDe;
    address internal constant CURRENT_PART2 = 0x1C8565F454F8239B854fe62C99B90b3FC9298E80;

    bytes32 internal constant VB_STORAGE = hex"f082fbc4cfb4d172ba00d34227e208a31ceb0982bc189440d519185302e44700";
    bytes32 internal constant PART2_SLOT = bytes32(uint256(VB_STORAGE) + 11);
    bytes32 internal constant LENS_SLOT = bytes32(uint256(VB_STORAGE) + 12);
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev 1 USDC. Used for preview probes and for a reserve-sized withdrawal.
    uint256 internal constant PROBE = 1e6;
    /// @dev Deposit and mint size, capped further by the V1 vault's maxDeposit.
    uint256 internal constant DEPOSIT = 1_000e6;

    struct CallResult {
        bool ok;
        bytes data;
    }

    struct Snapshot {
        bool paused;
        string name;
        address asset;
        uint256 totalSupply;
        uint256 totalAssets;
        uint256 reservedAssets;
        uint256 stakedAssets;
        uint256 yieldAssets;
        bool backingPositive;
        uint256 backingDifference;
        uint256 reservePercentage;
        address yieldVault;
        address yieldRecipient;
        address migrationManager;
        address lxlyBridge;
        uint256 minimumReservePercentage;
        uint256 minimumYieldVaultDeposit;
        uint256 slippage;
        uint256 maxDeposit;
        uint256 maxMint;
        uint256 maxWithdrawBridge;
        uint256 maxRedeemBridge;
        uint256 bridgeBalance;
        uint256 depositorBalance;
        uint256 recipientBalance;
        uint256 receiverUsdc;
        uint256 vaultShares;
        uint256 vaultMaxWithdraw;
        uint256 vaultAssets;
        CallResult previewDepositProbe;
        CallResult previewMintProbe;
        CallResult previewWithdrawProbe;
        CallResult previewRedeemProbe;
        CallResult previewWithdrawLarge;
        CallResult previewRedeemLarge;
    }

    uint256 internal baselineFork;
    uint256 internal upgradedFork;
    /// @dev A call and the state check that follows it are one group. The next standalone check starts a new one.
    bool internal separateNextCompare;
    address internal depositor;
    address internal recipient;
    address internal receiver;

    error CallFailed(address target);

    function setUp() public {
        string memory url = vm.envOr("FORK_URL", string("mainnet"));
        baselineFork = vm.createFork(url);
        vm.selectFork(baselineFork);
        uint256 pinned = block.number;
        upgradedFork = vm.createFork(url, pinned);

        vm.selectFork(upgradedFork);
        assertEq(block.number, pinned, "forks diverged");
        vm.selectFork(baselineFork);

        depositor = makeAddr("depositor");
        recipient = makeAddr("recipient");
        receiver = makeAddr("receiver");

        vm.label(VB_USDC, "vbUSDC");
        vm.label(PROXY_ADMIN, "vbUSDC ProxyAdmin");
        vm.label(USDC_SAFE, "vbUSDC Safe");
        vm.label(V1_VAULT, "MetaMorpho V1 USDC");
        vm.label(USDC, "USDC");
        vm.label(LXLY_BRIDGE, "LxLy Bridge");
        vm.label(depositor, "depositor");
        vm.label(recipient, "recipient");
        vm.label(receiver, "receiver");
        separateNextCompare = true;
        console.log(string.concat("both forks pinned to block ", _digits(pinned)));
    }

    function test_viewsMatchOnV1AfterUpgrade() public {
        _rule();
        console.log("-- view parity: live 0.5.0 vs upgraded 0.6.0, yield vault stays MetaMorpho V1 --");
        _upgrade();
        _compare("after upgrade");
        _assertLensNotUsedWhenV1IsLiquid();
    }

    function test_callsMatchOnV1AfterUpgrade() public {
        _rule();
        console.log("-- call parity: same actions on live 0.5.0 and upgraded 0.6.0 --");
        _upgrade();
        _compare("before any calls");

        uint256 assets = _sizedDeposit();
        _fundAndApprove(depositor, assets * 2);

        _callBoth(
            depositor,
            VB_USDC,
            abi.encodeCall(IVbUsdc.deposit, (assets, depositor)),
            string.concat("deposit ", _usdc(assets)),
            true
        );
        _compare("after deposit");

        _callBoth(
            depositor,
            VB_USDC,
            abi.encodeCall(IVbUsdc.mint, (assets, depositor)),
            string.concat("mint ", _usdc(assets), " of vbUSDC"),
            true
        );
        _compare("after mint");

        _callBoth(
            depositor,
            VB_USDC,
            abi.encodeCall(IVbUsdc.transfer, (recipient, assets)),
            string.concat("transfer ", _usdc(assets), " of vbUSDC"),
            true
        );
        _compare("after transfer");

        // Live vbUSDC keeps no idle reserve, so a reserve withdrawal has nothing to draw.
        // The same donation on both forks funds that path without changing the yield vault.
        _seedReserveIfEmpty();

        uint256 fromReserve = _amountInsideReserve();
        _callBoth(
            LXLY_BRIDGE,
            VB_USDC,
            abi.encodeCall(IVbUsdc.withdraw, (fromReserve, receiver, LXLY_BRIDGE)),
            string.concat("withdraw ", _usdc(fromReserve), " from the reserve, without touching V1"),
            true
        );
        _compare("after reserve withdraw");

        uint256 fromVault = _amountFromVault();
        _callBoth(
            LXLY_BRIDGE,
            VB_USDC,
            abi.encodeCall(IVbUsdc.withdraw, (fromVault, receiver, LXLY_BRIDGE)),
            string.concat("withdraw ", _usdc(fromVault), ", which is above the reserve so it comes from V1"),
            false
        );
        _compare("after V1 withdraw");

        uint256 redeemShares = _amountFromVault();
        _callBoth(
            LXLY_BRIDGE,
            VB_USDC,
            abi.encodeCall(IVbUsdc.redeem, (redeemShares, receiver, LXLY_BRIDGE)),
            string.concat("redeem ", _usdc(redeemShares), " of vbUSDC from V1"),
            false
        );
        _compare("after V1 redeem");

        _callBoth(USDC_SAFE, VB_USDC, abi.encodeCall(IVbUsdc.rebalanceReserve, ()), "rebalanceReserve", false);
        _compare("after rebalanceReserve");

        _callBoth(USDC_SAFE, VB_USDC, abi.encodeCall(IVbUsdc.collectYield, ()), "collectYield", false);
        _compare("after collectYield");

        _callBoth(USDC_SAFE, VB_USDC, abi.encodeCall(IVbUsdc.pause, ()), "pause", true);
        _compare("after pause");
        _assertMaxWithdrawZero();

        _callBoth(USDC_SAFE, VB_USDC, abi.encodeCall(IVbUsdc.unpause, ()), "unpause", true);
        _compare("after unpause");
    }

    /// @dev Upgrades only the second fork. Records the identity fields that are allowed to change.
    function _upgrade() internal {
        vm.selectFork(baselineFork);
        assertEq(IProxyAdmin(PROXY_ADMIN).owner(), USDC_SAFE);
        assertEq(_token().version(), "0.5.0");
        assertEq(_token().yieldVault(), V1_VAULT);
        assertFalse(_token().paused());
        assertEq(_loadAddress(PART2_SLOT), CURRENT_PART2);
        assertEq(_loadAddress(LENS_SLOT), address(0));
        assertGt(_token().balanceOf(LXLY_BRIDGE), 0, "LxLy bridge holds no vbUSDC");
        _logIdentity("baseline fork: live vbUSDC, not upgraded");

        vm.selectFork(upgradedFork);
        address lens = address(new VaultBridgeLiquidityLens());
        address part2 = address(new VaultBridgeTokenPart2());
        address implementation = address(new GenericVaultBridgeToken());
        vm.label(lens, "LiquidityLens");
        vm.label(part2, "VaultBridgeTokenPart2");
        vm.label(implementation, "GenericVaultBridgeToken");

        _mustCall(
            USDC_SAFE, PROXY_ADMIN, abi.encodeCall(IProxyAdmin.upgradeAndCall, (VB_USDC, implementation, bytes("")))
        );
        assertEq(_token().version(), "0.6.0");
        assertEq(_implementation(), implementation);

        _mustCall(USDC_SAFE, VB_USDC, abi.encodeCall(IVbUsdc.setVaultBridgeTokenPart2, (part2)));
        _mustCall(USDC_SAFE, VB_USDC, abi.encodeCall(IVbUsdc.setLiquidityLens, (lens)));

        assertEq(_loadAddress(PART2_SLOT), part2);
        assertEq(_loadAddress(LENS_SLOT), lens);
        assertEq(_token().yieldVault(), V1_VAULT);
        assertFalse(_token().paused());
        _logIdentity("upgraded fork: 0.6.0, new Part2 and liquidity lens");
        console.log("yield vault is still MetaMorpho V1 on both forks");
        console.log("version, implementation, Part2, and lens are allowed to differ; every other value must match");
    }

    /// @dev V1 answers maxWithdraw itself, so a non-zero report never reaches the lens.
    function _assertLensNotUsedWhenV1IsLiquid() internal {
        vm.selectFork(upgradedFork);
        uint256 liquid = IYieldVault(V1_VAULT).maxWithdraw(VB_USDC);
        if (liquid == 0) {
            _rule();
            console.log("V1 reports 0 withdrawable USDC for vbUSDC. Views already matched.");
            console.log("This is the only path that consults the lens, and it must not change those views.");
            return;
        }

        vm.selectFork(baselineFork);
        uint256 maxWithdraw_ = _token().maxWithdraw(LXLY_BRIDGE);
        uint256 maxRedeem_ = _token().maxRedeem(LXLY_BRIDGE);
        vm.selectFork(upgradedFork);
        assertEq(_token().maxWithdraw(LXLY_BRIDGE), maxWithdraw_, "lens changed maxWithdraw");
        assertEq(_token().maxRedeem(LXLY_BRIDGE), maxRedeem_, "lens changed maxRedeem");
        _rule();
        console.log(string.concat("V1 can pay ", _usdc(liquid), " of the vbUSDC position right now"));
        console.log("that reading is non-zero, so vbUSDC uses it and does not call the lens");
        console.log(string.concat("bridge maxWithdraw matches on both forks: ", _usdc(maxWithdraw_)));
        console.log("that is the bridge's own vbUSDC balance, not the vault's full liquidity");
    }

    function _compare(string memory step) internal {
        vm.selectFork(baselineFork);
        Snapshot memory baseline = _snapshot();
        vm.selectFork(upgradedFork);
        Snapshot memory upgraded = _snapshot();
        if (separateNextCompare) _rule();
        separateNextCompare = true;
        _assertEqual(baseline, upgraded, step);
    }

    function _assertEqual(Snapshot memory left, Snapshot memory right, string memory step) internal pure {
        assertEq(left.paused, right.paused, _label(step, "paused"));
        assertEq(left.name, right.name, _label(step, "name"));
        assertEq(left.asset, right.asset, _label(step, "asset"));
        assertEq(left.totalSupply, right.totalSupply, _label(step, "totalSupply"));
        assertEq(left.totalAssets, right.totalAssets, _label(step, "totalAssets"));
        assertEq(left.reservedAssets, right.reservedAssets, _label(step, "reservedAssets"));
        assertEq(left.stakedAssets, right.stakedAssets, _label(step, "stakedAssets"));
        assertEq(left.yieldAssets, right.yieldAssets, _label(step, "yield"));
        assertEq(left.backingPositive, right.backingPositive, _label(step, "backingPositive"));
        assertEq(left.backingDifference, right.backingDifference, _label(step, "backingDifference"));
        assertEq(left.reservePercentage, right.reservePercentage, _label(step, "reservePercentage"));
        assertEq(left.yieldVault, right.yieldVault, _label(step, "yieldVault"));
        assertEq(left.yieldRecipient, right.yieldRecipient, _label(step, "yieldRecipient"));
        assertEq(left.migrationManager, right.migrationManager, _label(step, "migrationManager"));
        assertEq(left.lxlyBridge, right.lxlyBridge, _label(step, "lxlyBridge"));
        assertEq(
            left.minimumReservePercentage, right.minimumReservePercentage, _label(step, "minimumReservePercentage")
        );
        assertEq(
            left.minimumYieldVaultDeposit, right.minimumYieldVaultDeposit, _label(step, "minimumYieldVaultDeposit")
        );
        assertEq(left.slippage, right.slippage, _label(step, "slippage"));
        assertEq(left.maxDeposit, right.maxDeposit, _label(step, "maxDeposit"));
        assertEq(left.maxMint, right.maxMint, _label(step, "maxMint"));
        assertEq(left.maxWithdrawBridge, right.maxWithdrawBridge, _label(step, "maxWithdraw"));
        assertEq(left.maxRedeemBridge, right.maxRedeemBridge, _label(step, "maxRedeem"));
        assertEq(left.bridgeBalance, right.bridgeBalance, _label(step, "bridgeBalance"));
        assertEq(left.depositorBalance, right.depositorBalance, _label(step, "depositorBalance"));
        assertEq(left.recipientBalance, right.recipientBalance, _label(step, "recipientBalance"));
        assertEq(left.receiverUsdc, right.receiverUsdc, _label(step, "receiverUsdc"));
        assertEq(left.vaultShares, right.vaultShares, _label(step, "vaultShares"));
        assertEq(left.vaultMaxWithdraw, right.vaultMaxWithdraw, _label(step, "vaultMaxWithdraw"));
        assertEq(left.vaultAssets, right.vaultAssets, _label(step, "vaultAssets"));
        _assertCall(left.previewDepositProbe, right.previewDepositProbe, _label(step, "previewDeposit"));
        _assertCall(left.previewMintProbe, right.previewMintProbe, _label(step, "previewMint"));
        _assertCall(left.previewWithdrawProbe, right.previewWithdrawProbe, _label(step, "previewWithdraw"));
        _assertCall(left.previewRedeemProbe, right.previewRedeemProbe, _label(step, "previewRedeem"));
        _assertCall(left.previewWithdrawLarge, right.previewWithdrawLarge, _label(step, "previewWithdrawLarge"));
        _assertCall(left.previewRedeemLarge, right.previewRedeemLarge, _label(step, "previewRedeemLarge"));

        console.log(string.concat(step, ": state matches on both forks"));
        console.log(string.concat("  total supply       ", _usdc(left.totalSupply)));
        console.log(string.concat("  reserved           ", _usdc(left.reservedAssets)));
        console.log(string.concat("  staked in V1       ", _usdc(left.stakedAssets)));
        console.log(string.concat("  uncollected yield  ", _usdc(left.yieldAssets)));
        console.log(string.concat("  bridge maxWithdraw ", _usdc(left.maxWithdrawBridge)));
        if (left.paused) console.log("  paused             yes");
    }

    /// @param requireSuccess Matched reverts are a pass unless this step must move funds.
    function _callBoth(address caller, address target, bytes memory data, string memory step, bool requireSuccess)
        internal
    {
        (bool leftOk, bytes memory leftRet) = _call(baselineFork, caller, target, data);
        (bool rightOk, bytes memory rightRet) = _call(upgradedFork, caller, target, data);
        assertEq(leftOk, rightOk, step);
        assertEq(leftRet, rightRet, step);
        _rule();
        separateNextCompare = false;
        if (leftOk) {
            console.log(string.concat(step, ": both forks succeeded"));
            return;
        }
        console.log(string.concat(step, ": both forks reverted ", _revertName(leftRet)));
        // A required step has to move funds. Matched reverts stay a pass for the optional steps.
        assertFalse(requireSuccess, step);
    }

    function _assertMaxWithdrawZero() internal {
        vm.selectFork(baselineFork);
        assertEq(_token().maxWithdraw(LXLY_BRIDGE), 0);
        vm.selectFork(upgradedFork);
        assertEq(_token().maxWithdraw(LXLY_BRIDGE), 0);
        console.log("while paused, bridge maxWithdraw is 0 on both forks");
    }

    function _sizedDeposit() internal returns (uint256 assets) {
        vm.selectFork(baselineFork);
        uint256 maxDeposit = IYieldVault(V1_VAULT).maxDeposit(VB_USDC);
        assets = DEPOSIT;
        if (maxDeposit < assets * 2) assets = maxDeposit / 2;
        assertGt(assets, 0, "V1 maxDeposit cannot cover deposit and mint");
    }

    /// @dev Live reserve is empty because every deposit is staked. Donate on both forks so the reserve path runs.
    function _seedReserveIfEmpty() internal {
        vm.selectFork(baselineFork);
        uint256 reserved = _token().reservedAssets();
        if (reserved > 0) {
            _rule();
            console.log(string.concat("reserve already holds ", _usdc(reserved), "; no donation"));
            return;
        }

        address donor = makeAddr("donor");
        _fundAndApprove(donor, PROBE);
        _callBoth(
            donor,
            VB_USDC,
            abi.encodeCall(IVbUsdc.donateAsYield, (PROBE)),
            string.concat("donate ", _usdc(PROBE), " into the empty reserve"),
            true
        );
        _compare("after seeding reserve");
    }

    /// @dev An amount the reserve can pay without touching the V1 vault.
    function _amountInsideReserve() internal returns (uint256 assets) {
        vm.selectFork(baselineFork);
        uint256 reserved = _token().reservedAssets();
        uint256 bridgeBalance = _token().balanceOf(LXLY_BRIDGE);
        assertGt(reserved, 0, "no reserve");
        assets = reserved > PROBE ? PROBE : reserved;
        if (assets > bridgeBalance) assets = bridgeBalance;
        assertGt(assets, 0, "reserve withdraw is zero");
        assertLe(assets, reserved, "reserve withdraw reaches the vault");
    }

    /// @dev Strictly larger than the reserve, so a successful call must withdraw from V1.
    ///      Capped by the bridge balance and, when V1 reports liquidity, by that liquidity.
    function _amountFromVault() internal returns (uint256 assets) {
        vm.selectFork(baselineFork);
        uint256 reserved = _token().reservedAssets();
        uint256 bridgeBalance = _token().balanceOf(LXLY_BRIDGE);
        uint256 liquid = IYieldVault(V1_VAULT).maxWithdraw(VB_USDC);

        uint256 extra = DEPOSIT;
        if (liquid != 0 && extra > liquid) extra = liquid;

        assertGt(bridgeBalance, reserved, "bridge balance does not exceed the reserve");
        assets = reserved + extra;
        if (assets > bridgeBalance) assets = bridgeBalance;
        assertGt(assets, reserved, "amount does not pull from the V1 vault");
    }

    function _fundAndApprove(address user, uint256 amount) internal {
        _fund(baselineFork, user, amount);
        _fund(upgradedFork, user, amount);
    }

    function _fund(uint256 forkId, address user, uint256 amount) internal {
        vm.selectFork(forkId);
        deal(USDC, user, amount);
        vm.prank(user);
        IERC20(USDC).approve(VB_USDC, amount);
    }

    function _snapshot() internal view returns (Snapshot memory snap) {
        IVbUsdc token = _token();
        address vault = token.yieldVault();
        uint256 reserved = token.reservedAssets();
        uint256 large = reserved + 1;

        snap.paused = token.paused();
        snap.name = token.name();
        snap.asset = token.asset();
        snap.totalSupply = token.totalSupply();
        snap.totalAssets = token.totalAssets();
        snap.reservedAssets = reserved;
        snap.stakedAssets = token.stakedAssets();
        snap.yieldAssets = token.yield();
        (snap.backingPositive, snap.backingDifference) = token.backingDifference();
        snap.reservePercentage = token.reservePercentage();
        snap.yieldVault = vault;
        snap.yieldRecipient = token.yieldRecipient();
        snap.migrationManager = token.migrationManager();
        snap.lxlyBridge = token.lxlyBridge();
        snap.minimumReservePercentage = token.minimumReservePercentage();
        snap.minimumYieldVaultDeposit = token.minimumYieldVaultDeposit();
        snap.slippage = token.yieldVaultMaximumSlippagePercentage();
        snap.maxDeposit = token.maxDeposit(LXLY_BRIDGE);
        snap.maxMint = token.maxMint(LXLY_BRIDGE);
        snap.maxWithdrawBridge = token.maxWithdraw(LXLY_BRIDGE);
        snap.maxRedeemBridge = token.maxRedeem(LXLY_BRIDGE);
        snap.bridgeBalance = token.balanceOf(LXLY_BRIDGE);
        snap.depositorBalance = token.balanceOf(depositor);
        snap.recipientBalance = token.balanceOf(recipient);
        snap.receiverUsdc = IERC20(USDC).balanceOf(receiver);
        snap.vaultShares = IYieldVault(vault).balanceOf(VB_USDC);
        snap.vaultMaxWithdraw = IYieldVault(vault).maxWithdraw(VB_USDC);
        snap.vaultAssets = IYieldVault(vault).convertToAssets(snap.vaultShares);
        snap.previewDepositProbe = _tryView(abi.encodeCall(IVbUsdc.previewDeposit, (PROBE)));
        snap.previewMintProbe = _tryView(abi.encodeCall(IVbUsdc.previewMint, (PROBE)));
        snap.previewWithdrawProbe = _tryView(abi.encodeCall(IVbUsdc.previewWithdraw, (PROBE)));
        snap.previewRedeemProbe = _tryView(abi.encodeCall(IVbUsdc.previewRedeem, (PROBE)));
        snap.previewWithdrawLarge = _tryView(abi.encodeCall(IVbUsdc.previewWithdraw, (large)));
        snap.previewRedeemLarge = _tryView(abi.encodeCall(IVbUsdc.previewRedeem, (large)));
    }

    function _tryView(bytes memory data) internal view returns (CallResult memory result) {
        (result.ok, result.data) = VB_USDC.staticcall(data);
    }

    function _assertCall(CallResult memory left, CallResult memory right, string memory label) internal pure {
        assertEq(left.ok, right.ok, label);
        assertEq(left.data, right.data, label);
    }

    function _rule() internal pure {
        console.log("-----");
    }

    function _logIdentity(string memory label) internal view {
        address lens = _loadAddress(LENS_SLOT);
        _rule();
        console.log(label);
        console.log("  version        ", _token().version());
        console.log("  implementation ", _implementation());
        console.log("  part2          ", _loadAddress(PART2_SLOT));
        if (lens == address(0)) console.log("  lens            none");
        else console.log("  lens           ", lens);
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

    function _revertName(bytes memory ret) private pure returns (string memory) {
        bytes4 selector = _selector(ret);
        if (selector == bytes4(keccak256("NoNeedToRebalanceReserve()"))) return "NoNeedToRebalanceReserve";
        if (selector == bytes4(keccak256("NoYield()"))) return "NoYield";
        if (selector == bytes4(keccak256("CannotRebalanceReserve()"))) return "CannotRebalanceReserve";
        if (selector == bytes4(keccak256("Error(string)"))) return "Error(string)";
        return string.concat("unrecognized ", _hex4(selector));
    }

    function _hex4(bytes4 selector) private pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory out = new bytes(10);
        out[0] = "0";
        out[1] = "x";
        for (uint256 i; i < 4; i++) {
            out[2 + i * 2] = alphabet[uint8(selector[i] >> 4)];
            out[3 + i * 2] = alphabet[uint8(selector[i] & 0x0f)];
        }
        return string(out);
    }

    function _mustCall(address caller, address target, bytes memory data) internal {
        vm.prank(caller);
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) _bubble(target, ret);
    }

    function _call(uint256 forkId, address caller, address target, bytes memory data)
        internal
        returns (bool ok, bytes memory ret)
    {
        vm.selectFork(forkId);
        vm.prank(caller);
        (ok, ret) = target.call(data);
    }

    function _bubble(address target, bytes memory ret) private pure {
        if (ret.length == 0) revert CallFailed(target);
        assembly {
            revert(add(ret, 32), mload(ret))
        }
    }

    function _selector(bytes memory ret) private pure returns (bytes4 selector) {
        if (ret.length < 4) return bytes4(0);
        assembly {
            selector := mload(add(ret, 32))
        }
    }

    function _label(string memory step, string memory field) private pure returns (string memory) {
        return string.concat(step, ": ", field);
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
