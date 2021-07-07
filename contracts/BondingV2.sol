// SPDX-License-Identifier: MIT
pragma solidity ^0.8.3;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./interfaces/IERC1155Ubiquity.sol";
import "./interfaces/IMetaPool.sol";
import "./interfaces/IUbiquityFormulas.sol";
import "./UbiquityAlgorithmicDollar.sol";
import "./BondingFormulas.sol";
import "./BondingShareV2.sol";
import "./UbiquityAlgorithmicDollarManager.sol";
import "./interfaces/ISablier.sol";
import "./interfaces/IMasterChefV2.sol";
import "./interfaces/ITWAPOracle.sol";
import "./interfaces/IERC1155Ubiquity.sol";
import "./utils/CollectableDust.sol";

contract BondingV2 is CollectableDust, Pausable {
    using SafeERC20 for IERC20;

    bytes public data = "";
    UbiquityAlgorithmicDollarManager public manager;
    uint256 public constant ONE = uint256(1 ether); // 3Crv has 18 decimals
    uint256 public bondingDiscountMultiplier = uint256(1000000 gwei); // 0.001
    uint256 public blockCountInAWeek = 45361;
    uint256 public accLpRewardPerShare = 0;
    uint256 public lpToMigrate; // LP that are inside the bondign contract but need to be migrated
    uint256 public lpRewards;
    address public bondingShareV1Address;
    address public bondingFormulasAddress;
    address public migrator; // temporary address to handle migration
    // array 0: lp deposited,  1: weeks, 2: migrated (0=false 1 =true)
    mapping(address => uint256[]) private _v1Holders;

    event PriceReset(
        address _tokenWithdrawn,
        uint256 _amountWithdrawn,
        uint256 _amountTransfered,
        uint256 _uADPrice
    );

    event Deposit(
        address indexed _user,
        uint256 indexed _id,
        uint256 _lpAmount,
        uint256 _bondingShareAmount,
        uint256 _weeks,
        uint256 _endBlock
    );
    event RemoveLiquidityFromBond(
        address indexed _user,
        uint256 indexed _id,
        uint256 _lpAmount,
        uint256 _bondingShareAmount
    );

    event AddLiquidityFromBond(
        address indexed _user,
        uint256 indexed _id,
        uint256 _lpAmount,
        uint256 _bondingShareAmount
    );

    event BondingDiscountMultiplierUpdated(uint256 _bondingDiscountMultiplier);
    event BlockCountInAWeekUpdated(uint256 _blockCountInAWeek);

    event Migrated(
        address indexed _user,
        uint256 indexed _id,
        uint256 _lpsAmount,
        uint256 _sharesAmount,
        uint256 _weeks
    );

    modifier onlyBondingManager() {
        require(
            manager.hasRole(manager.BONDING_MANAGER_ROLE(), msg.sender),
            "not manager"
        );
        _;
    }

    modifier onlyMigrator() {
        require(msg.sender == migrator, "not migrator");
        _;
    }

    constructor(
        address _manager,
        address _bondingFormulasAddress,
        address _bondingShareV1Address,
        address[] memory _originals,
        uint256[] memory _lpBalances,
        uint256[] memory _weeks
    ) CollectableDust() Pausable() {
        blockCountInAWeek = 45361;
        manager = UbiquityAlgorithmicDollarManager(_manager);
        bondingShareV1Address = _bondingShareV1Address;
        bondingFormulasAddress = _bondingFormulasAddress;
        migrator = msg.sender;
        for (uint256 index = 0; index < _originals.length; index++) {
            lpToMigrate += _lpBalances[index];
            _v1Holders[_originals[index]] = [
                _lpBalances[index],
                _weeks[index],
                0
            ];
        }
    }

    // solhint-disable-next-line no-empty-blocks
    receive() external payable {}

    /// @dev addUserToMigrate add a user to migrate from V1
    /// @param _original address of v1 user
    /// @param _lpBalance LP Balance of v1 user
    /// @param _weeks weeks lockup of v1 user
    /// @notice user will then be able to migrate
    function addUserToMigrate(
        address _original,
        uint256 _lpBalance,
        uint256 _weeks
    ) external onlyMigrator {
        lpToMigrate += _lpBalance;
        _v1Holders[_original] = [_lpBalance, _weeks, 0];
    }

    /// @dev removeUserToMigrate set  user as  migrated from V1
    /// @param _original address of v1 user
    /// @notice user will then be able to migrate
    function removeUserToMigrate(address _original) external onlyMigrator {
        _v1Holders[_original] = [0, 0, 1];
    }

    /// @dev migrate let a user migrate from V1
    /// @notice user will then be able to migrate
    function migrate() external returns (uint256 _id) {
        require(
            _v1Holders[msg.sender][0] > 0 && _v1Holders[msg.sender][2] == 0,
            "not registered or migrated"
        );
        uint256 _lpsAmount = _v1Holders[msg.sender][0];
        uint256 _weeks = _v1Holders[msg.sender][1];
        lpToMigrate -= _lpsAmount;

        // calculate the amount of share based on the amount of lp deposited and the duration
        uint256 _sharesAmount = IUbiquityFormulas(manager.formulasAddress())
        .durationMultiply(_lpsAmount, _weeks, bondingDiscountMultiplier);

        // calculate end locking period block number
        uint256 endBlock = block.number + _weeks * blockCountInAWeek;
        _id = _mint(_lpsAmount, _sharesAmount, endBlock);

        // set masterchef for uGOV rewards
        IMasterChefV2(manager.masterChefAddress()).deposit(
            msg.sender,
            _sharesAmount,
            _id
        );
        _v1Holders[msg.sender] = [0, 0, 1];
        emit Migrated(msg.sender, _id, _lpsAmount, _sharesAmount, _weeks);
    }

    function setMigrator(address _migrator) external onlyMigrator {
        migrator = _migrator;
    }

    /// @dev uADPriceReset remove uAD unilateraly from the curve LP share sitting inside
    ///      the bonding contract and send the uAD received to the treasury.
    ///      This will have the immediate effect of pushing the uAD price HIGHER
    /// @param amount of LP token to be removed for uAD
    /// @notice it will remove one coin only from the curve LP share sitting in the bonding contract
    function uADPriceReset(uint256 amount) external onlyBondingManager {
        IMetaPool metaPool = IMetaPool(manager.stableSwapMetaPoolAddress());
        // safe approve
        IERC20(manager.stableSwapMetaPoolAddress()).safeApprove(
            address(this),
            0
        );

        IERC20(manager.stableSwapMetaPoolAddress()).safeApprove(
            address(this),
            amount
        );
        // remove one coin
        uint256 expected = (metaPool.calc_withdraw_one_coin(amount, 0) * 99) /
            100;
        // update twap
        uint256 coinWithdrawn = metaPool.remove_liquidity_one_coin(
            amount,
            0,
            expected
        );
        ITWAPOracle(manager.twapOracleAddress()).update();
        uint256 toTransfer = IERC20(manager.dollarTokenAddress()).balanceOf(
            address(this)
        );
        IERC20(manager.dollarTokenAddress()).safeTransfer(
            manager.treasuryAddress(),
            toTransfer
        );
        emit PriceReset(
            manager.dollarTokenAddress(),
            coinWithdrawn,
            toTransfer,
            currentTokenPrice()
        );
    }

    /// @dev crvPriceReset remove 3CRV unilateraly from the curve LP share sitting inside
    ///      the bonding contract and send the 3CRV received to the treasury
    ///      This will have the immediate effect of pushing the uAD price LOWER
    /// @param amount of LP token to be removed for 3CRV tokens
    /// @notice it will remove one coin only from the curve LP share sitting in the bonding contract
    function crvPriceReset(uint256 amount) external onlyBondingManager {
        IMetaPool metaPool = IMetaPool(manager.stableSwapMetaPoolAddress());
        // safe approve
        IERC20(manager.stableSwapMetaPoolAddress()).safeApprove(
            address(this),
            0
        );
        // safe approve
        IERC20(manager.stableSwapMetaPoolAddress()).safeApprove(
            address(this),
            amount
        );
        // remove one coin
        uint256 expected = (metaPool.calc_withdraw_one_coin(amount, 1) * 99) /
            100;
        // update twap
        uint256 coinWithdrawn = metaPool.remove_liquidity_one_coin(
            amount,
            1,
            expected
        );
        ITWAPOracle(manager.twapOracleAddress()).update();
        uint256 toTransfer = IERC20(manager.curve3PoolTokenAddress()).balanceOf(
            address(this)
        );
        IERC20(manager.curve3PoolTokenAddress()).safeTransfer(
            manager.treasuryAddress(),
            toTransfer
        );
        emit PriceReset(
            manager.curve3PoolTokenAddress(),
            coinWithdrawn,
            toTransfer,
            currentTokenPrice()
        );
    }

    function setBondingFormulasAddress(address _bondingFormulasAddress)
        external
        onlyBondingManager
    {
        bondingFormulasAddress = _bondingFormulasAddress;
    }

    /// Collectable Dust
    function addProtocolToken(address _token)
        external
        override
        onlyBondingManager
    {
        _addProtocolToken(_token);
    }

    function removeProtocolToken(address _token)
        external
        override
        onlyBondingManager
    {
        _removeProtocolToken(_token);
    }

    function sendDust(
        address _to,
        address _token,
        uint256 _amount
    ) external override onlyBondingManager {
        _sendDust(_to, _token, _amount);
    }

    function setBondingDiscountMultiplier(uint256 _bondingDiscountMultiplier)
        external
        onlyBondingManager
    {
        bondingDiscountMultiplier = _bondingDiscountMultiplier;
        emit BondingDiscountMultiplierUpdated(_bondingDiscountMultiplier);
    }

    function setBlockCountInAWeek(uint256 _blockCountInAWeek)
        external
        onlyBondingManager
    {
        blockCountInAWeek = _blockCountInAWeek;
        emit BlockCountInAWeekUpdated(_blockCountInAWeek);
    }

    /// @dev deposit uAD-3CRV LP tokens for a duration to receive bonding shares
    /// @param _lpsAmount of LP token to send
    /// @param _weeks during lp token will be held
    /// @notice weeks act as a multiplier for the amount of bonding shares to be received
    function deposit(uint256 _lpsAmount, uint256 _weeks)
        external
        returns (uint256 _id)
    {
        require(
            1 <= _weeks && _weeks <= 208,
            "Bonding: duration must be between 1 and 208 weeks"
        );
        _updateOracle();

        // transfer lp token to the bonding contract
        IERC20(manager.stableSwapMetaPoolAddress()).safeTransferFrom(
            msg.sender,
            address(this),
            _lpsAmount
        );

        // calculate the amount of share based on the amount of lp deposited and the duration
        uint256 _sharesAmount = IUbiquityFormulas(manager.formulasAddress())
        .durationMultiply(_lpsAmount, _weeks, bondingDiscountMultiplier);

        // calculate end locking period block number
        // 1 week = 45361 blocks = 2371753*7/366
        // n = (block + duration * 45361)
        // id = n - n % blockRonding
        // blockRonding = 100 => 2 ending zeros
        uint256 _endBlock = block.number + _weeks * blockCountInAWeek;

        _id = _mint(_lpsAmount, _sharesAmount, _endBlock);

        // set masterchef for uGOV rewards
        IMasterChefV2(manager.masterChefAddress()).deposit(
            msg.sender,
            _sharesAmount,
            _id
        );

        emit Deposit(
            msg.sender,
            _id,
            _lpsAmount,
            _sharesAmount,
            _weeks,
            _endBlock
        );
    }

    /// @dev Add an amount of uAD-3CRV LP tokens
    /// @param _amount of LP token to deposit
    /// @param _id bonding shares id
    /// @param _weeks during lp token will be held
    /// @notice bonding shares are ERC1155 (aka NFT) because they have an expiration date
    function addLiquidity(
        uint256 _amount,
        uint256 _id,
        uint256 _weeks
    ) external {
        require(
            IERC1155Ubiquity(manager.bondingShareAddress()).balanceOf(
                msg.sender,
                _id
            ) == 1,
            "Bonding: caller is not owner"
        );
        BondingShareV2 bonding = BondingShareV2(manager.bondingShareAddress());
        BondingShareV2.Bond memory bond = bonding.getBond(_id);
        require(
            block.number > bond.endBlock,
            "Bonding: Redeem not allowed before bonding time"
        );
        _updateOracle();

        // calculate pending LP rewards
        uint256[2] memory bs = IMasterChefV2(manager.masterChefAddress())
        .getBondingShareInfo(_id);
        uint256 sharesToRemove = bs[0];
        _updateLpPerShare();
        uint256 pendingLpReward = lpRewardForShares(
            sharesToRemove,
            bond.lpRewardDebt
        );

        // add an extra step to be able to decrease rewards if locking end is near
        pendingLpReward = BondingFormulas(this.bondingFormulasAddress())
        .lpRewardsNormalization(bond, bs, pendingLpReward);
        // add these LP Rewards to the deposited amount of LP token
        bond.lpAmount += pendingLpReward;

        IERC20(manager.stableSwapMetaPoolAddress()).safeTransferFrom(
            msg.sender,
            address(this),
            _amount
        );
        bond.lpAmount += _amount;

        // redeem all shares
        IMasterChefV2(manager.masterChefAddress()).withdraw(
            msg.sender,
            sharesToRemove,
            _id
        );

        // calculate the amount of share based on the new amount of lp deposited and the duration
        uint256 _sharesAmount = IUbiquityFormulas(manager.formulasAddress())
        .durationMultiply(bond.lpAmount, _weeks, bondingDiscountMultiplier);

        // deposit new shares
        IMasterChefV2(manager.masterChefAddress()).deposit(
            msg.sender,
            _sharesAmount,
            _id
        );
        // calculate end locking period block number
        // 1 week = 45361 blocks = 2371753*7/366
        // n = (block + duration * 45361)
        // id = n - n % blockRonding
        // blockRonding = 100 => 2 ending zeros
        bond.endBlock = block.number + _weeks * blockCountInAWeek;

        // bond.lpRewardDebt = (bonding shares * accLpRewardPerShare) /  1e18;
        // user.amount.mul(pool.accSushiPerShare).div(1e12);
        // should be done after masterchef withdraw
        _updateLpPerShare();
        bond.lpRewardDebt =
            (IMasterChefV2(manager.masterChefAddress()).getBondingShareInfo(
                _id
            )[0] * accLpRewardPerShare) /
            1e12;

        BondingShareV2(manager.bondingShareAddress()).updateBond(
            _id,
            bond.lpAmount,
            bond.lpRewardDebt,
            bond.endBlock
        );

        emit AddLiquidityFromBond(
            msg.sender,
            _id,
            bond.lpAmount,
            _sharesAmount
        );
    }

    /// @dev Remove an amount of uAD-3CRV LP tokens
    /// @param _amount of LP token deposited when _id was created to be withdrawn
    /// @param _id bonding shares id
    /// @notice bonding shares are ERC1155 (aka NFT) because they have an expiration date
    function removeLiquidity(uint256 _amount, uint256 _id) external {
        require(
            IERC1155Ubiquity(manager.bondingShareAddress()).balanceOf(
                msg.sender,
                _id
            ) == 1,
            "Bonding: caller is not owner"
        );
        BondingShareV2 bonding = BondingShareV2(manager.bondingShareAddress());
        BondingShareV2.Bond memory bond = bonding.getBond(_id);
        require(
            block.number > bond.endBlock,
            "Bonding: Redeem not allowed before bonding time"
        );

        require(bond.lpAmount >= _amount, "Bonding: amount too big");

        _updateOracle();
        uint256[2] memory bs = IMasterChefV2(manager.masterChefAddress())
        .getBondingShareInfo(_id);

        // we should decrease the UBQ rewards proportionally to the LP removed
        // sharesToRemove = (bonding shares * _amount )  / bond.lpAmount ;
        uint256 sharesToRemove = BondingFormulas(this.bondingFormulasAddress())
        .sharesForLP(bond, bs, _amount);

        // update bonding shares
        // bond.shares = bond.shares - sharesToRemove;
        // get masterchef for uGOV rewards To ensure correct computation
        // it needs to be done BEFORE updating the bonding share
        IMasterChefV2(manager.masterChefAddress()).withdraw(
            msg.sender,
            sharesToRemove,
            _id
        );

        // redeem of the extra LP
        // bonding lp balance - BondingShareV2.totalLP
        IERC20 metapool = IERC20(manager.stableSwapMetaPoolAddress());
        _updateLpPerShare();
        uint256 pendingLpReward = lpRewardForShares(
            sharesToRemove,
            bond.lpRewardDebt
        );

        // add an extra step to be able to decrease rewards if locking end is near
        pendingLpReward = BondingFormulas(this.bondingFormulasAddress())
        .lpRewardsNormalization(bond, bs, pendingLpReward);

        bond.lpAmount = bond.lpAmount - _amount;

        // bond.lpRewardDebt = (bonding shares * accLpRewardPerShare) /  1e18;
        // user.amount.mul(pool.accSushiPerShare).div(1e12);
        // should be done after masterchef withdraw
        bond.lpRewardDebt =
            (IMasterChefV2(manager.masterChefAddress()).getBondingShareInfo(
                _id
            )[0] * accLpRewardPerShare) /
            1e12;

        BondingShareV2(manager.bondingShareAddress()).updateBond(
            _id,
            bond.lpAmount,
            bond.lpRewardDebt,
            bond.endBlock
        );

        // lastly redeem lp tokens
        metapool.safeTransfer(msg.sender, _amount + pendingLpReward);
        emit RemoveLiquidityFromBond(
            msg.sender,
            _id,
            _amount + pendingLpReward,
            sharesToRemove
        );
    }

    // View function to see pending lpRewards on frontend.
    function pendingLpRewards(uint256 _id) external view returns (uint256) {
        BondingShareV2 bonding = BondingShareV2(manager.bondingShareAddress());
        BondingShareV2.Bond memory bond = bonding.getBond(_id);
        uint256[2] memory bs = IMasterChefV2(manager.masterChefAddress())
        .getBondingShareInfo(_id);

        uint256 lpBalance = IERC20(manager.stableSwapMetaPoolAddress())
        .balanceOf(address(this));
        // the excess LP is the current balance minus the total deposited LP
        uint256 currentLpRewards = lpBalance - bonding.totalLP();
        uint256 newLpRewards = currentLpRewards - lpRewards;

        uint256 curAccLpRewardPerShare = accLpRewardPerShare +
            ((newLpRewards * 1e12) /
                IMasterChefV2(manager.masterChefAddress()).totalShares());
        // we multiply the shares amount by the accumulated lpRewards per share
        // and remove the lp Reward Debt
        return
            (bs[0] * (curAccLpRewardPerShare)) / (1e12) - (bond.lpRewardDebt);
    }

    /// @dev return the amount of Lp token to be sent for the amount of shares an debt
    /// @param amount of bonding shares
    /// @param lpRewardDebt lp rewards that has already been distributed
    function lpRewardForShares(uint256 amount, uint256 lpRewardDebt)
        public
        view
        returns (uint256 pendingLpReward)
    {
        if (accLpRewardPerShare > 0) {
            pendingLpReward =
                (amount * accLpRewardPerShare) /
                1e12 -
                (lpRewardDebt);
        }
    }

    function currentShareValue() public view returns (uint256 priceShare) {
        uint256 totalShares = IMasterChefV2(manager.masterChefAddress())
        .totalShares();
        // priceShare = totalLP / totalShares
        priceShare = IUbiquityFormulas(manager.formulasAddress()).bondPrice(
            BondingShareV2(manager.bondingShareAddress()).totalLP(),
            totalShares,
            ONE
        );
    }

    function currentTokenPrice() public view returns (uint256) {
        return
            ITWAPOracle(manager.twapOracleAddress()).consult(
                manager.dollarTokenAddress()
            );
    }

    /// @dev update the accumulated excess LP per share
    function _updateLpPerShare() internal {
        BondingShareV2 bond = BondingShareV2(manager.bondingShareAddress());
        uint256 lpBalance = IERC20(manager.stableSwapMetaPoolAddress())
        .balanceOf(address(this));
        // the excess LP is the current balance
        // minus the total deposited LP + LP that needs to be migrated
        if (lpBalance > (bond.totalLP() + lpToMigrate)) {
            uint256 currentLpRewards = lpBalance -
                (bond.totalLP() + lpToMigrate);
            uint256 newLpRewards = currentLpRewards - lpRewards;
            // is there new LP rewards to be distributed ?
            if (newLpRewards >= 0) {
                // we calculate the new accumulated LP rewards per share
                accLpRewardPerShare =
                    accLpRewardPerShare +
                    ((newLpRewards * 1e12) /
                        IMasterChefV2(manager.masterChefAddress())
                        .totalShares());
                // update the bonding contract lpRewards
                lpRewards = currentLpRewards;
            }
        }
    }

    function _mint(
        uint256 lpAmount,
        uint256 shares,
        uint256 endBlock
    ) internal returns (uint256) {
        uint256 _currentShareValue = currentShareValue();
        require(
            _currentShareValue != 0,
            "Bonding: share value should not be null"
        );
        // update the accumulated lp rewards per shares
        _updateLpPerShare();
        // set the lp rewards debts so that this bonding share only get lp rewards from this day
        uint256 lpRewardDebt = shares * accLpRewardPerShare;
        return
            BondingShareV2(manager.bondingShareAddress()).mint(
                msg.sender,
                lpAmount,
                lpRewardDebt,
                endBlock
            );
    }

    function _updateOracle() internal {
        ITWAPOracle(manager.twapOracleAddress()).update();
    }
}