// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IUniswapV3Pool, INonfungiblePositionManager} from "./interfaces/IUniswapV3.sol";
import {V3TickMath} from "./libraries/V3TickMath.sol";
import {ZapMath} from "./libraries/ZapMath.sol";
import {AnchoredZap} from "./libraries/AnchoredZap.sol";

/// @title HSTRConvertibleTrancheIII
/// @notice The next convertible-bond tranche, built to BE the bond factory: set it via
///         `HSTR.setBondFactory(this)` and it inherits HSTR's exclusive mint right.
///
///   DEPOSIT (window, opens at ISSUANCE_START):  1 bond per USD₮0 (18dp, face = full deposit).
///   Split at ingest:
///       (100% − LP split) → ESCROWED IN THIS CONTRACT until the outcome is recorded. It is
///                           the cash leg of every bond; the treasury receives it only after
///                           an HSTR outcome is fully funded, or after cash claims are paid
///                           or expire. settle()/fundHstr() push it automatically;
///                           releaseToTreasury() sends whatever becomes free later.
///       LP split          → zapped with an ANCHORED LIMIT ORDER (see libraries/AnchoredZap):
///                           the depositor cannot sandwich the buy, nothing reverts, and any
///                           unspent part carries into the next deposit's zap. The position
///                           is a HSTR/USD₮0 LP owned by
///                           THIS CONTRACT — sacrosanct while the window is open. From
///                           MATURITY_END the owner may hand the position to the treasury
///                           (releasePolToTreasury), which then manages it like any LP.
///                           Depositor money literally builds the liquidity their option
///                           pays out on.
///
///   SETTLEMENT (at window close — `noteDuration` may be 0), one outcome for every bond:
///       closing TWAP < strike  → redeem() pays (100% − LP split) of principal + coupon
///                                from the escrow held here. No treasury allowance is involved.
///       closing TWAP ≥ strike  → the HSTR outcome and its fixed reserve are RECORDED first;
///                                the reserve is then minted here (fundHstr — attempted at
///                                settlement, retryable by anyone). convert() pays `1/K` HSTR
///                                per bond at FULL face. Cash redemption is permanently
///                                disabled in this outcome.
///   The TWAP ends at MATURITY_END even if settlement is called later. Once recorded,
///   neither later prices nor later factory handoffs change the claim entitlement.
///   Recording never depends on mint authority or on `halted`, so an operational delay can
///   not let the pool's finite oracle history age out before the outcome is known. If the
///   closing history is nevertheless unavailable SETTLE_GRACE after maturity, the outcome
///   defaults to Cash (escrow is always there to pay it) — never to a later price.
///
///   CLAIM WINDOW: redeem must be claimed within `CLAIM_WINDOW` (7 days) after
///   MATURITY_END — unclaimed bonds expire and the treasury's redemption obligation is
///   final. Funded HSTR claims do not expire and remain claimable while halted.
///
///   DILUTION DISCIPLINE: zero HSTR exists because of this contract unless the market closed
///   AT OR ABOVE the strike. The complete conversion allocation is minted once, capped at
///   `maxMintableHstr`; users subsequently claim that allocation, without minting.
///   Below-strike settlement mints no HSTR. Any coupon must be prefunded into this contract.
///
/// @dev Assumes HSTR's mint is gated to `setBondFactory`-designated callers (verified live:
///      reverts "Only bond factory can call this function" otherwise). Not audited.
contract HSTRConvertibleTrancheIII is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────── Immutables ────────────────────────────────

    IERC20 public immutable USDT0;
    IERC20 public immutable HSTR;

    /// @dev HSTR exposes mint(address,uint256) gated to the bond factory (this contract, once
    ///      `setBondFactory` points here). Declared separately from the ERC20 view.
    function _mintHstr(address to, uint256 amount) internal returns (bool ok) {
        (ok,) = address(HSTR).call(abi.encodeWithSignature("mint(address,uint256)", to, amount));
    }
    IUniswapV3Pool public immutable BOND_POOL; // HSTR/USD₮0 — prices conversion & hosts the POL leg
    INonfungiblePositionManager public immutable NPM;
    address public immutable TREASURY;

    uint256 public immutable ISSUANCE_START;
    uint256 public immutable ISSUANCE_END;
    /// @notice Redemption/conversion open from this timestamp. With noteDuration = 0 this
    ///         EQUALS ISSUANCE_END: the sale window IS the whole note — deposit, let the LP
    ///         split do its work, settle at close. Never earlier than that — intra-window redemption is a griefing loop on
    ///         the LP split, and intra-window conversion would let self-pumped TWAP mint the
    ///         whole ceiling without a dollar of genuine demand.
    uint256 public immutable MATURITY_END;
    /// @notice Last timestamp at which redeem() can be called: MATURITY_END + CLAIM_WINDOW.
    ///         Unclaimed bonds expire here — the treasury's redemption liability is final.
    uint256 public immutable CLAIM_END;
    uint256 public immutable STRIKE_USD18; // usd18 per whole HSTR at conversion
    uint256 public immutable MAX_USDC; // raise capacity, raw 6dp
    /// @notice Per-address deposit ceiling, raw 6dp (0 = uncapped); not an identity limit.
    uint256 public immutable MAX_USDT_PER_WALLET;
    uint256 public immutable COUPON_BPS; // of principal, paid on redeem
    uint256 public immutable LP_SPLIT_BPS; // of each deposit routed into the permanent LP
    uint256 public immutable MAX_MINTABLE_HSTR; // hard lifetime ceiling on converted supply

    int24 public immutable TICK_LOWER;
    int24 public immutable TICK_UPPER;
    uint24 public immutable POOL_FEE;

    // ──────────────────────────────── Constants ─────────────────────────────────

    uint256 private constant Q96 = 1 << 96;
    uint160 private constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    /// @notice How long after settlement holders may redeem. Hardcoded so the deploy
    ///         surface stays untouched.
    uint256 private constant CLAIM_WINDOW = 7 days;

    /// @notice If the pool no longer holds the closing observations this long after maturity,
    ///         settlement records Cash instead of reverting forever. Escrow always covers it.
    uint256 public constant SETTLE_GRACE = 24 hours;

    /// @notice Closing TWAP window; configurable only before the first funded deposit.
    uint32 public twapWindow = 1800;

    // ──────────────────────────────── Accounting ────────────────────────────────

    uint256 public usdcDeposited; // raw 6dp raised
    mapping(address => uint256) public depositedUsdt; // raw 6dp, cumulative per wallet
    mapping(address => uint256) public bondBalance; // 1e18-scale bonds ($1 each)
    uint256 public totalBondsOutstanding;

    enum Settlement {
        Unsettled,
        Cash,
        Hstr
    }
    Settlement public settlement;
    uint256 public settlementPriceUsd18;
    uint256 public hstrReserve; // HSTR owed to all holders, fixed when an HSTR outcome is recorded
    uint256 public hstrMinted; // minted into this contract; equals hstrReserve once funded
    uint256 public hstrClaimed;
    bool public halted; // stops deposits and the reserve mint; never recording, cash or funded claims

    uint256 public polTokenId;
    uint256 public polUsdtDeployed;

    /// @notice LP-split USD₮0 not yet deployed: the anchored zap buys less when the pool has been
    ///         pushed above its anchor, and whatever it did not spend joins the next deposit's zap.
    ///         Anything still here at settlement is released to the treasury with the residue.
    uint256 public zapCarry;
    /// @dev Where this contract's own latest zap left the price (see {AnchoredZap}).
    AnchoredZap.LastZap private _lastZap;

    enum SwapInFlight {
        None,
        Bond
    }
    SwapInFlight private _swapInFlight;

    // ────────────────────────────────── Events ──────────────────────────────────

    event Bonded(address indexed user, uint256 usdtIn, uint256 lpSplit, uint256 escrowed);
    event Redeemed(address indexed user, uint256 bonds, uint256 principal, uint256 payout);
    event Converted(address indexed user, uint256 bonds, uint256 hstrOut, uint256 twapUsd18);
    event Settled(Settlement outcome, uint256 closingTwapUsd18, uint256 hstrReserved);
    event HstrFunded(uint256 amount);
    event ReleasedToTreasury(uint256 usdt0, uint256 hstr);
    event LpZap(uint256 hstrBought, uint256 usdtDeployed, uint256 usdtCarried);
    event PolFeesCollected(uint256 amount0, uint256 amount1);
    event PolReleased(uint256 tokenId, address to);

    // ─────────────────────────────────── Errors ──────────────────────────────────

    error IssuanceNotStarted();
    error IssuanceClosed();
    error RaiseCapped();
    error WalletCapped();
    error NotMature();
    error ClaimWindowClosed();
    error NothingToRedeem();
    error BelowStrike();
    error CashRedemptionUnavailable();
    error MintCeiling();
    error HstrUnfunded();
    error TwapUnseasoned();
    error SettlementHistoryUnavailable();
    error TermsLocked();
    error Halted();
    error NoSwapInFlight();
    error BadCallback();
    error UseProtectedDeposit();
    error SlippageExceeded();
    error DepositExpired();

    // ───────────────────────────────── Constructor ─────────────────────────────

    constructor(
        address usdt0_,
        address hstr_,
        address bondPool_,
        address npm_,
        address treasury_,
        uint256 issuanceStart_, // unix time deposits open; deploy and verify ahead of it
        uint256 issuanceDuration_, // seconds from issuanceStart_
        uint256 noteDuration_, // seconds after ISSUANCE_END (0 = settle at window close)
        uint256 strikeUsd18_,
        uint256 maxUsdc_,
        uint256 maxUsdtPerWallet_,
        uint256 couponBps_,
        uint256 lpSplitBps_,
        uint256 maxMintableHstr_,
        int24 tickLower_,
        int24 tickUpper_,
        address owner_
    ) Ownable(owner_) {
        require(treasury_ != address(0), "tranche: treasury is zero");
        require(IUniswapV3Pool(bondPool_).token0() == hstr_, "tranche: bond token0 != HSTR");
        require(IUniswapV3Pool(bondPool_).token1() == usdt0_, "tranche: bond token1 != USDT0");
        require(issuanceStart_ >= block.timestamp && issuanceDuration_ > 0 && npm_.code.length > 0, "tranche: bad setup");
        require(tickLower_ < tickUpper_ && tickLower_ >= -887272 && tickUpper_ <= 887272, "tranche: bad range");
        require(strikeUsd18_ > 0 && maxUsdc_ > 0, "tranche: bad params");
        require(lpSplitBps_ <= 5_000, "tranche: split too high");
        require(maxUsdtPerWallet_ <= maxUsdc_ && couponBps_ <= 10000, "tranche: invalid caps/coupon");
        require(Math.mulDiv(maxUsdc_, 1e30, strikeUsd18_) <= maxMintableHstr_, "tranche: mint ceiling below capacity");

        USDT0 = IERC20(usdt0_);
        HSTR = IERC20(hstr_);
        BOND_POOL = IUniswapV3Pool(bondPool_);
        NPM = INonfungiblePositionManager(npm_);
        TREASURY = treasury_;
        ISSUANCE_START = issuanceStart_;
        ISSUANCE_END = issuanceStart_ + issuanceDuration_;
        halted = true; // Configuration and activation are separate from deployment.
        MATURITY_END = ISSUANCE_END + noteDuration_;
        CLAIM_END = MATURITY_END + CLAIM_WINDOW;
        STRIKE_USD18 = strikeUsd18_;
        MAX_USDC = maxUsdc_;
        MAX_USDT_PER_WALLET = maxUsdtPerWallet_;
        COUPON_BPS = couponBps_;
        LP_SPLIT_BPS = lpSplitBps_;
        MAX_MINTABLE_HSTR = maxMintableHstr_;
        TICK_LOWER = tickLower_;
        TICK_UPPER = tickUpper_;
        POOL_FEE = IUniswapV3Pool(bondPool_).fee();
    }

    // ─────────────────────────────────── Deposit ────────────────────────────────

    /// @notice Mint bonds: 1 bond (1e18) per USD₮0, strictly before issuance closes.
    /// @dev Kept for zero-LP issuances only. An LP deposit must supply execution bounds.
    function mintBonds(uint256 amountUsdt0) external nonReentrant {
        if (LP_SPLIT_BPS != 0) revert UseProtectedDeposit();
        _deposit(amountUsdt0, 0, 0, block.timestamp);
    }

    /// @notice Deposit with absolute minimum swap output, LP liquidity and a deadline.
    /// @return bought HSTR purchased by the zap, usable for a non-broadcast quote.
    /// @return liquidityAdded LP liquidity minted or added by this deposit.
    function mintBondsProtected(uint256 amountUsdt0, uint256 minHstr, uint128 minLiquidity, uint256 deadline)
        external nonReentrant returns (uint256 bought, uint128 liquidityAdded)
    {
        // Minima are optional: the anchored zap already protects the LP leg, and a depositor's
        // bonds never depend on how the zap executed. Zero means "never revert on price".
        return _deposit(amountUsdt0, minHstr, minLiquidity, deadline);
    }

    function _deposit(uint256 amountUsdt0, uint256 minHstr, uint128 minLiquidity, uint256 deadline)
        private returns (uint256 bought, uint128 liquidityAdded)
    {
        if (block.timestamp > deadline) revert DepositExpired();
        require(amountUsdt0 > 0, "tranche: zero deposit");
        if (halted) revert Halted();
        if (block.timestamp < ISSUANCE_START) revert IssuanceNotStarted();
        if (block.timestamp >= ISSUANCE_END) revert IssuanceClosed();
        if (usdcDeposited + amountUsdt0 > MAX_USDC) revert RaiseCapped();
        if (MAX_USDT_PER_WALLET != 0 && depositedUsdt[msg.sender] + amountUsdt0 > MAX_USDT_PER_WALLET) {
            revert WalletCapped();
        }

        uint256 before = IERC20(USDT0).balanceOf(address(this));
        IERC20(USDT0).safeTransferFrom(msg.sender, address(this), amountUsdt0);
        amountUsdt0 = IERC20(USDT0).balanceOf(address(this)) - before; // fee-on-transfer safe

        uint256 split = (amountUsdt0 * LP_SPLIT_BPS) / 10_000;
        uint256 rest = amountUsdt0 - split;

        if (split > 0) {
            (bought, liquidityAdded) = _polZap(split);
            if (bought < minHstr || liquidityAdded < minLiquidity) revert SlippageExceeded();
        } else if (LP_SPLIT_BPS != 0) revert SlippageExceeded();
        // `rest` stays here as escrow: it is the cash leg until the outcome is recorded.

        usdcDeposited += amountUsdt0;
        depositedUsdt[msg.sender] += amountUsdt0;
        bondBalance[msg.sender] += amountUsdt0 * 1e12; // $1 of principal = 1e18 bonds
        totalBondsOutstanding += amountUsdt0 * 1e12;
        emit Bonded(msg.sender, amountUsdt0, split, rest);
    }

    // ──────────────────────────────── Settlement ────────────────────────────────

    /// @notice Record the closing TWAP outcome once, for all holders, and try to fund it.
    ///         Permissionless and idempotent. Call promptly after maturity while the pool
    ///         retains the closing observations; there is deliberately no live-price fallback.
    function settle() external nonReentrant returns (Settlement) {
        return _settle();
    }

    function _settle() private returns (Settlement outcome) {
        outcome = settlement;
        if (outcome != Settlement.Unsettled) return outcome;
        if (block.timestamp < MATURITY_END) revert NotMature();

        uint256 mark;
        try this.closingTwapUsd18() returns (uint256 closing) {
            mark = closing;
            outcome = mark >= STRIKE_USD18 ? Settlement.Hstr : Settlement.Cash;
        } catch (bytes memory reason) {
            // Only a genuine, permanent loss of oracle history may select the fallback, and only
            // after the grace period. Anything else (including an out-of-gas inner call, which
            // returns no data) bubbles up so a caller cannot force the outcome.
            if (block.timestamp < MATURITY_END + SETTLE_GRACE || !_isHistoryLoss(reason)) {
                assembly {
                    revert(add(reason, 32), mload(reason))
                }
            }
            outcome = Settlement.Cash; // escrow covers it; never substitutes a later price
        }

        settlement = outcome;
        settlementPriceUsd18 = mark;
        uint256 reserved;
        if (outcome == Settlement.Hstr) {
            reserved = Math.mulDiv(totalBondsOutstanding, 1e18, STRIKE_USD18);
            hstrReserve = reserved;
        }
        emit Settled(outcome, mark, reserved);
        // Best effort from here on: nothing below may undo the recording above.
        if (outcome == Settlement.Hstr) _fundHstr(); // fundHstr() retries; releases the escrow on success
        else _release(false); // cash outcome: only residue above the full liability
    }

    function _isHistoryLoss(bytes memory reason) private pure returns (bool) {
        if (reason.length < 4) return false;
        bytes4 selector;
        assembly {
            selector := mload(add(reason, 32))
        }
        return selector == TwapUnseasoned.selector || selector == SettlementHistoryUnavailable.selector
            || keccak256(reason) == keccak256(abi.encodeWithSignature("Error(string)", "OLD"));
    }

    /// @dev Mints the recorded reserve exactly once. Returns false (never reverts the caller's
    ///      recording) while halted or while this contract lacks HSTR mint authority.
    function _fundHstr() private returns (bool) {
        if (settlement != Settlement.Hstr) return false;
        uint256 owed = hstrReserve;
        if (hstrMinted == owed) return true;
        if (halted) return false;
        if (owed > MAX_MINTABLE_HSTR) revert MintCeiling(); // unreachable: constructor bounds capacity
        uint256 before = HSTR.balanceOf(address(this));
        if (!_mintHstr(address(this), owed)) return false;
        require(HSTR.balanceOf(address(this)) - before == owed, "tranche: reserve not minted");
        hstrMinted = owed;
        emit HstrFunded(owed);
        _release(false); // every HSTR claim is now backed: the escrowed cash leg goes to the treasury
        return true;
    }

    /// @notice Retry minting the recorded HSTR reserve (after mint authority or a halt is fixed).
    function fundHstr() external nonReentrant {
        if (_settle() != Settlement.Hstr) revert BelowStrike();
        if (!_fundHstr()) revert HstrUnfunded();
    }

    /// @notice True once every recorded HSTR claim is backed by tokens held here.
    function hstrFunded() public view returns (bool) {
        return settlement == Settlement.Hstr && hstrMinted == hstrReserve;
    }

    /// @notice Cash-only settlement: redeem the escrowed share plus any coupon within the
    ///         seven-day window. A closing TWAP at/above strike permanently excludes cash.
    function redeem(uint256 bonds) external nonReentrant {
        if (block.timestamp < MATURITY_END) revert NotMature();
        if (block.timestamp > CLAIM_END) revert ClaimWindowClosed();
        uint256 bal = bondBalance[msg.sender];
        require(bonds > 0 && bal >= bonds, "tranche: balance");
        if (_settle() != Settlement.Cash) revert CashRedemptionUnavailable();
        bondBalance[msg.sender] = bal - bonds;
        totalBondsOutstanding -= bonds;

        // Bonds are $1 each (1e18 scale); USD out is raw 6dp. Payout = (100% − LP split)
        // of face, paid from the escrow this contract has held since the deposit.
        uint256 principal = bonds / 1e12;
        uint256 payout = (principal * (10_000 - LP_SPLIT_BPS)) / 10_000;
        if (COUPON_BPS > 0) payout += (principal * COUPON_BPS) / 10_000;

        IERC20(USDT0).safeTransfer(msg.sender, payout);
        emit Redeemed(msg.sender, bonds, principal, payout);
    }

    /// @notice HSTR-only settlement: consume bonds for their fixed strike-priced entitlement.
    ///         Holders may claim later even if price falls, the factory changes or deposits halt.
    function convert(uint256 bonds) external nonReentrant {
        if (block.timestamp < MATURITY_END) revert NotMature();
        uint256 bal = bondBalance[msg.sender];
        require(bonds > 0 && bal >= bonds, "tranche: balance");
        if (_settle() != Settlement.Hstr) revert BelowStrike();
        if (!_fundHstr()) revert HstrUnfunded();

        // bonds ($1 each, 1e18) ÷ strike (usd18 per whole HSTR) → whole-HSTR wei.
        uint256 tokens = Math.mulDiv(bonds, 1e18, STRIKE_USD18);
        bondBalance[msg.sender] = bal - bonds;
        totalBondsOutstanding -= bonds;
        hstrClaimed += tokens;
        HSTR.safeTransfer(msg.sender, tokens);
        emit Converted(msg.sender, bonds, tokens, settlementPriceUsd18);
    }

    /// @notice Send everything this contract no longer owes to the (immutable) treasury.
    ///         Permissionless. After an HSTR outcome the escrow is released only once every
    ///         HSTR claim is funded; after a cash outcome the outstanding liability stays here
    ///         until it is redeemed or the claim window closes. Also recovers zap residue.
    /// @dev Settlement and funding already push automatically; this is for what becomes free
    ///      later (expired cash claims, late residue) or if an automatic push could not complete.
    function releaseToTreasury() external nonReentrant returns (uint256 usdtOut, uint256 hstrOut) {
        _settle();
        return _release(true);
    }

    /// @param strict Revert on a failed transfer. The automatic pushes pass false: a transfer
    ///        that cannot complete must never block recording the outcome or funding claims.
    function _release(bool strict) private returns (uint256 usdtOut, uint256 hstrOut) {
        uint256 usdtBal = IERC20(USDT0).balanceOf(address(this));
        uint256 usdtOwed = settlement == Settlement.Hstr ? (hstrFunded() ? 0 : usdtBal) : cashRedemptionLiability();
        if (usdtBal > usdtOwed && _send(IERC20(USDT0), usdtBal - usdtOwed, strict)) usdtOut = usdtBal - usdtOwed;
        uint256 hstrBal = HSTR.balanceOf(address(this));
        uint256 hstrOwed = hstrMinted - hstrClaimed;
        if (hstrBal > hstrOwed && _send(HSTR, hstrBal - hstrOwed, strict)) hstrOut = hstrBal - hstrOwed;
        if (usdtOut != 0 || hstrOut != 0) emit ReleasedToTreasury(usdtOut, hstrOut);
    }

    function _send(IERC20 token, uint256 amount, bool strict) private returns (bool ok) {
        if (strict) {
            token.safeTransfer(TREASURY, amount);
            return true;
        }
        (bool success, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transfer, (TREASURY, amount)));
        ok = success && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (uint256)) == 1));
    }

    /// @notice The settlement mark: TWAP over `twapWindow` ending exactly at MATURITY_END.
    function closingTwapUsd18() external view returns (uint256) {
        if (block.timestamp < MATURITY_END) revert NotMature();
        return _twapUsd18EndingAt(MATURITY_END);
    }

    /// @notice Current settlement TWAP in usd18 (reverts unseasoned).
    function twapUsd18() external view returns (uint256) {
        return _twapUsd18EndingAt(block.timestamp);
    }

    /// @notice A recorded HSTR outcome, or an unsettled closing price that qualifies for HSTR.
    ///         Before settlement this can revert if historical oracle data is unavailable.
    function conversionOpen() external view returns (bool) {
        if (settlement != Settlement.Unsettled) return settlement == Settlement.Hstr;
        return block.timestamp >= MATURITY_END && _twapUsd18EndingAt(MATURITY_END) >= STRIKE_USD18;
    }

    /// @notice Conservative cash obligation while unsettled or in the cash outcome.
    ///         Becomes zero at a recorded HSTR outcome, or after the cash claim deadline.
    ///         Escrow held here always covers it (plus a prefunded coupon, if any).
    function cashRedemptionLiability() public view returns (uint256) {
        if (settlement == Settlement.Hstr || block.timestamp > CLAIM_END) return 0;
        uint256 principal = totalBondsOutstanding / 1e12;
        return Math.mulDiv(principal, 10_000 - LP_SPLIT_BPS, 10_000) + Math.mulDiv(principal, COUPON_BPS, 10_000);
    }

    // ──────────────────────────────── Price plumbing ────────────────────────────

    function growOracle(uint16 next) external {
        BOND_POOL.increaseObservationCardinalityNext(next);
    }

    function _obsIndex(IUniswapV3Pool pool) private view returns (uint16 idx) {
        (,, idx,,,,) = pool.slot0();
    }

    function _twapSeasoned(IUniswapV3Pool pool, uint32 window) private view returns (bool ok) {
        (,,, uint16 card,,,) = pool.slot0();
        if (card <= 1) return false;
        uint256[2] memory candidates;
        candidates[0] = 0;
        candidates[1] = (uint256(_obsIndex(pool)) + 1) % card;
        for (uint256 i; i < 2; ++i) {
            (uint32 ts,,, bool initialized) = pool.observations(candidates[i]);
            if (initialized && block.timestamp - ts >= window) return true;
        }
        return false;
    }

    /// @dev usd18 per whole HSTR from the windowed mean tick; floor-corrected for negative ticks.
    function _twapUsd18EndingAt(uint256 end) private view returns (uint256) {
        uint256 elapsed = block.timestamp - end;
        if (elapsed > type(uint32).max - twapWindow) revert SettlementHistoryUnavailable();
        uint32 oldest = uint32(elapsed) + twapWindow;
        if (!_twapSeasoned(BOND_POOL, oldest)) revert TwapUnseasoned();
        uint32[] memory ago = new uint32[](2);
        ago[0] = oldest;
        ago[1] = uint32(elapsed);
        (int56[] memory tc,) = BOND_POOL.observe(ago);
        int56 delta = tc[1] - tc[0];
        int24 avgTick = int24(delta / int56(uint56(twapWindow)));
        if (delta < 0 && delta % int56(uint56(twapWindow)) != 0) avgTick--;
        uint160 sqrtP = V3TickMath.getSqrtRatioAtTick(avgTick);
        return Math.mulDiv(Math.mulDiv(sqrtP, sqrtP, Q96), 1e30, Q96);
    }

    // ──────────────────────────────── POL leg & owner ───────────────────────────

    /// @dev Concentrated position owned by this contract; grows with every deposit's LP
    ///      split. No reduction/exit while the window is open; after settlement the owner
    ///      can release the NFT to the treasury (releasePolToTreasury).
    function _polZap(uint256 split) private returns (uint256 bought, uint128 liquidityAdded) {
        uint256 net = split + zapCarry;
        (uint160 sqrtP,,,,,,) = BOND_POOL.slot0();
        uint256 swapIn = ZapMath.optimalSwapIn(net, BOND_POOL.liquidity(), sqrtP, POOL_FEE);
        require(swapIn > 0 && swapIn < net, "tranche: bad zap size");

        // The depositor picks minHstr/minLiquidity but the protocol's LP leg bears the slippage,
        // so the buy is a LIMIT order anchored where the depositor cannot move it. A pumped pool
        // makes it buy less — never pay more — and the remainder waits for the next deposit.
        (uint160 limitSqrtP, bool fillable) = AnchoredZap.limit(BOND_POOL, twapWindow, _lastZap, swapIn, POOL_FEE);
        uint256 spent;
        if (fillable) {
            _swapInFlight = SwapInFlight.Bond;
            (int256 a0, int256 a1) = BOND_POOL.swap(address(this), false, int256(swapIn), limitSqrtP, "");
            _swapInFlight = SwapInFlight.None;
            bought = uint256(-a0);
            spent = uint256(a1);
        }
        uint256 used1;
        if (bought > 0) {
            uint256 pair = net - spent;
            IERC20(HSTR).forceApprove(address(NPM), bought);
            IERC20(USDT0).forceApprove(address(NPM), pair);
            if (polTokenId == 0) {
                uint256 tokenId;
                (tokenId, liquidityAdded,, used1) = NPM.mint(
                    INonfungiblePositionManager.MintParams({
                        token0: address(HSTR),
                        token1: address(USDT0),
                        fee: POOL_FEE,
                        tickLower: TICK_LOWER,
                        tickUpper: TICK_UPPER,
                        amount0Desired: bought,
                        amount1Desired: pair,
                        amount0Min: 0,
                        amount1Min: 0,
                        recipient: address(this), // until released to the treasury after maturity
                        deadline: block.timestamp
                    })
                );
                polTokenId = tokenId;
            } else {
                (liquidityAdded,, used1) = NPM.increaseLiquidity(
                    INonfungiblePositionManager.IncreaseLiquidityParams({
                        tokenId: polTokenId,
                        amount0Desired: bought,
                        amount1Desired: pair,
                        amount0Min: 0,
                        amount1Min: 0,
                        deadline: block.timestamp
                    })
                );
            }
            IERC20(HSTR).forceApprove(address(NPM), 0);
            IERC20(USDT0).forceApprove(address(NPM), 0);
            _lastZap = AnchoredZap.snapshot(BOND_POOL);
        }
        zapCarry = net - spent - used1;
        polUsdtDeployed += spent + used1;
        emit LpZap(bought, spent + used1, zapCarry);
    }

    /// @notice Sweep the POL position's earned fees to the treasury. Liquidity stays put.
    ///         Open at any time — the LP leg is only locked from being REDUCED, not from
    ///         earning.
    function collectPolFees() external onlyOwner nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(polTokenId != 0, "tranche: no pol position");
        (amount0, amount1) = NPM.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: polTokenId, recipient: TREASURY, amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
        emit PolFeesCollected(amount0, amount1);
    }

    /// @notice Hand the POL position NFT to the treasury. Owner-only, and only AFTER
    ///         settlement: while the window is open the LP is sacrosanct (live deposits
    ///         settle against that depth); from MATURITY_END on the treasury owns the
    ///         position and manages it — reduce, withdraw, claim — through the position
    ///         manager like any other LP position. Until release, fees can be swept
    ///         anytime via collectPolFees(). polUsdtDeployed keeps the historical total
    ///         zapped by this contract.
    function releasePolToTreasury() external onlyOwner nonReentrant {
        if (block.timestamp < MATURITY_END) revert NotMature();
        require(polTokenId != 0, "tranche: no pol position");
        _settle(); // record the closing outcome before the treasury can remove its liquidity
        uint256 id = polTokenId;
        NPM.safeTransferFrom(address(this), TREASURY, id);
        IERC20(HSTR).forceApprove(address(NPM), 0); // mint-time approvals are stale — zero them
        IERC20(USDT0).forceApprove(address(NPM), 0);
        polTokenId = 0;
        emit PolReleased(id, TREASURY);
    }

    /// @dev Terms may be configured before the first funded deposit, then remain fixed.
    function setTwapWindow(uint32 w) external onlyOwner {
        if (usdcDeposited != 0 || block.timestamp >= MATURITY_END) revert TermsLocked();
        require(w >= 120 && w <= 4 hours, "tranche: bad window");
        twapWindow = w;
    }

    /// @notice Stops deposits and the mint of an unfunded HSTR reserve. Recording the outcome,
    ///         funded HSTR claims and cash redemption remain available while halted.
    ///         Fund all HSTR claims BEFORE handing mint authority to a new tranche.
    function setHalted(bool halted_) external onlyOwner {
        halted = halted_;
    }

    // ──────────────────────────────── Swap callback ─────────────────────────────

    function uniswapV3SwapCallback(int256, int256 amount1Delta, bytes calldata) external {
        if (_swapInFlight != SwapInFlight.Bond || msg.sender != address(BOND_POOL)) revert BadCallback();
        if (amount1Delta > 0) IERC20(USDT0).safeTransfer(msg.sender, uint256(amount1Delta));
    }
}
