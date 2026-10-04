// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniswapV3Pool, INonfungiblePositionManager} from "./interfaces/IUniswapV3.sol";
import {PositionMath} from "./libraries/PositionMath.sol";
import {V3TickMath} from "./libraries/V3TickMath.sol";

/// @title HSTR Matched Liquidity Bonds (MLB)
/// @notice Prefunded treasury matching and cancellable two-person community rounds.
/// @dev Each matched round owns one V3 NFT. Principal, trading fees and vested rewards
///      have independent ledgers. Campaign terms cannot be changed after creation.
contract HSTRMatchedLiquidityBond is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    uint256 private constant ONE = 1e18;
    uint256 private constant Q96 = 1 << 96;
    uint32 public constant TWAP_WINDOW = 30 minutes;
    uint24 public constant MAX_TICK_DEVIATION = 200;
    bytes32 public constant CONTRACT_VERSION = keccak256("HSTR_MLB_V2");

    enum Mode {
        Treasury,
        Community
    }
    enum State {
        None,
        Forming,
        Active,
        Settled,
        Cancelled
    }

    struct Terms {
        bytes32 name;
        Mode mode;
        address rewardToken;
        uint256 rewardBudget;
        uint256 quoteCapacity;
        uint256 minQuote;
        uint256 walletCap;
        uint64 endsAt;
        uint32 duration;
        uint32 fillWindow;
        int24 tickLower;
        int24 tickUpper;
        uint16 userFeeBps;
        /// @dev Treasury mode only: most HSTR (wei) the sponsor will pair with 1 USDT0 (1e6 raw),
        ///      i.e. the lowest price it accepts. The thin pool's TWAP can be walked down for the
        ///      cost of waiting 30 minutes; this bound is what stops inventory being paired there.
        uint256 maxHstrPerQuote;
    }

    struct Campaign {
        Terms terms;
        address sponsor;
        bool closed;
        uint256 allocatedQuote;
        uint256 rewardFree;
        uint256 inventory;
    }

    struct Round {
        uint256 campaignId;
        State state;
        address hstrOwner;
        address quoteOwner;
        uint256 quoteAmount;
        uint256 hstrEscrow;
        uint256 rewardTotal;
        uint64 expiresAt;
        uint64 matchedAt;
        int24 openingTick;
        uint256 tokenId;
        uint128 liquidity;
        uint256 quoteShare;
        uint256 quoteFeeShare;
        uint256 quoteReward;
        uint256 principal0;
        uint256 principal1;
        uint256 fees0;
        uint256 fees1;
    }

    struct Claimed {
        bool principal;
        uint256 reward;
        uint256 fees0;
        uint256 fees1;
    }

    struct Quote {
        uint256 hstrAmount;
        uint128 liquidity;
        uint256 quoteShare;
        uint256 reward;
        uint160 sqrtPriceX96;
        int24 tick;
    }

    IERC20 public immutable HSTR;
    IERC20 public immutable USDT0;
    IUniswapV3Pool public immutable POOL;
    INonfungiblePositionManager public immutable NPM;
    bool public paused = true;
    uint256 public campaignCount;
    uint256 public roundCount;
    mapping(uint256 => Campaign) private _campaigns;
    mapping(uint256 => Round) private _rounds;
    mapping(uint256 => mapping(address => uint256)) public walletCommitted;
    mapping(uint256 => mapping(address => Claimed)) public claimed;
    mapping(address => uint256[]) private _userRounds;
    mapping(uint256 => uint256[]) private _campaignRounds;

    event CampaignCreated(uint256 indexed campaignId, address indexed sponsor, Mode mode, address rewardToken);
    event CampaignClosed(uint256 indexed campaignId);
    event InventoryFunded(uint256 indexed campaignId, uint256 amount);
    event UnusedReturned(uint256 indexed campaignId, uint256 reward, uint256 inventory);
    event Paused(bool paused);
    event RoundOpened(uint256 indexed roundId, uint256 indexed campaignId, address indexed creator, bool hstrSide);
    event RoundMatched(
        uint256 indexed roundId,
        address hstrOwner,
        address quoteOwner,
        uint256 tokenId,
        uint128 liquidity,
        uint256 quoteShare
    );
    event RoundCancelled(uint256 indexed roundId);
    event RoundSettled(uint256 indexed roundId, uint256 hstr, uint256 usdt0);
    event PrincipalClaimed(uint256 indexed roundId, address indexed user, uint256 hstr, uint256 usdt0);
    event RewardsClaimed(uint256 indexed roundId, address indexed user, address token, uint256 amount);
    event FeesClaimed(uint256 indexed roundId, address indexed user, uint256 hstr, uint256 usdt0);

    constructor(address hstr, address usdt0, address pool, address npm, address administrator) Ownable(administrator) {
        require(hstr != address(0) && hstr != usdt0, "MLB: tokens");
        require(IUniswapV3Pool(pool).token0() == hstr && IUniswapV3Pool(pool).token1() == usdt0, "MLB: pool tokens");
        require(INonfungiblePositionManager(npm).factory() == IUniswapV3Pool(pool).factory(), "MLB: factory");
        HSTR = IERC20(hstr);
        USDT0 = IERC20(usdt0);
        POOL = IUniswapV3Pool(pool);
        NPM = INonfungiblePositionManager(npm);
    }

    /// @notice Fund an immutable campaign. Inventory and rewards remain separate even when both are HSTR.
    function createCampaign(Terms calldata t, uint256 hstrInventory)
        external
        onlyOwner
        nonReentrant
        returns (uint256 id)
    {
        require(t.rewardToken.code.length != 0 && t.rewardBudget > 0, "MLB: reward");
        require(t.minQuote > 0 && t.minQuote <= t.walletCap && t.walletCap <= t.quoteCapacity, "MLB: caps");
        require(t.endsAt > block.timestamp && t.duration >= 1 days && t.duration <= 365 days, "MLB: term");
        require(t.fillWindow >= 5 minutes && t.fillWindow <= 7 days && t.userFeeBps <= 10_000, "MLB: terms");
        int24 spacing = POOL.tickSpacing();
        require(
            spacing > 0 && t.tickLower < t.tickUpper && t.tickLower >= V3TickMath.MIN_TICK
                && t.tickUpper <= V3TickMath.MAX_TICK,
            "MLB: range"
        );
        require(t.tickLower % spacing == 0 && t.tickUpper % spacing == 0, "MLB: spacing");
        require(t.mode == Mode.Treasury || hstrInventory == 0, "MLB: community inventory");
        require((t.mode == Mode.Treasury) == (t.maxHstrPerQuote != 0), "MLB: price floor term");
        id = ++campaignCount;
        Campaign storage c = _campaigns[id];
        c.terms = t;
        c.sponsor = msg.sender;
        c.rewardFree = t.rewardBudget;
        c.inventory = hstrInventory;
        _pull(IERC20(t.rewardToken), msg.sender, t.rewardBudget);
        if (hstrInventory > 0) _pull(HSTR, msg.sender, hstrInventory);
        emit CampaignCreated(id, msg.sender, t.mode, t.rewardToken);
    }

    function setPaused(bool value) external onlyOwner {
        paused = value;
        emit Paused(value);
    }

    function closeCampaign(uint256 id) external onlyOwner {
        Campaign storage c = _campaign(id);
        c.closed = true;
        emit CampaignClosed(id);
    }

    function fundInventory(uint256 id, uint256 amount) external onlyOwner nonReentrant {
        Campaign storage c = _campaign(id);
        require(c.terms.mode == Mode.Treasury && !c.closed && amount > 0, "MLB: inventory");
        c.inventory += amount;
        _pull(HSTR, msg.sender, amount);
        emit InventoryFunded(id, amount);
    }

    /// @notice Only unallocated rewards and unused treasury inventory can return to the original sponsor.
    function returnUnused(uint256 id) external nonReentrant {
        Campaign storage c = _campaign(id);
        require(c.closed || block.timestamp >= c.terms.endsAt, "MLB: campaign open");
        uint256 reward = c.rewardFree;
        uint256 inventory = c.inventory;
        c.rewardFree = 0;
        c.inventory = 0;
        if (reward > 0) IERC20(c.terms.rewardToken).safeTransfer(c.sponsor, reward);
        if (inventory > 0) HSTR.safeTransfer(c.sponsor, inventory);
        emit UnusedReturned(id, reward, inventory);
    }

    function depositTreasury(
        uint256 campaignId,
        uint256 amount,
        uint256 maxHstr,
        uint128 minLiquidity,
        uint256 deadline
    ) external nonReentrant returns (uint256 id) {
        Campaign storage c = _open(campaignId, deadline);
        require(c.terms.mode == Mode.Treasury && msg.sender != c.sponsor, "MLB: treasury mode");
        Quote memory q = _quote(c, amount);
        require(q.hstrAmount <= Math.mulDiv(amount, c.terms.maxHstrPerQuote, 1e6), "MLB: price floor");
        require(q.hstrAmount <= maxHstr && q.hstrAmount <= c.inventory, "MLB: HSTR limit");
        id = _newRound(campaignId, amount, q, false);
        Round storage r = _rounds[id];
        r.hstrOwner = c.sponsor;
        c.inventory -= q.hstrAmount;
        r.hstrEscrow = q.hstrAmount;
        _pull(USDT0, msg.sender, amount);
        _userRounds[c.sponsor].push(id);
        _match(id, q, minLiquidity, deadline);
    }

    /// @notice Opens a cancellable round. `amount` is the USDT0 size of the pair on either side.
    function openRound(uint256 campaignId, bool hstrSide, uint256 amount, uint256 maxHstr, uint256 deadline)
        external
        nonReentrant
        returns (uint256 id)
    {
        Campaign storage c = _open(campaignId, deadline);
        require(c.terms.mode == Mode.Community, "MLB: community mode");
        Quote memory q = _quote(c, amount);
        require(q.hstrAmount <= maxHstr, "MLB: HSTR limit");
        id = _newRound(campaignId, amount, q, hstrSide);
        if (hstrSide) {
            _rounds[id].hstrEscrow = q.hstrAmount;
            _pull(HSTR, msg.sender, q.hstrAmount);
        } else {
            _pull(USDT0, msg.sender, amount);
        }
    }

    function matchRound(uint256 id, uint256 maxHstr, uint128 minLiquidity, uint256 deadline) external nonReentrant {
        Round storage r = _rounds[id];
        Campaign storage c = _open(r.campaignId, deadline);
        require(r.state == State.Forming && block.timestamp < r.expiresAt, "MLB: round closed");
        address creator = r.hstrOwner == address(0) ? r.quoteOwner : r.hstrOwner;
        require(msg.sender != creator, "MLB: self match");
        Quote memory q = _quote(c, r.quoteAmount);
        require(_distance(q.tick, r.openingTick) <= MAX_TICK_DEVIATION, "MLB: quote moved");
        require(q.hstrAmount <= maxHstr, "MLB: HSTR limit");
        _commitWallet(r.campaignId, msg.sender, r.quoteAmount, c.terms.walletCap);
        if (r.hstrOwner == address(0)) {
            r.hstrOwner = msg.sender;
            r.hstrEscrow = q.hstrAmount;
            _pull(HSTR, msg.sender, q.hstrAmount);
        } else {
            require(q.hstrAmount <= r.hstrEscrow, "MLB: reopen HSTR quote");
            r.quoteOwner = msg.sender;
            _pull(USDT0, msg.sender, r.quoteAmount);
        }
        _userRounds[msg.sender].push(id);
        _match(id, q, minLiquidity, deadline);
    }

    /// @notice Creator cancellation is immediate; after expiry anyone can refund the original owner.
    function cancelRound(uint256 id) external nonReentrant {
        Round storage r = _rounds[id];
        require(r.state == State.Forming, "MLB: not forming");
        address creator = r.hstrOwner == address(0) ? r.quoteOwner : r.hstrOwner;
        require(msg.sender == creator || block.timestamp >= r.expiresAt, "MLB: not creator");
        r.state = State.Cancelled;
        Campaign storage c = _campaigns[r.campaignId];
        c.allocatedQuote -= r.quoteAmount;
        c.rewardFree += r.rewardTotal;
        walletCommitted[r.campaignId][creator] -= r.quoteAmount;
        if (r.hstrOwner != address(0)) {
            uint256 amount = r.hstrEscrow;
            r.hstrEscrow = 0;
            HSTR.safeTransfer(creator, amount);
        } else {
            USDT0.safeTransfer(creator, r.quoteAmount);
        }
        emit RoundCancelled(id);
    }

    /// @notice Either owner can close the mature NFT. Both sides then withdraw independently.
    function settleRound(uint256 id, uint256 minHstr, uint256 minUsdt0, uint256 deadline) external nonReentrant {
        _participant(_rounds[id], msg.sender);
        _settle(id, minHstr, minUsdt0, deadline);
    }

    function withdraw(uint256 id, uint256 minHstr, uint256 minUsdt0, uint256 deadline) external nonReentrant {
        Round storage r = _rounds[id];
        _participant(r, msg.sender);
        if (r.state == State.Active) _settle(id, minHstr, minUsdt0, deadline);
        require(r.state == State.Settled && !claimed[id][msg.sender].principal, "MLB: principal unavailable");
        claimed[id][msg.sender].principal = true;
        bool quoteSide = msg.sender == r.quoteOwner;
        uint256 a0 = _portion(r.principal0, r.quoteShare, quoteSide);
        uint256 a1 = _portion(r.principal1, r.quoteShare, quoteSide);
        if (a0 > 0) HSTR.safeTransfer(msg.sender, a0);
        if (a1 > 0) USDT0.safeTransfer(msg.sender, a1);
        emit PrincipalClaimed(id, msg.sender, a0, a1);
    }

    function claimRewards(uint256 id) external nonReentrant {
        Round storage r = _rounds[id];
        _participant(r, msg.sender);
        uint256 amount = pendingRewards(id, msg.sender);
        require(amount > 0, "MLB: no reward");
        claimed[id][msg.sender].reward += amount;
        address token = _campaigns[r.campaignId].terms.rewardToken;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit RewardsClaimed(id, msg.sender, token, amount);
    }

    function collectFees(uint256 id) external nonReentrant {
        require(_rounds[id].state == State.Active, "MLB: not active");
        _collectFees(_rounds[id]);
    }

    function claimFees(uint256 id) external nonReentrant {
        Round storage r = _rounds[id];
        _participant(r, msg.sender);
        require(r.state == State.Active || r.state == State.Settled, "MLB: not matched");
        if (r.state == State.Active) _collectFees(r);
        bool quoteSide = msg.sender == r.quoteOwner;
        Claimed storage paid = claimed[id][msg.sender];
        uint256 total0 = _portion(r.fees0, r.quoteFeeShare, quoteSide);
        uint256 total1 = _portion(r.fees1, r.quoteFeeShare, quoteSide);
        uint256 a0 = total0 - paid.fees0;
        uint256 a1 = total1 - paid.fees1;
        paid.fees0 = total0;
        paid.fees1 = total1;
        if (a0 > 0) HSTR.safeTransfer(msg.sender, a0);
        if (a1 > 0) USDT0.safeTransfer(msg.sender, a1);
        emit FeesClaimed(id, msg.sender, a0, a1);
    }

    function pendingRewards(uint256 id, address user) public view returns (uint256) {
        Round storage r = _rounds[id];
        if ((r.state != State.Active && r.state != State.Settled) || (user != r.hstrOwner && user != r.quoteOwner)) {
            return 0;
        }
        uint256 total = user == r.quoteOwner ? r.quoteReward : r.rewardTotal - r.quoteReward;
        uint256 duration = _campaigns[r.campaignId].terms.duration;
        uint256 vested = Math.mulDiv(total, Math.min(block.timestamp - r.matchedAt, duration), duration);
        return vested - claimed[id][user].reward;
    }

    function previewMatch(uint256 id, uint256 amount) external view returns (Quote memory) {
        return _quote(_campaign(id), amount);
    }

    /// @notice Total NFT principal, before ownership split; fees are excluded. Used for withdrawal slippage.
    function previewPrincipal(uint256 id) external view returns (uint256 a0, uint256 a1) {
        Round storage r = _rounds[id];
        if (r.state == State.Settled) return (r.principal0, r.principal1);
        if (r.state != State.Active) return (0, 0);
        Terms storage t = _campaigns[r.campaignId].terms;
        (uint160 p,,,,,,) = POOL.slot0();
        uint160 a = V3TickMath.getSqrtRatioAtTick(t.tickLower);
        uint160 b = V3TickMath.getSqrtRatioAtTick(t.tickUpper);
        if (p < b) {
            uint160 lower = p > a ? p : a;
            a0 = Math.mulDiv(Math.mulDiv(r.liquidity, uint256(b) - lower, b), Q96, lower);
        }
        if (p > a) a1 = Math.mulDiv(r.liquidity, uint256(p < b ? p : b) - a, Q96);
    }

    function getCampaign(uint256 id) external view returns (Campaign memory) {
        return _campaign(id);
    }

    function getRound(uint256 id) external view returns (Round memory) {
        require(_rounds[id].state != State.None, "MLB: round");
        return _rounds[id];
    }

    function userRounds(address user, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return _page(_userRounds[user], offset, limit);
    }

    function campaignRounds(uint256 id, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return _page(_campaignRounds[id], offset, limit);
    }

    function growOracle(uint16 cardinality) external {
        POOL.increaseObservationCardinalityNext(cardinality);
    }

    function _newRound(uint256 campaignId, uint256 amount, Quote memory q, bool hstrSide) private returns (uint256 id) {
        Campaign storage c = _campaigns[campaignId];
        require(amount >= c.terms.minQuote && c.allocatedQuote + amount <= c.terms.quoteCapacity, "MLB: capacity");
        require(q.reward > 0 && q.reward <= c.rewardFree, "MLB: reward funding");
        _commitWallet(campaignId, msg.sender, amount, c.terms.walletCap);
        c.allocatedQuote += amount;
        c.rewardFree -= q.reward;
        id = ++roundCount;
        Round storage r = _rounds[id];
        r.campaignId = campaignId;
        r.state = State.Forming;
        r.quoteAmount = amount;
        r.rewardTotal = q.reward;
        r.expiresAt = uint64(Math.min(block.timestamp + c.terms.fillWindow, c.terms.endsAt));
        r.openingTick = q.tick;
        if (hstrSide) r.hstrOwner = msg.sender;
        else r.quoteOwner = msg.sender;
        _userRounds[msg.sender].push(id);
        _campaignRounds[campaignId].push(id);
        emit RoundOpened(id, campaignId, msg.sender, hstrSide);
    }

    function _match(uint256 id, Quote memory q, uint128 minLiquidity, uint256 deadline) private {
        Round storage r = _rounds[id];
        Campaign storage c = _campaigns[r.campaignId];
        require(minLiquidity > 0, "MLB: set slippage");
        HSTR.forceApprove(address(NPM), q.hstrAmount);
        USDT0.forceApprove(address(NPM), r.quoteAmount);
        (uint256 nft, uint128 liquidity, uint256 used0, uint256 used1) = NPM.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(HSTR),
                token1: address(USDT0),
                fee: POOL.fee(),
                tickLower: c.terms.tickLower,
                tickUpper: c.terms.tickUpper,
                amount0Desired: q.hstrAmount,
                amount1Desired: r.quoteAmount,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: deadline
            })
        );
        HSTR.forceApprove(address(NPM), 0);
        USDT0.forceApprove(address(NPM), 0);
        require(
            liquidity >= minLiquidity && used0 > 0 && used1 > 0 && used0 <= q.hstrAmount && used1 <= r.quoteAmount,
            "MLB: mint slippage"
        );
        uint256 hstrValue = PositionMath.token0ValueInToken1(used0, q.sqrtPriceX96, Math.Rounding.Ceil);
        r.quoteShare = Math.mulDiv(used1, ONE, hstrValue + used1);
        require(r.quoteShare > 0 && r.quoteShare < ONE, "MLB: shares");
        r.quoteFeeShare = c.terms.mode == Mode.Treasury ? uint256(c.terms.userFeeBps) * 1e14 : r.quoteShare;
        r.quoteReward = c.terms.mode == Mode.Treasury ? r.rewardTotal : Math.mulDiv(r.rewardTotal, r.quoteShare, ONE);
        r.tokenId = nft;
        r.liquidity = liquidity;
        r.state = State.Active;
        r.matchedAt = uint64(block.timestamp);
        uint256 refund0 = r.hstrEscrow - used0;
        r.hstrEscrow = 0;
        if (refund0 > 0) {
            if (c.terms.mode == Mode.Treasury) c.inventory += refund0;
            else HSTR.safeTransfer(r.hstrOwner, refund0);
        }
        if (r.quoteAmount > used1) USDT0.safeTransfer(r.quoteOwner, r.quoteAmount - used1);
        emit RoundMatched(id, r.hstrOwner, r.quoteOwner, nft, liquidity, r.quoteShare);
    }

    function _settle(uint256 id, uint256 min0, uint256 min1, uint256 deadline) private {
        Round storage r = _rounds[id];
        require(
            r.state == State.Active
                && block.timestamp >= uint256(r.matchedAt) + _campaigns[r.campaignId].terms.duration,
            "MLB: locked"
        );
        require(deadline >= block.timestamp, "MLB: deadline");
        _collectFees(r);
        (uint256 a0, uint256 a1) = NPM.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: r.tokenId, liquidity: r.liquidity, amount0Min: min0, amount1Min: min1, deadline: deadline
            })
        );
        (uint256 collected0, uint256 collected1) = NPM.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: r.tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        require(collected0 >= a0 && collected1 >= a1, "MLB: incomplete collection");
        r.principal0 = a0;
        r.principal1 = a1;
        r.fees0 += collected0 - a0;
        r.fees1 += collected1 - a1;
        r.state = State.Settled;
        r.liquidity = 0;
        NPM.burn(r.tokenId);
        emit RoundSettled(id, a0, a1);
    }

    function _collectFees(Round storage r) private {
        (uint256 a0, uint256 a1) = NPM.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: r.tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        r.fees0 += a0;
        r.fees1 += a1;
    }

    function _quote(Campaign storage c, uint256 amount) private view returns (Quote memory q) {
        require(amount > 0, "MLB: amount");
        uint16 cardinality;
        (q.sqrtPriceX96, q.tick,, cardinality,,,) = POOL.slot0();
        require(cardinality > 1 && POOL.liquidity() > 0, "MLB: oracle unavailable");
        uint32[] memory ago = new uint32[](2);
        ago[0] = TWAP_WINDOW;
        (int56[] memory cumulative,) = POOL.observe(ago);
        int56 delta = cumulative[1] - cumulative[0];
        int56 window = int56(uint56(TWAP_WINDOW));
        int24 mean = int24(delta / window);
        if (delta < 0 && delta % window != 0) mean--;
        require(_distance(q.tick, mean) <= MAX_TICK_DEVIATION, "MLB: price off TWAP");
        uint160 a = V3TickMath.getSqrtRatioAtTick(c.terms.tickLower);
        uint160 b = V3TickMath.getSqrtRatioAtTick(c.terms.tickUpper);
        q.hstrAmount = PositionMath.token0For(amount, q.sqrtPriceX96, a, b);
        uint256 l = Math.mulDiv(amount, Q96, uint256(q.sqrtPriceX96) - a);
        require(l > 0 && l <= type(uint128).max, "MLB: liquidity overflow");
        q.liquidity = uint128(l);
        q.quoteShare = Math.mulDiv(
            amount, ONE, amount + PositionMath.token0ValueInToken1(q.hstrAmount, q.sqrtPriceX96, Math.Rounding.Ceil)
        );
        q.reward = Math.mulDiv(c.terms.rewardBudget, amount, c.terms.quoteCapacity);
    }

    function _open(uint256 id, uint256 deadline) private view returns (Campaign storage c) {
        c = _campaign(id);
        require(!paused && !c.closed && block.timestamp < c.terms.endsAt, "MLB: campaign closed");
        require(deadline >= block.timestamp, "MLB: deadline");
    }

    function _campaign(uint256 id) private view returns (Campaign storage c) {
        require(id > 0 && id <= campaignCount, "MLB: campaign");
        c = _campaigns[id];
    }

    function _commitWallet(uint256 id, address user, uint256 amount, uint256 cap) private {
        uint256 next = walletCommitted[id][user] + amount;
        require(next <= cap, "MLB: wallet cap");
        walletCommitted[id][user] = next;
    }

    function _participant(Round storage r, address user) private view {
        require(user != address(0) && (user == r.hstrOwner || user == r.quoteOwner), "MLB: not participant");
    }

    function _portion(uint256 total, uint256 quoteShare, bool quoteSide) private pure returns (uint256) {
        uint256 q = Math.mulDiv(total, quoteShare, ONE);
        return quoteSide ? q : total - q;
    }

    function _distance(int24 a, int24 b) private pure returns (uint24) {
        return uint24(a > b ? a - b : b - a);
    }

    function _pull(IERC20 token, address from, uint256 amount) private {
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        require(token.balanceOf(address(this)) - beforeBalance == amount, "MLB: unsupported token");
    }

    function _page(uint256[] storage source, uint256 offset, uint256 limit)
        private
        view
        returns (uint256[] memory ids, uint256 total)
    {
        require(limit <= 100, "MLB: page limit");
        total = source.length;
        uint256 end = offset < total ? offset + Math.min(limit, total - offset) : offset;
        ids = new uint256[](end - offset);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = source[offset + i];
        }
    }
}
