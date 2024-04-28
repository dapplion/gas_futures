// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "account-abstraction/core/BasePaymaster.sol";
import "account-abstraction/core/UserOperationLib.sol";
import "account-abstraction/core/Helpers.sol";
import "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";

contract FuturesGasNFTPaymaster is BasePaymaster, ERC721 {
    using UserOperationLib for PackedUserOperation;

    struct PaymasterConfig {
        /// @notice Deposit to the EntryPoint if balance of this Paymaster falls below this value
        uint256 entryPointBalanceLowWaterMark;
        /// @notice Deposit up to this value during an Entrypoint automatic deposit
        uint256 entryPointBalanceHighWaterMark;
        /// @notice Estimated gas cost for refunding tokens after the transaction is completed
        uint256 refundPostopCost;
        /// @notice Max block gas
        uint256 maxBlockGas;
    }

    struct BlockGasQuota {
        uint64 blockNumber;
        uint256 usedGas;
    }

    struct GasQuota {
        uint32 validFromDayNumber;
        uint32 validToDayNumber;
        /// Day number of usedGas
        uint32 dayNumber;
        // TODO: could use uint64, with 5 second blocks, u64 allows 1067519911 MGas / day
        uint256 maxDailyGas;
        /// Total used gas for `dayNumber`
        uint256 usedGas;
    }

    event ConfigUpdated(PaymasterConfig tokenPaymasterConfig);
    event UserOperationSponsored(address indexed user, uint256 actualCharge, uint256 tokenId);
    event Received(address indexed sender, uint256 value);

    uint256 nextTokenId;
    mapping(uint256 => GasQuota) public gasQuotas;
    BlockGasQuota public blockMaxGas;
    PaymasterConfig public tokenPaymasterConfig;

    constructor(IEntryPoint _entryPoint, PaymasterConfig memory _tokenPaymasterConfig, address _owner)
        BasePaymaster(_entryPoint)
        ERC721("Gnosis Gas Futures", "GGF")
    {
        nextTokenId = 0;
        setConfig(_tokenPaymasterConfig);
        transferOwnership(_owner);
    }

    /// @notice Updates the configuration for the Token Paymaster.
    /// @param _tokenPaymasterConfig The new configuration struct.
    function setConfig(PaymasterConfig memory _tokenPaymasterConfig) public onlyOwner {
        require(
            _tokenPaymasterConfig.entryPointBalanceHighWaterMark >= _tokenPaymasterConfig.entryPointBalanceLowWaterMark,
            "TPM: bad config"
        );
        tokenPaymasterConfig = _tokenPaymasterConfig;
        emit ConfigUpdated(_tokenPaymasterConfig);
    }

    /// @notice Mints a new gas quota
    /// @param _gasQuota The GasQuota struct representing the quota details
    /// @return tokenId The ID of the newly minted token
    function mintGasQuota(GasQuota memory _gasQuota, address to) public onlyOwner returns (uint256) {
        require(_gasQuota.validFromDayNumber <= _gasQuota.validToDayNumber, "TPM: bad quota");
        require(_gasQuota.dayNumber == 0, "TPM: bad quota");
        require(_gasQuota.usedGas == 0, "TPM: bad quota");
        uint256 tokenId = nextTokenId;
        nextTokenId += 1;
        _safeMint(to, tokenId);
        gasQuotas[tokenId] = _gasQuota;
        return tokenId;
    }

    /// @notice Validates a paymaster user operation and calculates the required token amount for the transaction.
    /// @param userOp The user operation data.
    /// @param requiredPreFund The maximum cost (in native token) the paymaster has to prefund.
    /// @return context The context containing the token amount and user sender address (if applicable).
    /// @return validationResult A uint256 value indicating the result of the validation (always 0 in this implementation).
    function _validatePaymasterUserOp(PackedUserOperation calldata userOp, bytes32, uint256 requiredPreFund)
        internal
        override
        returns (bytes memory context, uint256 validationResult)
    {
        unchecked {
            uint256 dataLength = userOp.paymasterAndData.length - PAYMASTER_DATA_OFFSET;
            require(dataLength == 32, "TPM: invalid data length");
            uint256 maxFeePerGas = userOp.unpackMaxFeePerGas();
            uint256 refundPostopCost = tokenPaymasterConfig.refundPostopCost;
            require(refundPostopCost < userOp.unpackPostOpGasLimit(), "TPM: postOpGasLimit too low");
            // Charge the sender on the validate step, and refund on postOp
            uint256 preCharge = requiredPreFund + (refundPostopCost * maxFeePerGas);

            {
                // Assert block limits
                uint64 blockNumber = uint64(block.number);
                if (blockMaxGas.blockNumber < blockNumber) {
                    blockMaxGas.blockNumber = blockNumber;
                    blockMaxGas.usedGas = 0;
                }
                require(blockMaxGas.usedGas + preCharge < tokenPaymasterConfig.maxBlockGas, "TPM: maxBlockGas");
                blockMaxGas.usedGas += preCharge;
            }

            // Retrieve the selected tokenId to sponsor this userAction
            uint256 tokenId =
                uint256(bytes32(userOp.paymasterAndData[PAYMASTER_DATA_OFFSET:PAYMASTER_DATA_OFFSET + 32]));
            require(tokenId < nextTokenId, "TPM: unknown tokenId");
            require(ownerOf(tokenId) == userOp.sender, "TPM: not token owner");

            GasQuota memory gasQuota = gasQuotas[tokenId];
            {
                // Assert user gas limits
                uint32 dayNumber = uint32(block.timestamp / 1 days);
                if (gasQuota.dayNumber < dayNumber) {
                    gasQuota.dayNumber = dayNumber;
                    gasQuota.usedGas = 0;
                }
                require(gasQuota.usedGas < gasQuota.maxDailyGas, "TPM: maxDailyGas");
                gasQuota.usedGas += preCharge;
            }
            // Assert user time validity
            uint48 validUntil = gasQuota.validToDayNumber * 1 days;
            uint48 validAfter = gasQuota.validFromDayNumber * 1 days;

            context = abi.encode(preCharge, tokenId, userOp.sender);
            validationResult = _packValidationData(false, validUntil, validAfter);
        }
    }

    /// @notice Performs post-operation tasks, such as updating the token price and refunding excess tokens.
    /// @dev This function is called after a user operation has been executed or reverted.
    /// @param context The context containing the token amount and user sender address.
    /// @param actualGasCost The actual gas cost of the transaction.
    /// @param actualUserOpFeePerGas - the gas price this UserOp pays. This value is based on the UserOp's maxFeePerGas
    //      and maxPriorityFee (and basefee)
    //      It is not the same as tx.gasprice, which is what the bundler pays.
    function _postOp(PostOpMode, bytes calldata context, uint256 actualGasCost, uint256 actualUserOpFeePerGas)
        internal
        override
    {
        unchecked {
            (uint256 preCharge, uint256 tokenId, address userOpSender) =
                abi.decode(context, (uint256, uint256, address));
            // Refund based on actual gas cost
            uint256 actualCharge = actualGasCost + tokenPaymasterConfig.refundPostopCost * actualUserOpFeePerGas;

            if (preCharge > actualCharge) {
                // If the initially provided amount is greater than the actual amount needed, refund the difference
                gasQuotas[tokenId].usedGas -= preCharge - actualCharge;
                blockMaxGas.usedGas += preCharge - actualCharge;
            } else if (preCharge < actualCharge) {
                // Attempt to cover Paymaster's gas expenses by withdrawing the 'overdraft' from the client
                // If the transfer reverts also revert the 'postOp' to remove the incentive to cheat
                gasQuotas[tokenId].usedGas += actualCharge - preCharge;
                blockMaxGas.usedGas += actualCharge - preCharge;
            }

            emit UserOperationSponsored(userOpSender, actualCharge, tokenId);
            refillEntryPointDeposit();
        }
    }

    /// @notice If necessary this function uses this Paymaster's balance to refill the deposit on EntryPoint
    function refillEntryPointDeposit() private {
        uint256 currentEntryPointBalance = entryPoint.balanceOf(address(this));
        if (currentEntryPointBalance < tokenPaymasterConfig.entryPointBalanceLowWaterMark) {
            uint256 value = tokenPaymasterConfig.entryPointBalanceHighWaterMark - currentEntryPointBalance;
            entryPoint.depositTo{value: value}(address(this));
        }
    }

    /// @notice Allows the contract owner to withdraw a specified amount of native tokens from the contract.
    /// @param to The address to transfer the tokens to.
    /// @param amount The amount of tokens to transfer.
    function withdrawEth(address payable to, uint256 amount) external onlyOwner {
        (bool success,) = to.call{value: amount}("");
        require(success, "withdraw failed");
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }
}
