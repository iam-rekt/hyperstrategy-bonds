# HyperStrategy Bonds

Bond products for building HSTR liquidity and growing the HyperStrategy treasury on HyperEVM.

## The bonds

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

This repository contains the bond contracts, shared libraries and minimal Foundry configuration. Solidity 0.8.30; OpenZeppelin Contracts is pinned as a Git submodule.

```sh
git clone --recurse-submodules https://github.com/iam-rekt/hyperstrategy-bonds.git
cd hyperstrategy-bonds
forge build
```

For an existing clone, initialize dependencies with `git submodule update --init --recursive`.

## Coming next

Options and trading products are being developed separately and will be added in stages:

- **CALL:** fully cash-secured, capped exposure to HYPE upside.
- **PUT:** fully cash-secured payouts when HYPE finishes below the strike.
- **DEGEN:** funded Bull/Bear positions with a bounded expiry payoff.

Their implementation is not included in this repository.

## Status

This is a source release for the new bond suite, not a deployment or launch announcement. Products require their own verified setup, funding and activation. The contracts are not presented as independently audited.

## License

MIT. Dependencies retain their upstream licenses.
