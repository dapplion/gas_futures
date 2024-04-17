// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/FuturesGasPaymaster.sol";
import "account-abstraction/core/Entrypoint.sol";
import "account-abstraction/interfaces/PackedUserOperation.sol";
import "account-abstraction/samples/SimpleAccountFactory.sol";

contract FuturesGasPaymasterTest is Test {
    FuturesGasPaymaster public paymaster;
    EntryPoint public entrypoint;
    SimpleAccountFactory public account_factory;
    address public paymaster_owner;

    function setUp() public {
        entrypoint = new EntryPoint();

        FuturesGasPaymaster.PaymasterConfig memory tokenPaymasterConfig = FuturesGasPaymaster.PaymasterConfig({
            entryPointBalanceLowWaterMark: 0,
            entryPointBalanceHighWaterMark: 0,
            refundPostopCost: 0,
            maxBlockGas: 30000000
        });
        paymaster_owner = address(1001);
        paymaster = new FuturesGasPaymaster(entrypoint, tokenPaymasterConfig, paymaster_owner);

        account_factory = new SimpleAccountFactory(entrypoint);
    }

    function test_FullFlow() public {
        // Fund paymaster
        // TODO: Should increase the deposit in the entrypoint for the paymaster
        hoax(msg.sender); // <- hoax mints 2^128 ETH
        payable(address(paymaster)).transfer(1 ether);

        uint256 userPrivKey = 123;
        address userAddress = vm.addr(userPrivKey);

        // Create a new simple account for user
        SimpleAccount userSCAddr = account_factory.createAccount(userAddress, 0);


        // Mint new gas quota for user
        {
            uint32 dayNumber = uint32(block.timestamp / 1 days);
            FuturesGasPaymaster.GasQuota memory gasQuota = FuturesGasPaymaster.GasQuota({
                owner: userAddress,
                validFromDayNumber: dayNumber,
                validToDayNumber: dayNumber,
                dayNumber: 0,
                maxDailyGas: 1000000,
                usedGas: 0
            });

            assertEq(paymaster.owner(), paymaster_owner);
            vm.prank(paymaster_owner);
            paymaster.mintGasQuota(gasQuota);
        }


        address bundler_addr = address(1002);

         // hard-code default at 100k. should add "create2" cost
        uint128 verificationGasLimit = 200000;
        // estimating call to account, and add rough entryPoint overhead
        uint128 callGasLimit = 55000; 
        // TODO
        uint128 maxPriorityFeePerGas = 0; 
         // TODO
        uint128 maxFeePerGas = uint128(block.basefee);

        // Stack too deep fix, from https://ethereum.stackexchange.com/questions/19587/how-to-fix-stack-too-deep-error
        bytes memory paymasterAndData;
        {
            // Default from eth-infinitism/account-abstraction
            uint128 paymasterVerificationGasLimit = 300000; 
            // TODO
            uint128 paymasterPostOpGasLimit = 0;
            // TODO
            bytes memory paymasterData = bytes("0x");
            paymasterAndData = abi.encodePacked(address(paymaster), paymasterVerificationGasLimit, paymasterPostOpGasLimit, paymasterData);
        }

        // beneficiary is the collector for all the fees in the user operations
        address payable beneficiary = payable(bundler_addr);


        bytes32 messageHash = keccak256("test");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivKey, messageHash);

        // Now prepare a user operation and send it to the entrypoint
        PackedUserOperation memory op = PackedUserOperation({
            sender: userAddress,
            nonce: 0,
            initCode: hex"", // no need for init code as the account should already be deployed
            callData: hex"fff612",
            accountGasLimits: bytes32(abi.encodePacked(verificationGasLimit, callGasLimit)),
            preVerificationGas: 0,
            gasFees: bytes32(abi.encodePacked(maxPriorityFeePerGas, maxFeePerGas)),
            paymasterAndData: paymasterAndData,
            signature: abi.encode(v, r, s)
        });

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        entrypoint.handleOps(ops, beneficiary);
    }

    /// Prepare init code for account
    function getInitCode(address userAddress) internal returns (bytes memory) {
        uint256 salt = 69420;
        bytes memory encodedFunction = abi.encodeWithSignature(
            "createAccount(address,uint256)",
            userAddress,
            salt
        );
        return abi.encodePacked(address(account_factory), encodedFunction);
    }
}
