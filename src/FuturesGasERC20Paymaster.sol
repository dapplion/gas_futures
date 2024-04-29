// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "account-abstraction/core/BasePaymaster.sol";
import "account-abstraction/core/UserOperationLib.sol";
import "account-abstraction/core/Helpers.sol";
import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract FuturesGasERC20Paymaster is BasePaymaster, ERC20 {
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
        /// @notice Minimum value for fake exponential
        uint256 minMintFee;
        /// @notice Fee update fraction for fake exponential
        uint256 feeUpdateFraction;
        /// @notice Target amount per block
        uint256 targetAmountPerBlock;
    }

    struct BlockGasQuota {
        uint64 blockNumber;
        uint256 usedGas;
    }

    event ConfigUpdated(PaymasterConfig tokenPaymasterConfig);
    event UserOperationSponsored(address indexed user, uint256 actualCharge, uint256 tokenId);
    event Received(address indexed sender, uint256 value);

    BlockGasQuota public blockMaxGas;
    PaymasterConfig public tokenPaymasterConfig;
    uint256 public mintGasExcess;
    uint256 public mintGasLastBlockUpdate;

    constructor(IEntryPoint _entryPoint, PaymasterConfig memory _tokenPaymasterConfig, address _owner)
        BasePaymaster(_entryPoint)
        ERC20("Gnosis Gas Futures", "GGF")
    {
        setConfig(_tokenPaymasterConfig);
        transferOwnership(_owner);
        mintGasExcess = 0;
        mintGasLastBlockUpdate = 0;
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

    /// @notice Mints new gas tokens
    /// @param _gasQuota The GasQuota struct representing the quota details
    /// @return tokenId The ID of the newly minted token
    function mint(address to, uint256 amount) public payable {
        (uint256 fee, uint256 excess) = mintFee(amount);
        uint256 value = fee * amount;
        // Limit the value transfered as front-running protection
        require(msg.value >= value, "TPM: not enough funds");
        // Update state, effects
        mintGasExcess = excess;
        _mint(to, amount);
        // Refund excess value, TODO: review for gas efficiency, but we need to know the amount ahead of time
        if (msg.value > value) {
            msg.sender.transfer(msg.value - value);
        }
    }

    /// @notice Compute the mint fee after accounting for `amount`
    /// @return fee and new excess
    function mintFee(uint256 amount) public view returns (uint256, uint256) {
        uint256 excessDelta = (block.number - mintGasLastBlockUpdate) * tokenPaymasterConfig.targetAmountPerBlock;
        uint256 excess = mintGasExcess;
        if (excessDelta > excess) {
            excess = 0;
        } else {
            excess -= excessDelta;
        }
        uint256 fee = fakeExponential(
            tokenPaymasterConfig.minMintFee,
            excess,
            tokenPaymasterConfig.feeUpdateFraction,
        )
        return (fee, excess)
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
            require(dataLength == 0, "TPM: invalid data length");
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
            _burn(userOp.sender, preCharge);

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
            // Perpetual validity
            uint48 validUntil = uint48(-1);
            uint48 validAfter = 0;

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
                _mint(userOpSender, actualCharge - preCharge);
                blockMaxGas.usedGas += preCharge - actualCharge;
            } else if (preCharge < actualCharge) {
                // Attempt to cover Paymaster's gas expenses by withdrawing the 'overdraft' from the client
                // If the transfer reverts also revert the 'postOp' to remove the incentive to cheat
                _burn(userOpSender, preCharge - actualCharge);
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

    /// @notice Computes a series expansion that resembles an exponential calculation
    /// @param factor The initial factor multiplied with the denominator
    /// @param numerator The numerator used to adjust the accumulation in the loop
    /// @param denominator The denominator used for scaling the output
    /// @return output The final computed value after completing the loop
    function fakeExponential(uint256 factor, uint256 numerator, uint256 denominator) public pure returns (uint256) {
        uint256 i = 1;
        uint256 output = 0;
        uint256 numeratorAccum = factor * denominator;

        while (numeratorAccum > 0) {
            output += numeratorAccum;
            // Safe multiplication and division to avoid overflow
            numeratorAccum = (numeratorAccum * numerator) / (denominator * i);
            i++;
        }

        return output / denominator;
    }
}

