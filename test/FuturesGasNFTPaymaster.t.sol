// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/FuturesGasNFTPaymaster.sol";
import "account-abstraction/core/EntryPoint.sol";
import "account-abstraction/core/UserOperationLib.sol";
import "account-abstraction/interfaces/PackedUserOperation.sol";
import "account-abstraction/samples/SimpleAccountFactory.sol";
import "openzeppelin-contracts/contracts/utils/cryptography/MessageHashUtils.sol";

contract FuturesGasNFTPaymasterTest is Test {
    using UserOperationLib for PackedUserOperation;

    FuturesGasNFTPaymaster public paymaster;
    EntryPoint public entrypoint;
    SimpleAccountFactory public account_factory;
    address public paymaster_owner;

    function setUp() public {
        entrypoint = new EntryPoint();

        FuturesGasNFTPaymaster.PaymasterConfig memory tokenPaymasterConfig = FuturesGasNFTPaymaster.PaymasterConfig({
            entryPointBalanceLowWaterMark: 0,
            entryPointBalanceHighWaterMark: 0,
            refundPostopCost: 0,
            maxBlockGas: 30000000
        });
        paymaster_owner = address(1001);
        paymaster = new FuturesGasNFTPaymaster(entrypoint, tokenPaymasterConfig, paymaster_owner);

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
        uint256 tokenId;
        {
            vm.warp(1700000000);
            uint32 dayNumber = uint32(block.timestamp / 1 days);
            FuturesGasNFTPaymaster.GasQuota memory gasQuota = FuturesGasNFTPaymaster.GasQuota({
                validFromDayNumber: dayNumber,
                validToDayNumber: dayNumber + 1,
                dayNumber: 0,
                maxDailyGas: 1000000,
                usedGas: 0
            });

            assertEq(paymaster.owner(), paymaster_owner);
            vm.prank(paymaster_owner);
            tokenId = paymaster.mintGasQuota(gasQuota, address(userSCAddr));
        }


        address bundler_addr = address(1002);

        // Stack too deep fix, from https://ethereum.stackexchange.com/questions/19587/how-to-fix-stack-too-deep-error
        bytes memory paymasterAndData;
        {
            // Default from eth-infinitism/account-abstraction
            uint128 paymasterVerificationGasLimit = 300000; 
            // TODO
            uint128 paymasterPostOpGasLimit = 100000;
            // TODO
            bytes memory paymasterData = abi.encodePacked(tokenId);
            paymasterAndData = abi.encodePacked(address(paymaster), paymasterVerificationGasLimit, paymasterPostOpGasLimit, paymasterData);
        }

        // beneficiary is the collector for all the fees in the user operations
        address payable beneficiary = payable(bundler_addr);


        PackedUserOperation memory userOp;
        {
            // hard-code default at 100k. should add "create2" cost
            uint128 verificationGasLimit = 200000;
            // estimating call to account, and add rough entryPoint overhead
            uint128 callGasLimit = 55000; 
            // TODO
            uint128 maxPriorityFeePerGas = 0; 
            // TODO
            uint128 maxFeePerGas = uint128(block.basefee);

            // Now prepare a user operation and send it to the entrypoint
            // must be calldata to have access to the UserOperationLib functions
            userOp = PackedUserOperation({
                sender: address(userSCAddr),
                nonce: 0,
                initCode: hex"", // no need for init code as the account should already be deployed
                callData: hex"fff612",
                accountGasLimits: bytes32(abi.encodePacked(verificationGasLimit, callGasLimit)),
                preVerificationGas: 0,
                gasFees: bytes32(abi.encodePacked(maxPriorityFeePerGas, maxFeePerGas)),
                paymasterAndData: paymasterAndData,
                signature: hex"" // set to blank to compute the hash
            });
        }

        {
            bytes32 userOpHashInner = getUserOpHash(userOp); 
            // Using console.log this `userOpHash` is correct, and matches the one passed to validateUserOp
            bytes32 userOpHash = keccak256(abi.encode(userOpHashInner, address(entrypoint), block.chainid));
            bytes32 hash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivKey, hash);
            userOp.signature = abi.encodePacked(r, s, v);
        }

        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;
        entrypoint.handleOps(userOps, beneficiary);
    }

    // Copied from upstream, to change data location to `memory`. Calldata can't be mutated.
    // https://github.com/eth-infinitism/account-abstraction/blob/2b1aac46a8b532121dab4af739bcb019f8693ae1/contracts/core/UserOperationLib.sol#L54
    function getUserOpHash(PackedUserOperation memory userOp) internal returns (bytes32) {
        address sender = userOp.sender;
        uint256 nonce = userOp.nonce;
        bytes32 hashInitCode = keccak256(userOp.initCode);
        bytes32 hashCallData = keccak256(userOp.callData);
        bytes32 accountGasLimits = userOp.accountGasLimits;
        uint256 preVerificationGas = userOp.preVerificationGas;
        bytes32 gasFees = userOp.gasFees;
        bytes32 hashPaymasterAndData = keccak256(userOp.paymasterAndData);

        bytes memory encoded = abi.encode(
            sender, nonce,
            hashInitCode, hashCallData,
            accountGasLimits, preVerificationGas, gasFees,
            hashPaymasterAndData
        );

        return keccak256(encoded);
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
