// SPDX-License-Identifier: LicenseRef-PolygonLabs-Open-Attribution OR LicenseRef-PolygonLabs-Source-Available
pragma solidity 0.8.29;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {GenericVaultBridgeToken} from "src/vault-bridge-tokens/GenericVaultBridgeToken.sol";
import {VaultBridgeToken} from "src/VaultBridgeToken.sol";
import {VaultBridgeTokenPart2} from "src/VaultBridgeTokenPart2.sol";
import {VaultBridgeTokenInitializer} from "src/VaultBridgeTokenInitializer.sol";

import {ZeroMaxVault} from "test/etc/ZeroMaxVault.sol";
import {MockLiquidityLens} from "test/etc/MockLiquidityLens.sol";
import {TestVault} from "test/etc/TestVault.sol";

contract IntegrationAsset is ERC20 {
    constructor() ERC20("Integration USD", "iUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Local end-to-end path against a V2-shaped yield vault (max* = 0).
contract MorphoV2IntegrationTest is Test {
    address internal constant LXLY_BRIDGE = 0x2a3DD3EB832aF982ec71669E178424b10Dca2EDe;

    IntegrationAsset internal asset;
    ZeroMaxVault internal vault;
    MockLiquidityLens internal lens;
    GenericVaultBridgeToken internal vbToken;
    VaultBridgeTokenPart2 internal part2;
    address internal owner;
    address internal user;
    address internal yieldRecipient;

    function setUp() public {
        asset = new IntegrationAsset();
        vault = new ZeroMaxVault(address(asset));
        lens = new MockLiquidityLens();
        lens.set(type(uint256).max, false);

        owner = makeAddr("owner");
        user = makeAddr("user");
        yieldRecipient = makeAddr("yieldRecipient");
        address migrationManager = makeAddr("migrationManager");

        vm.etch(LXLY_BRIDGE, hex"00");
        vm.mockCall(LXLY_BRIDGE, abi.encodeWithSignature("networkID()"), abi.encode(uint32(0)));
        vm.mockCall(
            LXLY_BRIDGE, abi.encodeWithSignature("bridgeAsset(uint32,address,uint256,address,bool,bytes)"), abi.encode()
        );

        part2 = new VaultBridgeTokenPart2();
        GenericVaultBridgeToken impl = new GenericVaultBridgeToken();
        address initializer = address(new VaultBridgeTokenInitializer());
        VaultBridgeToken.InitializationParameters memory initParams = VaultBridgeToken.InitializationParameters({
            owner: owner,
            name: "Vault Bridge iUSD",
            symbol: "vbiUSD",
            underlyingToken: address(asset),
            minimumReservePercentage: 1e17,
            yieldVault: address(vault),
            yieldRecipient: yieldRecipient,
            lxlyBridge: LXLY_BRIDGE,
            minimumYieldVaultDeposit: 1,
            migrationManager: migrationManager,
            yieldVaultMaximumSlippagePercentage: 1e16,
            vaultBridgeTokenPart2: address(part2)
        });
        bytes memory initData = abi.encodeCall(impl.initialize, (initializer, initParams));
        vbToken = GenericVaultBridgeToken(
            payable(address(new TransparentUpgradeableProxy(address(impl), address(this), initData)))
        );
        part2 = VaultBridgeTokenPart2(payable(address(vbToken)));

        vm.prank(owner);
        vbToken.setLiquidityLens(address(lens));
    }

    function test_depositWithdrawDrainAndSetYieldVault() public {
        uint256 amount = 10 ether;
        asset.mint(user, amount);
        vm.startPrank(user);
        asset.approve(address(vbToken), amount);
        uint256 shares = vbToken.deposit(amount, user);
        vm.stopPrank();
        assertEq(shares, amount);
        assertEq(vault.maxWithdraw(address(vbToken)), 0);
        assertGt(vault.balanceOf(address(vbToken)), 0);
        assertEq(vbToken.maxWithdraw(user), amount);

        uint256 withdrawAmount = 2 ether;
        vm.prank(user);
        vbToken.withdraw(withdrawAmount, user, user);
        assertEq(asset.balanceOf(user), withdrawAmount);
        assertEq(vbToken.balanceOf(user), amount - withdrawAmount);

        vault.setWithdrawReverts(true);
        uint256 reserved = vbToken.reservedAssets();
        uint256 fromReserve = reserved > 0.09 ether ? reserved - 0.08 ether : reserved / 2;
        vm.prank(user);
        vbToken.withdraw(fromReserve, user, user);
        vault.setWithdrawReverts(false);

        uint256 reservedBeforeDrain = vbToken.reservedAssets();
        vm.prank(owner);
        part2.drainYieldVault(type(uint256).max, true);
        assertGt(vbToken.reservedAssets(), reservedBeforeDrain);
        assertEq(vault.balanceOf(address(vbToken)), 0);

        TestVault nextVault = new TestVault(address(asset));
        nextVault.setMaxDeposit(type(uint256).max);
        nextVault.setMaxWithdraw(type(uint256).max);
        vm.prank(owner);
        part2.setYieldVault(address(nextVault));
        assertEq(address(vbToken.yieldVault()), address(nextVault));
    }
}
