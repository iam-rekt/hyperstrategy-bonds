// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IUniswapV3Pool, INonfungiblePositionManager, IWETH9} from "./interfaces/IUniswapV3.sol";
import {V3TickMath} from "./libraries/V3TickMath.sol";
import {ZapMath} from "./libraries/ZapMath.sol";
import {AnchoredZap} from "./libraries/AnchoredZap.sol";

/// @title HSTRBondDesk
/// @notice The OHM/HAM-style bond desk: bonders SELL their capital for vested HSTR, and the
///         protocol KEEPS the capital. Two generations above the liquidity bonds:
///
///   `bondReserveHype` / `bondReserveUsdt0` — RESERVE. The whole deposit (net of nothing —
///       this mode takes no fee) is banked straight to the treasury: WHYPE for HYPE deposits,
///       USD₮0 as-is. 100% lands as counted backing. Purest DAT accumulation there is.
///
///   `bondPolHype` / `bondPolUsdt0` — POL. The deposit (after a `feeBps` cut) is converted to
///       USD₮0 — HYPE routes through the deep WHYPE/USD₮0 pool — and ZAPPED into a single
///       shared HSTR/USD₮0 position the desk owns PERMANENTLY. There is deliberately NO
///       function that moves that position out: third-party money becomes protocol-owned
///       liquidity by construction.
///
///   In exchange the bonder receives HSTR from a PRE-FUNDED STASH (the desk has no mint
///   rights), vesting linearly over `vestDuration`, claimable in slices. The amount is
///   `depositUsd / issuePrice`, where
///
///       issuePrice = max( twapPrice × (1 − discountBps),  ACCRETION FLOOR )
///       floor(RESERVE) = backingPerHstr                    (= b)
///       floor(POL)     = 2·b·m/(b+m)                       (harmonic blend with market m;
///                                                           only the LP's USD₮0 leg banks,
///                                                           so the bar sits tighter)
///
///   The BACKING inputs never read the HSTR pool. The POL blend does use the pool's TWAP mark
///   `m`, so on its own it falls with a walked-down TWAP — which is why `minIssueTick` is a HARD
///   floor applied to BOTH the spot and the TWAP mark that issuance actually prices off
///   (2026-09-19 review: checking spot alone let a walked-down TWAP plus a same-block spot
///   restore buy 2x the HSTR for ~$30). And because the floor is derived from real assets per share, the desk
///   ARITHMETICALLY CLOSES ITSELF when the market falls below backing: the issue price then
///   sits above market and no rational bonder fills. mNAV discipline enforced by arithmetic.
///
/// The POL zap is an ANCHORED LIMIT ORDER (libraries/AnchoredZap): the bonder chooses the zap's
/// limits but the protocol's POL bears the slippage, so an unanchored market buy could be
/// self-sandwiched (measured: +1,158 USD₮0 per 3,000 bond). The zap never chases a pumped pool;
/// what it does not spend is carried into the next POL bond (`polCarry`).
///
/// The desk cannot be opened until the operator has set a real `minIssueTick` and a
/// `maxHstrPerBond`: both default to "off", and an unpause with them off is refused.
///
/// Price integrity, all fail-closed:
///   - HSTR priced off the bond pool's own seasoned TWAP (`observationCardinality > 1` is
///     REQUIRED — a cardinality-1 pool answers TWAP queries with SPOT), with a hard `minIssueTick`
///     floor beneath everything and a ONE-SIDED spot/TWAP deviation band (spot may sit above the
///     average freely; only the cheap direction is bounded).
///   - HYPE valued at the LOWER of the WHYPE/USD₮0 pool's spot and TWAP, inside owner-set
///     sanity bounds — inflating the deposit price buys nothing.
///   - Backing counts native HYPE + WHYPE + USD₮0 across an owner-declared address set. Own
///     token never backs itself; POL positions are not counted either (conservative direction).
///
/// @dev Not audited. TREASURY is immutable and receives reserves as plain ERC20 transfers
///      (WHYPE/USD₮0 — never native), so no payable-treasury footgun exists here.
contract HSTRBondDesk is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────── Immutables ────────────────────────────────

    IERC20 public immutable HSTR; // the issued asset — always paid from the stash
    IERC20 public immutable USDT0; // quote asset of the bond pool
    IWETH9 public immutable WHYPE; // wrapped HYPE — reserve vehicle for HYPE deposits
    IUniswapV3Pool public immutable BOND_POOL; // HSTR/USD₮0 — prices HSTR issuance
    IUniswapV3Pool public immutable ROUTE_POOL; // WHYPE/USD₮0 — prices HYPE deposits, routes HYPE lane
    INonfungiblePositionManager public immutable NPM;
    address public immutable TREASURY;

    int24 public immutable TICK_LOWER;
    int24 public immutable TICK_UPPER;
    uint24 public immutable BOND_POOL_FEE;

    // ──────────────────────────────── Constants ─────────────────────────────────

    uint256 private constant BPS = 10_000;
    uint256 public constant MAX_FEE_BPS = 500;
    uint256 public constant MAX_DISCOUNT_BPS = 3_000;
    uint256 public constant MAX_VEST = 365 days;
    uint256 public constant EXPIRY_GRACE = 180 days;
    uint256 public constant MIN_TWAP_WINDOW = 120 seconds;
    uint256 public constant MAX_TWAP_WINDOW = 4 hours;
    uint24 public constant MAX_TICK_DEVIATION = 2_000; // ≈ 20%, one-sided (cheap direction only)
    uint256 public constant MAX_TREASURY_ADDRS = 5;

    /// @dev All USD amounts in this contract are 18-decimal fixed point ("usd18").
    uint256 private constant Q96 = 1 << 96;
    uint160 private constant MIN_SQRT_RATIO = 4295128739;
    uint160 private constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    enum Mode {
        RESERVE, // deposit banks whole to the treasury
        POL // deposit converts to permanent protocol-owned liquidity
    }

    // ──────────────────────────────── Parameters ────────────────────────────────

    uint256 public feeBps = 0; // POL-mode skim only; RESERVE never charges (100% must bank)
    uint256 public discountBps; // off the TWAP mark — the entire bonder incentive
    uint256 public vestDuration = 14 days;
    uint256 public bondDeadline;
    /// @notice Cumulative deposit ceiling per wallet in usd18 (0 = uncapped).
    uint256 public maxDepositUsdPerWallet;
    /// @notice Hard ceiling on HSTR issued by a SINGLE bond, whatever the feeds said. The last
    ///         line of defence behind every oracle assumption. 0 = uncapped (set this).
    uint256 public maxHstrPerBond;
    /// @notice Lowest HSTR tick at which this desk will issue anything.
    int24 public minIssueTick;
    /// @notice TWAP averaging window for the BOND pool (prices HSTR).
    uint32 public twapWindow = 1800;
    /// @notice TWAP averaging window for the ROUTE pool (values HYPE deposits).
    uint32 public hypeWindow = 1800;
    /// @notice Sanity band on the HYPE price read (usd18). A broken/rugged route pool must fail
    ///         closed, not silently reprice every HYPE deposit.
    uint256 public minHypeUsd = 5e18; // $5
    uint256 public maxHypeUsd = 5_000e18; // $5,000
    bool public paused = true;

    // ──────────────────────────────── Accounting ────────────────────────────────

    uint256 public totalOwed; // HSTR committed to open vests, unpaid
    mapping(address => uint256) public depositedUsd; // usd18, cumulative per wallet (caps bind forever)

    struct Vest {
        uint128 owed; // HSTR committed at issue time
        uint128 paid;
        uint64 start;
        uint64 end; // start + vestDuration snapshot
        bool closed; // fully paid OR expired
    }

    mapping(address => Vest[]) public vests;

    /// @notice The shared POL position. Minted once, grown by every POL bond, owned by this desk
    ///         forever: NO function transfers or burns it. Fees it earns are swept by the owner
    ///         ({collectPolFees}); the liquidity itself is untouchable.
    uint256 public polTokenId;
    /// @notice USD₮0 a POL zap did not spend (pool above its anchor, or mint remainder). It joins
    ///         the next POL zap; the owner can send it to the treasury with {sweepPolCarry}.
    uint256 public polCarry;
    AnchoredZap.LastZap private _lastZap;
    uint256 public polLiquidityTotal; // cumulative liquidity added (accounting, not a claim)
    uint256 public polUsdtDeployed; // lifetime USD₮0 zapped into POL
    uint256 public reserveWhypeBanked; // lifetime WHYPE delivered to treasury
    uint256 public reserveUsdtBanked; // lifetime USD₮0 delivered to treasury

    address[] public treasurySet; // declared backing addresses (includes TREASURY)

    /// @dev Exactly one swap in flight; names the pool so the callback can authenticate both legs.
    enum SwapInFlight {
        None,
        Bond,
        Route
    }
    SwapInFlight private _swapInFlight;

    // ────────────────────────────────── Events ──────────────────────────────────

    event BondReserve(address indexed user, uint256 indexed index, address asset, uint256 amountIn, uint256 issued, uint64 end);
    event BondPol(
        address indexed user,
        uint256 indexed index,
        address depositAsset,
        uint256 amountIn,
        uint256 fee,
        uint256 usdt0Deployed,
        uint128 liquidityAdded,
        uint256 issued,
        uint64 end
    );
    event VestClaimed(address indexed user, uint256 indexed index, uint256 paid);
    event VestExpired(address indexed user, uint256 indexed index, uint256 freed);
    event ParamsSet(
        uint256 feeBps,
        uint256 discountBps,
        uint256 vestDuration,
        uint256 bondDeadline,
        uint256 maxDepositUsdPerWallet,
        uint256 maxHstrPerBond
    );
    event GuardsSet(int24 minIssueTick, uint32 twapWindow, uint32 hypeWindow, uint256 minHypeUsd, uint256 maxHypeUsd);
    event PausedSet(bool paused);
    event InventoryWithdrawn(uint256 amount);
    event PolFeesCollected(uint256 amount0, uint256 amount1);
    event PolCarrySwept(uint256 amount);
    event TreasuryAddressSet(address indexed addr, bool allowed);

    // ─────────────────────────────────── Errors ──────────────────────────────────

    error Paused();
    error Expired();
    error BondingEnded();
    error NoValue();
    error WalletCap();
    error NoIssuance();
    error IssuanceCapped();
    error StashExhausted();
    error VestNotClosed();
    error AlreadyClaimed();
    error NothingVested();
    error PriceBelowFloor();
    error TwapUnseasoned();
    error PoolOffTwap();
    error HypeFeedUnseasoned();
    error HypePriceOutOfBounds();
    error BadWindow();
    error BadFloor();
    error TooManyTreasuryAddresses();
    error TreasuryAddressRequired();
    error BadCallback();
    error NoSwapInFlight();
    error Slippage();
    error EmptyPolLeg();
    error NativeRefused();
    error GuardsNotSet();

    // ───────────────────────────────── Constructor ─────────────────────────────

    constructor(
        address hstr_,
        address usdt0_,
        address whype_,
        address bondPool_,
        address routePool_,
        address npm_,
        address treasury_,
        int24 tickLower_,
        int24 tickUpper_,
        address owner_
    ) Ownable(owner_) {
        require(treasury_ != address(0), "HSTRBondDesk: treasury is zero");
        require(IUniswapV3Pool(bondPool_).token0() == hstr_, "HSTRBondDesk: bond token0 != HSTR");
        require(IUniswapV3Pool(bondPool_).token1() == usdt0_, "HSTRBondDesk: bond token1 != USDT0");
        require(IUniswapV3Pool(routePool_).token0() == whype_, "HSTRBondDesk: route token0 != WHYPE");
        require(IUniswapV3Pool(routePool_).token1() == usdt0_, "HSTRBondDesk: route token1 != USDT0");
        require(
            INonfungiblePositionManager(npm_).factory() == IUniswapV3Pool(bondPool_).factory(),
            "HSTRBondDesk: npm/pool factory mismatch"
        );

        int24 spacing = IUniswapV3Pool(bondPool_).tickSpacing();
        require(tickLower_ < tickUpper_, "HSTRBondDesk: bad range");
        require(tickLower_ % spacing == 0 && tickUpper_ % spacing == 0, "HSTRBondDesk: tick not on spacing");

        HSTR = IERC20(hstr_);
        USDT0 = IERC20(usdt0_);
        WHYPE = IWETH9(whype_);
        BOND_POOL = IUniswapV3Pool(bondPool_);
        ROUTE_POOL = IUniswapV3Pool(routePool_);
        NPM = INonfungiblePositionManager(npm_);
        TREASURY = treasury_;
        TICK_LOWER = tickLower_;
        TICK_UPPER = tickUpper_;
        BOND_POOL_FEE = IUniswapV3Pool(bondPool_).fee();

        treasurySet.push(treasury_);
        minIssueTick = V3TickMath.MIN_TICK;
    }
    // ────────────────────────────────── Oracle plumbing ─────────────────────────

    /// @dev The bond pool starts at `observationCardinality == 1`, which is worse than no
    ///      oracle: a TWAP query there does NOT revert — it reports SPOT. Growing the array is
    ///      permissionless; every issue reverts until it is grown AND seasoned.
    function growOracle(uint16 bondNext, uint16 routeNext) external {
        if (bondNext > 0) BOND_POOL.increaseObservationCardinalityNext(bondNext);
        if (routeNext > 0) ROUTE_POOL.increaseObservationCardinalityNext(routeNext);
    }

    function oracleReady() external view returns (bool bondOk, bool routeOk, uint16 bondCard, uint16 routeCard) {
        (,,, uint16 bc,,, ) = BOND_POOL.slot0();
        (,,, uint16 rc,,, ) = ROUTE_POOL.slot0();
        (bondCard, routeCard) = (bc, rc);
        (bondOk, routeOk) = (_twapSeasoned(BOND_POOL, twapWindow), _twapSeasoned(ROUTE_POOL, hypeWindow));
    }

    function _obsIndex(IUniswapV3Pool pool) private view returns (uint16 idx) {
        (, , idx, , , , ) = pool.slot0();
    }

    /// @dev Seasoning gate: cardinality grown past 1 AND some live observation actually reaches
    ///      back past the window. A freshly-grown array clamps TWAP reads to its newest entry —
    ///      spot wearing a costume — so we inspect real timestamps: index 0 while the array is
    ///      still filling, then (head+1) once writes wrap around.
    function _twapSeasoned(IUniswapV3Pool pool, uint32 window) private view returns (bool ok) {
        (,,, uint16 card,,, ) = pool.slot0();
        if (card <= 1) return false;

        uint256[2] memory candidates;
        candidates[0] = 0;
        candidates[1] = (uint256(_obsIndex(pool)) + 1) % card;

        for (uint256 i; i < 2; ++i) {
            (uint32 ts, , , bool initialized) = pool.observations(candidates[i]);
            if (initialized && block.timestamp - ts >= window) return true;
        }
        return false;
    }

    /// @dev Mean sqrtP over `window` on `pool`, with floor-tick correction for negative-tick
    ///      pools (truncation toward zero would read marginally high otherwise).
    function _meanSqrtP(IUniswapV3Pool pool, uint32 window) private view returns (uint160 sqrtP) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = window;
        ago[1] = 0;
        (int56[] memory tickCumulatives,) = pool.observe(ago);
        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        int24 avgTick = int24(delta / int56(uint56(window)));
        if (delta < 0 && delta % int56(uint56(window)) != 0) avgTick--;
        sqrtP = V3TickMath.getSqrtRatioAtTick(avgTick);
    }

    /// @dev HSTR price integrity: hard floor tick, seasoned oracle, one-sided deviation band
    ///      (spot above average is the protocol-favouring direction — dearer issuance — so only
    ///      the cheap side is bounded). Returns the TWAP mark used for issuance.
    function _checkedHstrPrice() private view returns (int24 tick, uint160 twapP) {
        uint160 spotP;
        uint16 cardinality;
        (spotP, tick,, cardinality,,,) = BOND_POOL.slot0();

        if (tick < minIssueTick) revert PriceBelowFloor();
        if (!_twapSeasoned(BOND_POOL, twapWindow)) revert TwapUnseasoned();

        uint32[] memory ago = new uint32[](2);
        ago[0] = twapWindow;
        ago[1] = 0;
        (int56[] memory tc,) = BOND_POOL.observe(ago);
        int56 delta = tc[1] - tc[0];
        int24 avgTick = int24(delta / int56(uint56(twapWindow)));
        if (delta < 0 && delta % int56(uint56(twapWindow)) != 0) avgTick--;

        // The floor binds the mark issuance actually prices off, not only spot: a TWAP can be
        // walked down and spot restored inside the bonding block.
        if (avgTick < minIssueTick) revert PriceBelowFloor();
        if (tick < avgTick && uint24(avgTick - tick) > MAX_TICK_DEVIATION) revert PoolOffTwap();
        twapP = V3TickMath.getSqrtRatioAtTick(avgTick);
    }

    /// @dev HYPE/USD at the LOWER of route-pool spot and TWAP. Inflating the deposit valuation
    ///      requires beating the TWAP; deflating it only cheats the bonder. Sanity-banded.
    function _hypePriceUsd18() private view returns (uint256 usd18) {
        uint160 spotP;
        (spotP,,,,,, ) = ROUTE_POOL.slot0();
        if (!_twapSeasoned(ROUTE_POOL, hypeWindow)) revert HypeFeedUnseasoned();
        uint160 twapP = _meanSqrtP(ROUTE_POOL, hypeWindow);

        uint256 s = _usd18FromSqrtP(spotP);
        uint256 t = _usd18FromSqrtP(twapP);
        usd18 = s < t ? s : t;

        if (usd18 < minHypeUsd || usd18 > maxHypeUsd) revert HypePriceOutOfBounds();
    }

    /// @dev token1=USDT0(6), token0=18-dec asset ⇒ usd18 of one whole token0 is exactly
    ///      (sqrtP/Q96)² × 1e30. Two chained mulDivs stay in range; verified against live pools.
    function _usd18FromSqrtP(uint160 sqrtP) private pure returns (uint256) {
        return Math.mulDiv(Math.mulDiv(sqrtP, sqrtP, Q96), 1e30, Q96);
    }

    /// @notice Backing per whole HSTR in usd18: native HYPE + WHYPE + USD₮0 across declared
    ///         addresses ÷ total supply. Own token never backs itself; LP positions are NOT
    ///         counted (conservative direction for an issuance floor).
    function backingPerShare() public view returns (uint256) {
        uint256 hypeUsd18 = _hypePriceUsd18();
        uint256 total;

        for (uint256 i = 0; i < treasurySet.length; ++i) {
            address a = treasurySet[i];
            total += Math.mulDiv(a.balance, hypeUsd18, 1e18); // native HYPE
            total += Math.mulDiv(IERC20(address(WHYPE)).balanceOf(a), hypeUsd18, 1e18);
            total += IERC20(USDT0).balanceOf(a) * 1e12; // stables at par, raw6 → usd18
        }
        // Normalize to usd18 per WHOLE token — the same convention as _usd18FromSqrtP — or the
        // floor sits 1e18 below the mark and never binds.
        return Math.mulDiv(total, 1e18, IERC20(HSTR).totalSupply());
    }
    // ────────────────────────────────── Issuance ────────────────────────────────

    /// @notice Current HYPE/USD valuation feed (lower-of spot/TWAP, sanity-banded).
    function hypePriceUsd() external view returns (uint256) {
        return _hypePriceUsd18();
    }

    /// @notice Current HSTR TWAP mark in usd18 — what issuance prices off. Reverts unseasoned.
    function markUsd() external view returns (uint256) {
        (, uint160 twapP) = _checkedHstrPrice();
        return _usd18FromSqrtP(twapP);
    }

    /// @dev The checked TWAP mark every issuance prices off. Reverts fail-closed.
    function _markUsd18() private view returns (uint256) {
        (, uint160 twapP) = _checkedHstrPrice();
        return _usd18FromSqrtP(twapP);
    }

    function _issuePriceLive(Mode mode) private view returns (uint256) {
        return _issuePrice(_markUsd18(), mode);
    }

    /// @notice The issue price a RESERVE bond would get right now (usd18 per HSTR).
    function reserveIssuePrice() external view returns (uint256) {
        (, uint160 twapP) = _checkedHstrPrice();
        return _issuePrice(_usd18FromSqrtP(twapP), Mode.RESERVE);
    }

    /// @notice The issue price a POL bond would get right now (usd18 per HSTR).
    function polIssuePrice() external view returns (uint256) {
        (, uint160 twapP) = _checkedHstrPrice();
        return _issuePrice(_usd18FromSqrtP(twapP), Mode.POL);
    }

    /// @dev max( mark×(1−discount), floor ). The floor is the whole discipline: it never reads
    ///      the HSTR pool for its backing inputs, so pool manipulation cannot buy cheap supply.
    function _issuePrice(uint256 markUsd18, Mode mode) private view returns (uint256 price) {
        price = Math.mulDiv(markUsd18, BPS - discountBps, BPS);

        uint256 b = backingPerShare();
        uint256 floor;
        if (mode == Mode.RESERVE) {
            floor = b; // the whole deposit banks ⇒ accretive iff price ≥ b
        } else {
            // Only ~half of a POL deposit banks as backing, so the bar is tighter; the harmonic
            // blend keeps it between b and the market mark instead of an arbitrary 2b.
            floor = Math.mulDiv(2 * b, markUsd18, b + markUsd18);
        }
        if (price < floor) price = floor;
    }

    /// @dev Commit issuance against the stash and open a vesting position.
    function _issue(address user, uint256 shares) private returns (uint256 index) {
        if (shares == 0) revert NoIssuance();
        if (maxHstrPerBond != 0 && shares > maxHstrPerBond) revert IssuanceCapped();
        if (totalOwed + shares > IERC20(HSTR).balanceOf(address(this))) revert StashExhausted();

        totalOwed += shares;
        uint64 end = uint64(block.timestamp + vestDuration);
        index = vests[user].length;
        vests[user].push(Vest({owed: uint128(shares), paid: 0, start: uint64(block.timestamp), end: end, closed: false}));
    }

    // ──────────────────────────────── Reserve bonds ─────────────────────────────

    /// @notice RESERVE with native HYPE: wrapped and banked whole. No fee — 100% must land as
    ///         counted backing or the mode's premise is false.
    function bondReserveHype() external payable nonReentrant returns (uint256 index) {
        if (paused) revert Paused();
        if (msg.value == 0) revert NoValue();
        if (bondDeadline != 0 && block.timestamp > bondDeadline) revert BondingEnded();

        WHYPE.deposit{value: msg.value}();
        uint256 net = msg.value;
        uint256 usd18 = Math.mulDiv(net, _hypePriceUsd18(), 1e18);
        _chargeWallet(msg.sender, usd18);

        IERC20(address(WHYPE)).safeTransfer(TREASURY, net);
        reserveWhypeBanked += net;

        index = _issue(msg.sender, Math.mulDiv(usd18, 1e18, _issuePriceLive(Mode.RESERVE)));
        emit BondReserve(msg.sender, index, address(WHYPE), msg.value, vests[msg.sender][index].owed, vests[msg.sender][index].end);
    }

    /// @notice RESERVE with USD₮0: banked as-is (stables are their own dry powder).
    function bondReserveUsdt0(uint256 amount) external nonReentrant returns (uint256 index) {
        if (paused) revert Paused();
        if (amount == 0) revert NoValue();
        if (bondDeadline != 0 && block.timestamp > bondDeadline) revert BondingEnded();

        uint256 before = IERC20(USDT0).balanceOf(address(this));
        IERC20(USDT0).safeTransferFrom(msg.sender, address(this), amount);
        amount = IERC20(USDT0).balanceOf(address(this)) - before; // fee-on-transfer safe

        uint256 usd18 = amount * 1e12;
        _chargeWallet(msg.sender, usd18);

        IERC20(USDT0).safeTransfer(TREASURY, amount);
        reserveUsdtBanked += amount;

        index = _issue(msg.sender, Math.mulDiv(usd18, 1e18, _issuePriceLive(Mode.RESERVE)));
        emit BondReserve(msg.sender, index, address(USDT0), amount, vests[msg.sender][index].owed, vests[msg.sender][index].end);
    }
    // ────────────────────────────────── POL bonds ───────────────────────────────

    /// @notice POL with native HYPE: fee skimmed, remainder routed WHYPE→USD₮0 through the deep
    ///         route pool, then zapped into the permanent shared position.
    /// @param amountOutMin Slippage floor on the routing leg. Compute off-chain; 0 disables it.
    function bondPolHype(uint256 amountOutMin) external payable nonReentrant returns (uint256 index) {
        if (paused) revert Paused();
        if (msg.value == 0) revert NoValue();
        if (bondDeadline != 0 && block.timestamp > bondDeadline) revert BondingEnded();

        uint256 net = _chargeFeeHype(msg.value);
        uint256 usd18 = Math.mulDiv(net, _hypePriceUsd18(), 1e18);
        _chargeWallet(msg.sender, usd18);

        _checkedHstrPrice(); // same pre-trade guard as the USD₮0 lane

        // HYPE lane: swap WHYPE for USD₮0 through the deep route pool first.
        uint256 usdtOut = _routeSwap(int256(net), amountOutMin);

        (uint128 liq, uint256 deployed) = _polZap(usdtOut, 0);
        index = _issue(msg.sender, Math.mulDiv(usd18, 1e18, _issuePriceLive(Mode.POL)));
        Vest storage v = vests[msg.sender][index];
        emit BondPol(msg.sender, index, address(WHYPE), msg.value, msg.value - net, deployed, liq, v.owed, v.end);
    }

    /// @notice POL with USD₮0: fee skimmed, remainder zapped straight into the permanent
    ///         shared position — no routing needed, the cheapest lane.
    function bondPolUsdt0(uint256 amount, uint128 minLiquidity) external nonReentrant returns (uint256 index) {
        if (paused) revert Paused();
        if (amount == 0) revert NoValue();
        if (bondDeadline != 0 && block.timestamp > bondDeadline) revert BondingEnded();

        uint256 before = IERC20(USDT0).balanceOf(address(this));
        IERC20(USDT0).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(USDT0).balanceOf(address(this)) - before;

        uint256 net = received - (received * feeBps) / BPS;
        if (feeBps > 0 && received > net) IERC20(USDT0).safeTransfer(TREASURY, received - net);
        if (net == 0) revert NoValue();

        _chargeWallet(msg.sender, net * 1e12);

        // Under POL the PROTOCOL eats the zap's slippage, so the desk — not the bonder — guards
        // spot against TWAP before trading.
        _checkedHstrPrice();

        (uint128 liq, uint256 deployed) = _polZap(net, minLiquidity);
        index = _issue(msg.sender, Math.mulDiv(net * 1e12, 1e18, _issuePriceLive(Mode.POL)));
        Vest storage v = vests[msg.sender][index];
        emit BondPol(msg.sender, index, address(USDT0), received, received - net, deployed, liq, v.owed, v.end);
    }

    /// @dev Single-sided zap into the shared POL position, as an anchored LIMIT order: sell up to
    ///      `swapIn` of the USD₮0 for HSTR but never above the honest end price from an anchor the
    ///      bonder cannot move, pair what was bought, grow the position. Unspent USD₮0 is carried
    ///      into the next zap. HSTR the mint does not take simply rejoins the stash. The position
    ///      NFT never leaves.
    function _polZap(uint256 fresh, uint128 minLiquidity) private returns (uint128 liquidity, uint256 deployedUsdt) {
        uint256 net = fresh + polCarry;
        (uint160 sqrtP,,,,,,) = BOND_POOL.slot0();
        uint256 swapIn = ZapMath.optimalSwapIn(net, BOND_POOL.liquidity(), sqrtP, BOND_POOL_FEE);
        require(swapIn > 0 && swapIn < net, "HSTRBondDesk: bad zap size");

        (uint160 limitSqrtP, bool fillable) = AnchoredZap.limit(BOND_POOL, twapWindow, _lastZap, swapIn, BOND_POOL_FEE);
        uint256 bought;
        uint256 spent;
        if (fillable) {
            (int256 a0, int256 a1) = _bondSwap(int256(swapIn), limitSqrtP);
            bought = uint256(-a0); // token0 arrives negative
            spent = uint256(a1);
        }
        uint256 used1;
        if (bought > 0) {
            uint256 pair = net - spent;
            IERC20(HSTR).forceApprove(address(NPM), bought);
            IERC20(USDT0).forceApprove(address(NPM), pair);

            if (polTokenId == 0) {
                (polTokenId, liquidity,, used1) = NPM.mint(
                    INonfungiblePositionManager.MintParams({
                        token0: address(HSTR),
                        token1: address(USDT0),
                        fee: BOND_POOL_FEE,
                        tickLower: TICK_LOWER,
                        tickUpper: TICK_UPPER,
                        amount0Desired: bought,
                        amount1Desired: pair,
                        amount0Min: 0,
                        amount1Min: 0,
                        recipient: address(this), // forever
                        deadline: block.timestamp
                    })
                );
            } else {
                (liquidity,, used1) = NPM.increaseLiquidity(
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
        // A caller who asks for a minimum still gets it; zero means "never revert on price".
        require(liquidity >= minLiquidity, "HSTRBondDesk: insufficient liquidity");

        polCarry = net - spent - used1;
        polLiquidityTotal += liquidity;
        deployedUsdt = spent + used1;
        polUsdtDeployed += deployedUsdt;
    }
    // ────────────────────────────────── Vesting ────────────────────────────────

    /// @notice Claim the vested slice of a bond. Linear from bond time; repeatable until
    ///         exhausted. Paid from the pre-funded stash — the desk holds no mint rights.
    function claimVested(uint256 index) external nonReentrant returns (uint256 paid) {
        Vest storage v = vests[msg.sender][index];
        if (v.closed) revert AlreadyClaimed();

        paid = _pendingVest(v);
        if (paid == 0) revert NothingVested();

        totalOwed -= paid;
        v.paid += uint128(paid);
        if (block.timestamp >= v.end && v.paid >= v.owed) {
            v.closed = true;
            // Unclaimed accumulator-style dust is impossible here: owed−paid hits zero exactly
            // at end by construction of the linear stream (floored mulDivs, tail claim covers).
        }
        IERC20(HSTR).safeTransfer(msg.sender, paid);
        emit VestClaimed(msg.sender, index, paid);
    }

    /// @notice After `end + EXPIRY_GRACE`, free an abandoned vest's remaining capacity back to
    ///         the stash. Never pays anyone; only unwinds the commitment.
    function expireVest(address user, uint256 index) external onlyOwner {
        Vest storage v = vests[user][index];
        if (v.closed) revert AlreadyClaimed();
        require(block.timestamp > v.end + EXPIRY_GRACE, "HSTRBondDesk: not expirable");
        v.closed = true;
        uint256 freed = uint256(v.owed) - v.paid;
        totalOwed -= freed;
        emit VestExpired(user, index, freed);
    }

    /// @notice Vested-but-unclaimed HSTR on a position.
    function pendingVest(address user, uint256 index) external view returns (uint256) {
        return _pendingVest(vests[user][index]);
    }

    function vestsLength(address user) external view returns (uint256) {
        return vests[user].length;
    }

    /// @notice Free stash committable to new issuance right now.
    function availableCapacity() public view returns (uint256) {
        uint256 bal = IERC20(HSTR).balanceOf(address(this));
        return bal > totalOwed ? bal - totalOwed : 0;
    }

    /// @notice Quote the shares (HSTR wei) a RESERVE HYPE deposit would issue right now.
    function quoteReserveHype(uint256 hypeAmount) external view returns (uint256) {
        uint256 usd18 = Math.mulDiv(hypeAmount, _hypePriceUsd18(), 1e18);
        return Math.mulDiv(usd18, 1e18, _issuePriceLive(Mode.RESERVE));
    }

    /// @notice Quote the shares a POL USD₮0 deposit would issue right now (pre-fee).
    function quotePolUsdt0(uint256 usdtAmount) external view returns (uint256) {
        uint256 net = usdtAmount - (usdtAmount * feeBps) / BPS;
        return Math.mulDiv(net * 1e12, 1e18, _issuePriceLive(Mode.POL));
    }

    function _pendingVest(Vest storage v) private view returns (uint256) {
        if (v.closed || block.timestamp < v.start) return 0;
        uint64 end = v.end >= v.start ? v.end : v.start;
        uint256 elapsed = block.timestamp >= end ? uint256(end - v.start) : uint256(block.timestamp) - v.start;
        uint256 duration = uint256(end - v.start);
        if (duration == 0) return uint256(v.owed) - v.paid;
        uint256 vested = Math.mulDiv(v.owed, elapsed, duration);
        return vested - v.paid;
    }

    function _chargeWallet(address user, uint256 usd18) private {
        if (maxDepositUsdPerWallet != 0) {
            if (depositedUsd[user] + usd18 > maxDepositUsdPerWallet) revert WalletCap();
        }
        depositedUsd[user] += usd18;
    }

    /// @dev Wraps the native value sent with the call; returns net after POL fee skim.
    function _chargeFeeHype(uint256 gross) private returns (uint256 net) {
        WHYPE.deposit{value: gross}();
        net = gross - (gross * feeBps) / BPS;
        if (gross > net) IERC20(address(WHYPE)).safeTransfer(TREASURY, gross - net);
        if (net == 0) revert NoValue();
    }
    // ──────────────────────────────────── Owner ─────────────────────────────────

    /// @dev Applies to NEW bonds only.
    function setParams(
        uint256 feeBps_,
        uint256 discountBps_,
        uint256 vestDuration_,
        uint256 bondDeadline_,
        uint256 maxDepositUsdPerWallet_,
        uint256 maxHstrPerBond_
    ) external onlyOwner {
        require(feeBps_ <= MAX_FEE_BPS, "HSTRBondDesk: fee too high");
        require(discountBps_ <= MAX_DISCOUNT_BPS, "HSTRBondDesk: discount too high");
        require(vestDuration_ <= MAX_VEST, "HSTRBondDesk: vest too long");

        feeBps = feeBps_;
        discountBps = discountBps_;
        vestDuration = vestDuration_;
        bondDeadline = bondDeadline_;
        maxDepositUsdPerWallet = maxDepositUsdPerWallet_;
        maxHstrPerBond = maxHstrPerBond_;
        _requireGuardsWhileOpen();

        emit ParamsSet(feeBps_, discountBps_, vestDuration_, bondDeadline_, maxDepositUsdPerWallet_, maxHstrPerBond_);
    }

    /// @dev Tightening is always safe; loosening re-opens the desk to the pool it prices off.
    function setGuards(
        int24 minIssueTick_,
        uint32 twapWindow_,
        uint32 hypeWindow_,
        uint256 minHypeUsd_,
        uint256 maxHypeUsd_
    ) external onlyOwner {
        if (minIssueTick_ < V3TickMath.MIN_TICK || minIssueTick_ > V3TickMath.MAX_TICK) revert BadFloor();
        if (twapWindow_ < MIN_TWAP_WINDOW || twapWindow_ > MAX_TWAP_WINDOW) revert BadWindow();
        if (hypeWindow_ < MIN_TWAP_WINDOW || hypeWindow_ > MAX_TWAP_WINDOW) revert BadWindow();
        if (minHypeUsd_ >= maxHypeUsd_) revert HypePriceOutOfBounds();

        minIssueTick = minIssueTick_;
        twapWindow = twapWindow_;
        hypeWindow = hypeWindow_;
        minHypeUsd = minHypeUsd_;
        maxHypeUsd = maxHypeUsd_;
        _requireGuardsWhileOpen();

        emit GuardsSet(minIssueTick_, twapWindow_, hypeWindow_, minHypeUsd_, maxHypeUsd_);
    }

    /// @dev Opening requires a real hard floor and a per-bond issuance cap. Both default to "off",
    ///      and every oracle assumption in this contract sits behind them.
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        _requireGuardsWhileOpen();
        emit PausedSet(paused_);
    }

    function _requireGuardsWhileOpen() private view {
        if (!paused && (minIssueTick == V3TickMath.MIN_TICK || maxHstrPerBond == 0)) revert GuardsNotSet();
    }

    /// @notice Send USD₮0 the POL zap has not deployed to the treasury (e.g. when bonding winds
    ///         down). The desk holds no other USD₮0 between transactions.
    function sweepPolCarry() external onlyOwner nonReentrant returns (uint256 amount) {
        amount = IERC20(USDT0).balanceOf(address(this));
        polCarry = 0;
        if (amount > 0) IERC20(USDT0).safeTransfer(TREASURY, amount);
        emit PolCarrySwept(amount);
    }

    /// @notice Declare or remove a backing address. TREASURY itself can never be removed —
    ///         the floor must at least see where reserves land.
    function setTreasuryAddress(address addr, bool allowed) external onlyOwner {
        require(addr != address(0), "HSTRBondDesk: zero addr");

        for (uint256 i; i < treasurySet.length; ++i) {
            if (treasurySet[i] == addr) {
                if (!allowed) {
                    if (addr == TREASURY) revert TreasuryAddressRequired();
                    treasurySet[i] = treasurySet[treasurySet.length - 1];
                    treasurySet.pop();
                }
                emit TreasuryAddressSet(addr, allowed);
                return;
            }
        }
        if (allowed) {
            if (treasurySet.length >= MAX_TREASURY_ADDRS) revert TooManyTreasuryAddresses();
            treasurySet.push(addr);
            emit TreasuryAddressSet(addr, true);
        }
    }

    function treasuryAddresses() external view returns (address[] memory) {
        return treasurySet;
    }

    /// @notice Pull unused HSTR stash back to the treasury. Committed vests are untouchable:
    ///         reclaim is bounded by balance − totalOwed.
    function withdrawInventory(uint256 amount) external onlyOwner {
        require(amount <= availableCapacity(), "HSTRBondDesk: exceeds free stash");
        IERC20(HSTR).safeTransfer(TREASURY, amount);
        emit InventoryWithdrawn(amount);
    }

    /// @notice Sweep the swap fees the POL position has earned to the treasury. The liquidity
    ///         itself is NOT touched — there is no code path that decreases POL liquidity.
    function collectPolFees() external onlyOwner nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(polTokenId != 0, "HSTRBondDesk: no pol position");
        (amount0, amount1) = NPM.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: polTokenId, recipient: TREASURY, amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
        emit PolFeesCollected(amount0, amount1);
    }

    // ──────────────────────────────── Swap plumbing ─────────────────────────────

    function _routeSwap(int256 whypeIn, uint256 amountOutMin) private returns (uint256 usdtOut) {
        IERC20(address(WHYPE)).forceApprove(address(ROUTE_POOL), uint256(whypeIn));
        _swapInFlight = SwapInFlight.Route;
        (int256 a0, int256 a1) =
            ROUTE_POOL.swap(address(this), true, whypeIn, MIN_SQRT_RATIO + 1, "");
        _swapInFlight = SwapInFlight.None;
        IERC20(address(WHYPE)).forceApprove(address(ROUTE_POOL), 0);

        require(a0 >= 0 && a1 <= 0);
        usdtOut = uint256(-a1);
        if (usdtOut < amountOutMin) revert Slippage();
    }

    function _bondSwap(int256 usdtIn, uint160 limitSqrtP) private returns (int256 amount0, int256 amount1) {
        _swapInFlight = SwapInFlight.Bond;
        (amount0, amount1) = BOND_POOL.swap(address(this), false, usdtIn, limitSqrtP, "");
        _swapInFlight = SwapInFlight.None;
    }

    /// @notice Pays whichever swap this contract just initiated. Authenticates BOTH pools.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        SwapInFlight inflight = _swapInFlight;
        if (inflight == SwapInFlight.None) revert NoSwapInFlight();

        if (msg.sender == address(BOND_POOL)) {
            if (inflight != SwapInFlight.Bond) revert BadCallback();
            // token1→token0: we owe USD₮0.
            if (amount1Delta > 0) IERC20(USDT0).safeTransfer(msg.sender, uint256(amount1Delta));
        } else if (msg.sender == address(ROUTE_POOL)) {
            if (inflight != SwapInFlight.Route) revert BadCallback();
            // token0→token1: we owe WHYPE.
            if (amount0Delta > 0) IERC20(address(WHYPE)).safeTransfer(msg.sender, uint256(amount0Delta));
        } else {
            revert BadCallback();
        }
    }

    /// @dev Refuse direct native transfers — unaccounted value would sit outside every
    ///      guarantee. HYPE enters exclusively via the payable bond functions that wrap it.
    receive() external payable {
        revert NativeRefused();
    }
}
