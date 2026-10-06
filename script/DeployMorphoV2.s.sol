// SPDX-License-Identifier: LicenseRef-PolygonLabs-Open-Attribution OR LicenseRef-PolygonLabs-Source-Available
pragma solidity 0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {VaultBridgeLiquidityLens} from "src/etc/VaultBridgeLiquidityLens.sol";
import {VaultBridgeTokenPart2} from "src/VaultBridgeTokenPart2.sol";
import {GenericVaultBridgeToken} from "src/vault-bridge-tokens/GenericVaultBridgeToken.sol";
import {VbETH} from "src/vault-bridge-tokens/vbETH/VbETH.sol";

interface IProxyAdmin {
    function owner() external view returns (address);
    function upgradeAndCall(ITransparentUpgradeableProxy proxy, address implementation, bytes memory data)
        external
        payable;
}

/// @notice Deploys Morpho V2 lens upgrade implementations. Does not upgrade live proxies.
/// @dev `forge script script/DeployMorphoV2.s.sol:DeployMorphoV2 --sig "deploy()" --rpc-url $ETH_RPC --broadcast`
/// @dev `forge script script/DeployMorphoV2.s.sol:DeployMorphoV2 --sig "printUpgrade()" --rpc-url $ETH_RPC`
contract DeployMorphoV2 is Script {
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    address internal constant VB_USDT = 0x6d4f9f9f8f0155509ecd6Ac6c544fF27999845CC;
    address internal constant VB_USDT_PROXY_ADMIN = 0x377a9e5df2882DC1DF8A0bD162cbc640eA634010;
    address internal constant VB_USDT_OWNER = 0x2De242e27386e224E5fbF110EA8406d5B70740ec;

    address internal constant VB_USDC = 0x53E82ABbb12638F09d9e624578ccB666217a765e;
    address internal constant VB_USDC_PROXY_ADMIN = 0x8970650CF3f1E57cA804C65B4DBcFf698789FE30;
    address internal constant VB_USDC_OWNER = 0xf4F2f5F6bAdBE05433C4604320ecC56BbECBC04E;

    address internal constant VB_WBTC = 0x2C24B57e2CCd1f273045Af6A5f632504C432374F;
    address internal constant VB_WBTC_PROXY_ADMIN = 0x420693B32113a0e00Eb9f3315D5D5ec3b32C2d69;
    address internal constant VB_WBTC_OWNER = 0x2De242e27386e224E5fbF110EA8406d5B70740ec;

    address internal constant VB_ETH = 0x2DC70fb75b88d2eB4715bc06E1595E6D97c34DFF;
    address internal constant VB_ETH_PROXY_ADMIN = 0x14Be6579A41342ca6B402ec85E7be538e6Ade951;
    address internal constant VB_ETH_OWNER = 0x2De242e27386e224E5fbF110EA8406d5B70740ec;

    address internal constant CURRENT_PART2 = 0x1C8565F454F8239B854fe62C99B90b3FC9298E80;

    function run() external {
        deploy();
    }

    function deploy() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        VaultBridgeLiquidityLens lens = new VaultBridgeLiquidityLens();
        VaultBridgeTokenPart2 part2 = new VaultBridgeTokenPart2();
        GenericVaultBridgeToken genericImpl = new GenericVaultBridgeToken();
        VbETH vbEthImpl = new VbETH();

        vm.stopBroadcast();

        console.log("VaultBridgeLiquidityLens", address(lens));
        console.log("VaultBridgeTokenPart2", address(part2));
        console.log("GenericVaultBridgeToken", address(genericImpl));
        console.log("VbETH", address(vbEthImpl));
        console.log(
            "This script does not upgrade proxies. Set LENS, PART2, GENERIC_IMPL, VBETH_IMPL and run printUpgrade()."
        );
    }

    function printUpgrade() public {
        address lens = vm.envAddress("LENS");
        address part2 = vm.envAddress("PART2");
        address genericImpl = vm.envAddress("GENERIC_IMPL");
        address vbEthImpl = vm.envAddress("VBETH_IMPL");

        console.log("Current shared Part2", CURRENT_PART2);
        console.log("New lens", lens);
        console.log("New Part2", part2);
        console.log("New Generic impl", genericImpl);
        console.log("New VbETH impl", vbEthImpl);
        console.log("");

        _printToken("vbUSDT", VB_USDT, VB_USDT_PROXY_ADMIN, VB_USDT_OWNER, genericImpl, part2, lens);
        _printToken("vbWBTC", VB_WBTC, VB_WBTC_PROXY_ADMIN, VB_WBTC_OWNER, genericImpl, part2, lens);
        _printToken("vbETH", VB_ETH, VB_ETH_PROXY_ADMIN, VB_ETH_OWNER, vbEthImpl, part2, lens);

        console.log("----- separate Safe batch (vbUSDC) -----");
        _printToken("vbUSDC", VB_USDC, VB_USDC_PROXY_ADMIN, VB_USDC_OWNER, genericImpl, part2, lens);
    }

    function _printToken(
        string memory name,
        address proxy,
        address proxyAdmin,
        address expectedOwner,
        address newImpl,
        address part2,
        address lens
    ) internal view {
        address adminOwner = IProxyAdmin(proxyAdmin).owner();
        require(adminOwner == expectedOwner, "ProxyAdmin owner mismatch");
        require(IAccessControl(proxy).hasRole(DEFAULT_ADMIN_ROLE, expectedOwner), "DEFAULT_ADMIN_ROLE mismatch");

        bytes memory upgradeCall = abi.encodeCall(
            IProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(payable(proxy)), newImpl, bytes(""))
        );
        bytes memory setPart2 = abi.encodeWithSignature("setVaultBridgeTokenPart2(address)", part2);
        bytes memory setLens = abi.encodeWithSignature("setLiquidityLens(address)", lens);

        console.log("Token", name);
        console.log("  proxy", proxy);
        console.log("  ProxyAdmin", proxyAdmin);
        console.log("  Safe / owner", expectedOwner);
        console.log("  1. ProxyAdmin.upgradeAndCall(proxy, newImpl, 0x)");
        console.logBytes(upgradeCall);
        console.log("  2. proxy.setVaultBridgeTokenPart2(newPart2)  [to=", proxy, "]");
        console.logBytes(setPart2);
        console.log("  3. proxy.setLiquidityLens(lens)  [to=", proxy, "]");
        console.logBytes(setLens);
        console.log("");
    }
}
