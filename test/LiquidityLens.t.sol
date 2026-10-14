// SPDX-License-Identifier: LicenseRef-PolygonLabs-Open-Attribution OR LicenseRef-PolygonLabs-Source-Available
pragma solidity 0.8.29;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {GenericVaultBridgeToken} from "src/vault-bridge-tokens/GenericVaultBridgeToken.sol";
import {VaultBridgeToken} from "src/VaultBridgeToken.sol";
import {VaultBridgeTokenPart2} from "src/VaultBridgeTokenPart2.sol";
import {VaultBridgeTokenInitializer} from "src/VaultBridgeTokenInitializer.sol";
import {ILiquidityLens} from "src/etc/ILiquidityLens.sol";

import {TestVault} from "test/etc/TestVault.sol";
import {MockLiquidityLens} from "test/etc/MockLiquidityLens.sol";
import {ZeroMaxVault} from "test/etc/ZeroMaxVault.sol";

contract MintableERC20 is ERC20 {
    constructor() ERC20("Mock USD", "mUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract LiquidityLensTest is Test {
    bytes32 internal constant VB_STORAGE = hex"f082fbc4cfb4d172ba00d34227e208a31ceb0982bc189440d519185302e44700";
    address internal constant LXLY_BRIDGE = 0x2a3DD3EB832aF982ec71669E178424b10Dca2EDe;
    uint256 internal constant SLIPPAGE = 1e16;

    MintableERC20 internal asset;
    address internal owner;
    address internal user;
    address internal yieldRecipient;
    address internal migrationManager;
    address internal initializer;

    function setUp() public {
        asset = new MintableERC20();
        owner = makeAddr("owner");
        user = makeAddr("user");
        yieldRecipient = makeAddr("yieldRecipient");
        migrationManager = makeAddr("migrationManager");
        initializer = address(new VaultBridgeTokenInitializer());
        vm.etch(LXLY_BRIDGE, hex"00");
        vm.mockCall(LXLY_BRIDGE, abi.encodeWithSignature("networkID()"), abi.encode(uint32(0)));
        vm.mockCall(
            LXLY_BRIDGE, abi.encodeWithSignature("bridgeAsset(uint32,address,uint256,address,bool,bytes)"), abi.encode()
        );
    }

    function test_killSwitch_noLens_viewsDoNotRevert() public {
        TestVault vault = new TestVault(address(asset));
        vault.setMaxDeposit(type(uint256).max);
        vault.setMaxWithdraw(0);
        GenericVaultBridgeToken vbToken = _deploy(address(vault), 1e17);

        uint256 amount = 10 ether;
        _deposit(vbToken, user, amount);

        uint256 reserved = vbToken.reservedAssets();
        assertGt(reserved, 0);
        assertEq(vbToken.maxWithdraw(user), reserved);
        assertEq(vbToken.maxRedeem(user), reserved);
    }

    function test_lensUnknown_treatedAsUnknown() public {
        ZeroMaxVault vault = new ZeroMaxVault(address(asset));
        GenericVaultBridgeToken vbToken = _deploy(address(vault), 1e17);
        MockLiquidityLens lens = new MockLiquidityLens();
        lens.set(0, false);
        vm.prank(owner);
        vbToken.setLiquidityLens(address(lens));

        _deposit(vbToken, user, 10 ether);

        assertEq(vbToken.maxWithdraw(user), vbToken.reservedAssets());
    }

    function test_lensReverts_viewsDoNotRevert() public {
        ZeroMaxVault vault = new ZeroMaxVault(address(asset));
        GenericVaultBridgeToken vbToken = _deploy(address(vault), 1e17);
        MockLiquidityLens lens = new MockLiquidityLens();
        lens.set(1 ether, true);
        vm.prank(owner);
        vbToken.setLiquidityLens(address(lens));

        _deposit(vbToken, user, 10 ether);

        assertEq(vbToken.maxWithdraw(user), vbToken.reservedAssets());
        assertEq(vbToken.maxRedeem(user), vbToken.reservedAssets());
    }

    function test_hostileLens_clampedToPosition() public {
        ZeroMaxVault vault = new ZeroMaxVault(address(asset));
        GenericVaultBridgeToken vbToken = _deploy(address(vault), 1e17);
        MockLiquidityLens lens = new MockLiquidityLens();
        lens.set(type(uint256).max, false);
        vm.prank(owner);
        vbToken.setLiquidityLens(address(lens));

        _deposit(vbToken, user, 10 ether);

        uint256 position = vault.convertToAssets(vault.balanceOf(address(vbToken)));
        assertEq(vbToken.maxWithdraw(user), vbToken.reservedAssets() + position);
    }

    function test_compliantVault_shortCircuitsLens() public {
        TestVault vault = new TestVault(address(asset));
        vault.setMaxDeposit(type(uint256).max);
        vault.setMaxWithdraw(100 ether);
        GenericVaultBridgeToken vbToken = _deploy(address(vault), 1e17);
        MockLiquidityLens lens = new MockLiquidityLens();
        lens.set(1, false);
        vm.prank(owner);
        vbToken.setLiquidityLens(address(lens));

        _deposit(vbToken, user, 10 ether);

        vm.expectCall(address(lens), abi.encodeWithSelector(ILiquidityLens.maxWithdraw.selector), 0);
        uint256 maxAssets = vbToken.maxWithdraw(user);
        assertEq(maxAssets, vbToken.totalAssets());
    }

    function test_v2ShapedVault_viewsHonorLens() public {
        ZeroMaxVault vault = new ZeroMaxVault(address(asset));
        GenericVaultBridgeToken vbToken = _deploy(address(vault), 1e17);
        MockLiquidityLens lens = new MockLiquidityLens();
        lens.set(3 ether, false);
        vm.prank(owner);
        vbToken.setLiquidityLens(address(lens));

        _deposit(vbToken, user, 10 ether);

        uint256 reserved = vbToken.reservedAssets();
        assertEq(vbToken.maxWithdraw(user), reserved + 3 ether);
        assertEq(vbToken.maxRedeem(user), reserved + 3 ether);
        assertEq(vbToken.previewRedeem(reserved + 3 ether), reserved + 3 ether);
    }

    function test_executionIgnoresUnderReportingLens() public {
        TestVault vault = new TestVault(address(asset));
        vault.setMaxDeposit(type(uint256).max);
        vault.setMaxWithdraw(100 ether);
        GenericVaultBridgeToken vbToken = _deploy(address(vault), 1e17);
        MockLiquidityLens lens = new MockLiquidityLens();
        lens.set(1, false);
        vm.prank(owner);
        vbToken.setLiquidityLens(address(lens));

        _deposit(vbToken, user, 10 ether);
        vault.setMaxWithdraw(0);

        uint256 reserved = vbToken.reservedAssets();
        uint256 withdrawAmount = reserved + 1 ether;
        vm.prank(user);
        vbToken.withdraw(withdrawAmount, user, user);
        assertEq(asset.balanceOf(user), withdrawAmount);
    }

    function test_tryCatch_protectsUserRebalance() public {
        TestVault vault = new TestVault(address(asset));
        vault.setMaxDeposit(type(uint256).max);
        vault.setMaxWithdraw(100 ether);
        GenericVaultBridgeToken vbToken = _deploy(address(vault), 1e17);

        _deposit(vbToken, user, 10 ether);
        uint256 reserved = vbToken.reservedAssets();
        uint256 fromReserve = reserved - 1;
        vault.setMaxWithdraw(0);
        vault.setEnforceLimits(true);

        vm.prank(user);
        vbToken.withdraw(fromReserve, user, user);
        assertEq(asset.balanceOf(user), fromReserve);
    }

    function test_drainYieldVault_max_and_secondDrain() public {
        TestVault vault = new TestVault(address(asset));
        vault.setMaxDeposit(type(uint256).max);
        vault.setMaxWithdraw(100 ether);
        GenericVaultBridgeToken vbToken = _deploy(address(vault), 1e17);
        VaultBridgeTokenPart2 part2 = VaultBridgeTokenPart2(payable(address(vbToken)));

        _deposit(vbToken, user, 10 ether);

        uint256 vaultShares = vault.balanceOf(address(vbToken));
        vault.setMaxRedeem(vaultShares - 1);

        asset.mint(user, 20 ether);
        vm.startPrank(user);
        asset.approve(address(vbToken), 20 ether);
        part2.donateAsYield(20 ether);
        vm.stopPrank();

        vm.prank(owner);
        part2.collectYield();

        uint256 reservedBefore = vbToken.reservedAssets();
        vm.prank(owner);
        part2.drainYieldVault(type(uint256).max, true);
        assertGt(vbToken.reservedAssets(), reservedBefore);
        assertEq(vault.balanceOf(address(vbToken)), 0);

        vm.prank(owner);
        part2.drainYieldVault(type(uint256).max, true);
        assertEq(vault.balanceOf(address(vbToken)), 0);
    }

    function test_setters_adminOnly_andEvents() public {
        TestVault vault = new TestVault(address(asset));
        vault.setMaxDeposit(type(uint256).max);
        vault.setMaxWithdraw(100 ether);
        GenericVaultBridgeToken vbToken = _deploy(address(vault), 1e17);
        MockLiquidityLens lens = new MockLiquidityLens();
        address newPart2 = address(new VaultBridgeTokenPart2());
        bytes32 adminRole = vbToken.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, adminRole)
        );
        vm.prank(user);
        vbToken.setLiquidityLens(address(lens));

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, adminRole)
        );
        vm.prank(user);
        vbToken.setVaultBridgeTokenPart2(newPart2);

        vm.expectRevert(VaultBridgeToken.InvalidVaultBridgeTokenPart2.selector);
        vm.prank(owner);
        vbToken.setVaultBridgeTokenPart2(address(0));

        vm.expectEmit(true, true, true, true, address(vbToken));
        emit VaultBridgeToken.LiquidityLensSet(address(lens));
        vm.prank(owner);
        vbToken.setLiquidityLens(address(lens));

        vm.expectEmit(true, true, true, true, address(vbToken));
        emit VaultBridgeToken.LiquidityLensSet(address(0));
        vm.prank(owner);
        vbToken.setLiquidityLens(address(0));

        vm.expectEmit(true, true, true, true, address(vbToken));
        emit VaultBridgeToken.VaultBridgeTokenPart2Set(newPart2);
        vm.prank(owner);
        vbToken.setVaultBridgeTokenPart2(newPart2);
    }

    function test_storageSlot_lensAppended() public {
        TestVault vault = new TestVault(address(asset));
        vault.setMaxDeposit(type(uint256).max);
        vault.setMaxWithdraw(100 ether);
        GenericVaultBridgeToken vbToken = _deploy(address(vault), 1e17);

        bytes32 yieldVaultSlot = bytes32(uint256(VB_STORAGE) + 3);
        bytes32 part2Slot = bytes32(uint256(VB_STORAGE) + 11);
        bytes32 lensSlot = bytes32(uint256(VB_STORAGE) + 12);

        bytes32 yieldVaultBefore = vm.load(address(vbToken), yieldVaultSlot);
        bytes32 part2Before = vm.load(address(vbToken), part2Slot);
        assertEq(address(uint160(uint256(yieldVaultBefore))), address(vault));
        assertEq(vm.load(address(vbToken), lensSlot), bytes32(0));

        MockLiquidityLens lens = new MockLiquidityLens();
        vm.prank(owner);
        vbToken.setLiquidityLens(address(lens));

        assertEq(vm.load(address(vbToken), lensSlot), bytes32(uint256(uint160(address(lens)))));
        assertEq(vm.load(address(vbToken), yieldVaultSlot), yieldVaultBefore);
        assertEq(vm.load(address(vbToken), part2Slot), part2Before);
    }

    function test_zeroGuard_previewWithdrawTypedRevert() public {
        TestVault vault = new TestVault(address(asset));
        vault.setMaxDeposit(type(uint256).max);
        vault.setMaxWithdraw(0);
        GenericVaultBridgeToken vbToken = _deploy(address(vault), 1e17);

        _deposit(vbToken, user, 10 ether);

        uint256 reserved = vbToken.reservedAssets();
        vm.expectRevert(abi.encodeWithSelector(VaultBridgeToken.AssetsTooLarge.selector, reserved, reserved + 1));
        vbToken.previewWithdraw(reserved + 1);

        assertEq(vbToken.maxWithdraw(user), reserved);
    }

    function _deploy(address yieldVault, uint256 minimumReservePercentage)
        internal
        returns (GenericVaultBridgeToken vbToken)
    {
        VaultBridgeTokenPart2 part2 = new VaultBridgeTokenPart2();
        GenericVaultBridgeToken impl = new GenericVaultBridgeToken();
        VaultBridgeToken.InitializationParameters memory initParams = VaultBridgeToken.InitializationParameters({
            owner: owner,
            name: "Vault Bridge Mock",
            symbol: "vbMOCK",
            underlyingToken: address(asset),
            minimumReservePercentage: minimumReservePercentage,
            yieldVault: yieldVault,
            yieldRecipient: yieldRecipient,
            lxlyBridge: LXLY_BRIDGE,
            minimumYieldVaultDeposit: 1,
            migrationManager: migrationManager,
            yieldVaultMaximumSlippagePercentage: SLIPPAGE,
            vaultBridgeTokenPart2: address(part2)
        });
        bytes memory initData = abi.encodeCall(impl.initialize, (initializer, initParams));
        vbToken = GenericVaultBridgeToken(
            payable(address(new TransparentUpgradeableProxy(address(impl), address(this), initData)))
        );
        asset.mint(migrationManager, 1_000_000 ether);
        vm.prank(migrationManager);
        asset.approve(address(vbToken), type(uint256).max);
    }

    function _deposit(GenericVaultBridgeToken vbToken, address from, uint256 amount) internal {
        asset.mint(from, amount);
        vm.startPrank(from);
        asset.approve(address(vbToken), amount);
        vbToken.deposit(amount, from);
        vm.stopPrank();
    }
}
