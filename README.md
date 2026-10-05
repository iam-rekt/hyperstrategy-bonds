# HyperStrategy Bonds

Bond products for building HSTR liquidity and growing the HyperStrategy treasury on HyperEVM.

## The bonds

### Convertible Bonds — original Bond Protocol

The original HyperStrategy bond product. Participants deposit USDT0 during an issuance window and receive ERC-20 bond tokens. After maturity, redemption returns USDT0 when the stored settlement price is at or below the strike, or mints the configured asset token at the strike conversion rate when the price is above it.

Contracts: [`Bond.sol`](legacy/convertible/Bond.sol), [`BondFactory.sol`](legacy/convertible/BondFactory.sol), and [`MintableERC20.sol`](legacy/convertible/MintableERC20.sol). Supporting pricing libraries and interfaces are included alongside them.

The source is preserved from `iam-rekt/BondsProtocol` at commit `0dc1104ce3ab3e07d4a256c04961bb01525d40e6`, without changing contract logic. Legacy `USDC` identifiers refer to the hardcoded HyperEVM USDT0 address, `0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb`. Deposit units have 6 decimals; bond accounting assumes 18 decimals. The pool must order the asset as token0 and USDT0 as token1.

Important distinctions from the newer products:

- The first successful redemption stores the trailing 30-minute pool TWAP at redemption time, not a historical price anchored to the maturity timestamp. Later redemptions reuse it.
- The owner can change the oracle pool and withdraw tokens, including deposited USDT0. Cash redemption requires available funding; principal protection is not unconditional.
- Conversion mints the configured asset through the factory rather than distributing prefunded inventory. The token owner can change the authorized factory.
- Deposits go to the bond contract; this implementation does not automatically buy HYPE or deploy funds into yield strategies.

This is legacy source, not confirmation of any particular deployed series or its bytecode.

### BLBonds — Boosted Liquidity Bonds

Deposits help build protocol-owned HSTR liquidity while the remaining cash stays in escrow. At maturity, a fixed closing price determines whether holders receive HSTR at the strike or the cash redemption defined by the issuance terms.

Contract: [`HSTRConvertibleTrancheIII.sol`](contracts/HSTRConvertibleTrancheIII.sol)

### MLBonds — Matched Liquidity Bonds

Pair a user's USDT0 with treasury HSTR, or match two community participants contributing opposite assets. Each round records ownership and accounts separately for principal, trading fees and prefunded rewards.

Contract: [`HSTRMatchedLiquidityBond.sol`](contracts/HSTRMatchedLiquidityBond.sol)

### Bond Desk

Exchange HYPE or USDT0 for discounted HSTR released over time. Deposits support treasury reserves or permanent protocol-owned liquidity. HSTR entitlements are backed by prefunded inventory.

Contract: [`HSTRBondDesk.sol`](contracts/HSTRBondDesk.sol)

## Build

This repository contains bond contracts, shared libraries and minimal Foundry configuration, without deployment scripts or tests. The newer products use Solidity 0.8.30 and pinned OpenZeppelin Contracts. The original convertible bonds use a separate `convertible` profile with Solidity 0.8.28, Shanghai, and Solmate pinned to the original dependency revision (`89365b880c4f3c786bdd453d4b8e8fe410344a69`).

```sh
git clone --recurse-submodules https://github.com/iam-rekt/hyperstrategy-bonds.git
cd hyperstrategy-bonds
forge build
# Build the original convertible bonds separately:
FOUNDRY_PROFILE=convertible forge build
```

For an existing clone, initialize dependencies with `git submodule update --init --recursive`.

## Coming next

Options and trading products are being developed separately and will be added in stages:

- **CALL:** fully cash-secured, capped exposure to HYPE upside.
- **PUT:** fully cash-secured payouts when HYPE finishes below the strike.
- **DEGEN:** funded Bull/Bear positions with a bounded expiry payoff.

Their implementation is not included in this repository.

## Status

This is a source release covering the original convertible bonds and the newer bond suite, not a deployment or launch announcement. Products require their own verified setup, funding and activation. The contracts are not presented as independently audited. A successful build does not establish economic safety or live deployment equivalence.

## License

MIT. Dependencies retain their upstream licenses.
