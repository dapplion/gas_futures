## Gnosis gas futures

Background doc: https://hackmd.io/@dapplion/gnosis_gas_futures

Extend the network fee collector to allow the network to sell gas futures. This repo explores two approaches:
- Periodic dutch auctions to sell an NFT to gives right to a specific daily quota for a range of days. Every month 10 auctions are hold at 1:10 months lookahead.
- Purchase gas units as a fungible ERC-20 which can redeemed forever. There's an additive eip-1559 fee mechanism that targets to sell 10% of the block limit every block.

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
