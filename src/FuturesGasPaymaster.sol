// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "account-abstraction/core/BasePaymaster.sol";

contract FuturesGasPaymaster is BasePaymaster {
    using UserOperationLib for PackedUserOperation;

    struct TokenPaymasterConfig {
        /// @notice Exchange tokens to native currency if the EntryPoint balance of this Paymaster falls below this value
        uint128 entryPointBalanceLowWaterMark;
        uint128 entryPointBalanceHighWaterMark;

        /// @notice Estimated gas cost for refunding tokens after the transaction is completed
        uint48 refundPostopCost;

        /// @notice Max block gas
        uint48 maxBlockGas;
    }

    struct BlockGasQuota {
        uint64 blockNumber;
        uint64 usedGas;
    }

    struct GasQuota {
        address owner;
        uint32 validFromDayNumber;
        uint32 validToDayNumber;
        /// Day number of usedGas
        uint32 dayNumber;
        // With 5 second blocks, u64 allows 1067519911 MGas / day
        uint64 maxDailyGas;
        /// Total used gas for `dayNumber`
        uint64 usedGas;
    }

    event ConfigUpdated(TokenPaymasterConfig tokenPaymasterConfig);
    event UserOperationSponsored(address indexed user, uint256 actualTokenCharge, uint256 actualGasCost, uint256 actualTokenPriceWithMarkup);

    uint256 nextTokenId;
    mapping(uint256 => GasQuota) public gasQuotas;
    BlockGasQuota public blockMasGas;
    TokenPaymasterConfig public tokenPaymasterConfig;

    constructor(
        IEntryPoint _entryPoint,
        TokenPaymasterConfig memory _tokenPaymasterConfig,
        address _owner
    )
    BasePaymaster(_entryPoint)
    {
        nextTokenId = 1;
        setTokenPaymasterConfig(_tokenPaymasterConfig);
        transferOwnership(_owner);
    }

    /// @notice Updates the configuration for the Token Paymaster.
    /// @param _tokenPaymasterConfig The new configuration struct.
    function setTokenPaymasterConfig(
        TokenPaymasterConfig memory _tokenPaymasterConfig
    ) public onlyOwner {
        require(
            _tokenPaymasterConfig.entryPointBalanceHighWaterMark > _tokenPaymasterConfig.entryPointBalanceLowWaterMark,
            "TPM: bad config"
        );
        tokenPaymasterConfig = _tokenPaymasterConfig;
        emit ConfigUpdated(_tokenPaymasterConfig);
    }

    /// @notice Mints a new gas quota
    function mintGasQuota(GasQuota memory _gasQuota) public onlyOwner {
        require(_gasQuota.validFromDayNumber < _gasQuota.validToDayNumber, "TPM: bad quota");
        require(_gasQuota.dayNumber == 0, "TPM: bad quota");
        require(_gasQuota.usedGas == 0, "TPM: bad quota");
        uint256 tokenId = nextTokenId;
        nextTokenId += 1;
        gasQuotas[tokenId] = _gasQuota;
    }

    /// @notice Validates a paymaster user operation and calculates the required token amount for the transaction.
    /// @param userOp The user operation data.
    /// @param requiredPreFund The maximum cost (in native token) the paymaster has to prefund.
    /// @return context The context containing the token amount and user sender address (if applicable).
    /// @return validationResult A uint256 value indicating the result of the validation (always 0 in this implementation).
    function _validatePaymasterUserOp(PackedUserOperation calldata userOp, bytes32, uint256 requiredPreFund)
    internal
    override
    returns (bytes memory context, uint256 validationResult) {unchecked {
            uint256 dataLength = userOp.paymasterAndData.length - PAYMASTER_DATA_OFFSET;
            require(dataLength == 0 || dataLength == 32, "TPM: invalid data length");
            uint256 maxFeePerGas = userOp.unpackMaxFeePerGas();
            uint256 refundPostopCost = tokenPaymasterConfig.refundPostopCost;
            require(refundPostopCost < userOp.unpackPostOpGasLimit(), "TPM: postOpGasLimit too low");
            // Charge the sender on the validate step, and refund on postOp
            uint256 preCharge = requiredPreFund + (refundPostopCost * maxFeePerGas);
            
            // Assert block limits
            if (blockMaxGas.blockNumber < block.number) {
                blockMaxGas.blockNumber = block.number;
                blockMaxGas.usedGas = 0;
            }
            require(blockMaxGas.usedGas + preCharge < tokenPaymasterConfig.maxBlockGas, "TPM: maxBlockGas");
            blockMaxGas.usedGas += preCharge;

            // Assert user gas limits
            userBalance = userBalances[userOp.sender];
            uint32 dayNumber = block.timestamp / 1 days;
            if (userBalance.dayNumber < dayNumber) {
                userBalance.dayNumber = dayNumber;
                userBalance.usedGas = 0;
            }
            require(userBalance.usedGas < userBalance.maxDailyGas, "TPM: maxDailyGas");
            userBalance.usedGas += preCharge;
            // Assert user time validity
            uint48 validUntil = userBalance.validFromDayNumber * 1 days;
            uint48 validAfter = userBalance.validToDayNumber * 1 days;
            
            context = abi.encode(preCharge, userOp.sender);
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
    function _postOp(PostOpMode, bytes calldata context, uint256 actualGasCost, uint256 actualUserOpFeePerGas) internal override {
        unchecked {
            uint256 priceMarkup = tokenPaymasterConfig.priceMarkup;
            (
                uint256 preCharge,
                address userOpSender
            ) = abi.decode(context, (uint256, address));
            // Refund based on actual gas cost
            uint256 actualCharge = actualGasCost + tokenPaymasterConfig.refundPostopCost * actualUserOpFeePerGas;

            if (preCharge > actualCharge) {
                // If the initially provided amount is greater than the actual amount needed, refund the difference
                usedBalance[userOpSender] -= preCharge - actualCharge;
                blockMaxGas.usedGas += preCharge - actualCharge;
            } else if (preCharge < actualCharge) {
                // Attempt to cover Paymaster's gas expenses by withdrawing the 'overdraft' from the client
                // If the transfer reverts also revert the 'postOp' to remove the incentive to cheat
                usedBalance[userOpSender] += actualCharge - preCharge;
                blockMaxGas.usedGas += actualCharge - preCharge;
            }

            emit UserOperationSponsored(userOpSender, actualTokenNeeded, actualGasCost, cachedPriceWithMarkup);
            refillEntryPointDeposit(_cachedPrice);
        }
    }

    /// @notice If necessary this function uses this Paymaster's balance to refill the deposit on EntryPoint
    /// @param _cachedPrice the token price that will be used to calculate the swap amount.
    function refillEntryPointDeposit(uint256 _cachedPrice) private {
        uint256 currentEntryPointBalance = entryPoint.balanceOf(address(this));
        if (
            currentEntryPointBalance < tokenPaymasterConfig.entryPointBalanceLowWaterMark
        ) {
            uint256 value = tokenPaymasterConfig.entryPointBalanceHighWaterMark - currentEntryPointBalance;
            entryPoint.depositTo{value: value}(address(this));
        }
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    /// @notice Allows the contract owner to withdraw a specified amount of native tokens from the contract.
    /// @param to The address to transfer the tokens to.
    /// @param amount The amount of tokens to transfer.
    function withdrawEth(address payable recipient, uint256 amount) external onlyOwner {
        (bool success,) = recipient.call{value: amount}("");
        require(success, "withdraw failed");
    }

    /// @notice Allows the contract owner to withdraw a specified amount of tokens from the contract.
    /// @param to The address to transfer the tokens to.
    /// @param amount The amount of tokens to transfer.
    function withdrawToken(address to, uint256 amount) external onlyOwner {
        SafeERC20.safeTransfer(token, to, amount);
    }

    function increaseGasQuota(GasQuota gasQuota, uint128 delta) internal pure returns (GasQuota) {
        if (gasQuota.blockNumber < block.number) {
            gasQuota.blockNumber = block.number;
            gasQuota.usedGas = 0;
        }
        gasQuota.usedGas += delta;
        return gasQuota;
    }
}
