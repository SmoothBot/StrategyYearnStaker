// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;


// These are the core Yearn libraries
import "@yearnvaults/contracts/BaseStrategy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

// import "./Interfaces/UniswapInterfaces/IUniswapV2Router02.sol";
// import "./Interfaces/CurveInterfaces/ICurveFi.sol";
import "./Interfaces/yearn.sol";

interface IERC20Extended is IERC20 {
    function decimals() external view returns (uint8);
}

contract StrategyStargateStaker is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */
    IVault public constant yvVault = IVault(0xEF0210eB96c7EB36AF8ed1c20306462764935607); // yvUSDC
    uint256 public constant decimals = 6; // USDC
    uint256 public maxLoss = 1;

    string internal stratName; // we use this for our strategy's name on cloning
    bool internal isOriginal = true;

    bool internal forceHarvestTriggerOnce; // only set this to true externally when we want to trigger our keepers to harvest for us
    uint256 public minHarvestCredit; // if we hit this amount of credit, harvest the strategy
    uint256 BPS_ADJ = 10000;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _vault,
        string memory _name
    ) public BaseStrategy(_vault) {
        _initializeStrat(_name);
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        string memory _name
    ) public {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrat(_name);
    }

    // this is called by our original strategy, as well as any clones
    function _initializeStrat(string memory _name) internal {
        // initialize variables
        maxReportDelay = 14400; // 4 hours
        healthCheck = address(0xebc79550f3f3Bc3424dde30A157CE3F22b66E274); // Fantom common health check

        // set our strategy's name
        stratName = _name;

        // turn off our credit harvest trigger to start with
        minHarvestCredit = type(uint256).max;

        // add approvals on all tokens
        want.approve(address(yvVault), type(uint256).max);
    }

    /* ========== VIEWS ========== */

    function name() external view override returns (string memory) {
        return stratName;
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function sharesToWant(uint256 _shares) public view returns (uint256) {
        return _shares.mul(yvVault.pricePerShare()).div(10**decimals);
    }

    function wantToShares(uint256 _want) public view returns (uint256) {
        return _want.mul(10**decimals).div(yvVault.pricePerShare());
    }

    function withdrawStaked(uint256 _amountWant) internal {
        // Will revert if masterchef.withdraw if called with amount > balance
        // uint256 shares = Math.min(wantToShares(_amountWant), balanceStaked());
        uint256 shares = wantToShares(_amountWant);
        yvVault.withdraw(shares, address(this), maxLoss);
    }

    function balanceStaked() public view returns (uint256) {
        return sharesToWant(yvVault.balanceOf(address(this)));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        // look at our staked tokens and any free tokens sitting in the strategy
        return balanceStaked().add(balanceOfWant());
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function setMaxLoss(uint256 _maxLoss) external onlyEmergencyAuthorized {
        maxLoss = _maxLoss;
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        uint256 assets = estimatedTotalAssets();
        uint256 wantBal = balanceOfWant();

        uint256 debt = vault.strategies(address(this)).totalDebt;
        uint256 amountToFree;

        if (assets >= debt) {
            _debtPayment = _debtOutstanding;
            _profit = assets - debt;

            amountToFree = _profit.add(_debtPayment);

            if (amountToFree > 0 && wantBal < amountToFree) {
                liquidatePosition(amountToFree);

                uint256 newLoose = want.balanceOf(address(this));

                // if we dont have enough money adjust _debtOutstanding and only change profit if needed
                if (newLoose < amountToFree) {
                    if (_profit > newLoose) {
                        _profit = newLoose;
                        _debtPayment = 0;
                    } else {
                        _debtPayment = Math.min(
                            newLoose - _profit,
                            _debtPayment
                        );
                    }
                }
            }
        } else {
            // Serious loss should never happen but if it does lets record it accurately
            // If entering here, it's usually because of a rounding error.
            _loss = debt - assets;

            if (_debtOutstanding > 0) {
                if (_loss >= _debtOutstanding) {
                    _debtPayment = 0;
                } else {
                    _debtPayment = _debtOutstanding.sub(_loss);

                    if (wantBal < _debtPayment) {
                        liquidatePosition(_debtPayment);
                        _debtPayment = want.balanceOf(address(this));
                    }
                }
            }
        }

        // we're done harvesting, so reset our trigger if we used it
        forceHarvestTriggerOnce = false;
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (emergencyExit) {
            return;
        }
        // send all of our want tokens to be deposited
        uint256 toInvest = balanceOfWant();
        // stake only if we have something to stake
        if (toInvest > 0) {
            yvVault.deposit(toInvest);
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 wantBalance = want.balanceOf(address(this));
        if (_amountNeeded > wantBalance) {
            withdrawStaked(_amountNeeded.sub(wantBalance));
            _liquidatedAmount = Math.min(balanceOfWant(), _amountNeeded);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        if (balanceStaked() > 0) {
            yvVault.withdraw(yvVault.balanceOf(address(this)), address(this), maxLoss);
        }
        return balanceOfWant();
    }

    event Log(uint256 assets, uint256 wantBalance);
    function prepareMigration(address _newStrategy) internal override {
        uint256 assets = estimatedTotalAssets();
        liquidateAllPositions();
        uint256 wantBalance = balanceOfWant();
        // ensure the required assets have been liquidated
        emit Log(assets, wantBalance);
        // require(wantBalance >= assets.mul(BPS_ADJ.sub(maxLoss)).div(BPS_ADJ));
    }

    ///@notice Only do this if absolutely necessary; as assets will be withdrawn but rewards won't be claimed.
    function emergencyWithdraw() external onlyEmergencyAuthorized {
        yvVault.withdraw(yvVault.balanceOf(address(this)), address(this), maxLoss);
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    // our main trigger is regarding our DCA since there is low liquidity for our emissionToken
    function harvestTrigger(uint256 callCostinEth)
        public
        view
        override
        returns (bool)
    {
        StrategyParams memory params = vault.strategies(address(this));

        // harvest no matter what once we reach our maxDelay
        if (block.timestamp.sub(params.lastReport) > maxReportDelay) {
            return true;
        }

        // trigger if we want to manually harvest
        if (forceHarvestTriggerOnce) {
            return true;
        }

        // trigger if we have enough credit
        if (vault.creditAvailable() >= minHarvestCredit) {
            return true;
        }

        // otherwise, we don't harvest
        return false;
    }

    function ethToWant(uint256 _amtInWei)
        public
        view
        override
        returns (uint256)
    {}

    /* ========== SETTERS ========== */

    ///@notice This allows us to manually harvest with our keeper as needed
    function setForceHarvestTriggerOnce(bool _forceHarvestTriggerOnce)
        external
        onlyAuthorized
    {
        forceHarvestTriggerOnce = _forceHarvestTriggerOnce;
    }

    ///@notice When our strategy has this much credit, harvestTrigger will be true.
    function setMinHarvestCredit(uint256 _minHarvestCredit)
        external
        onlyAuthorized
    {
        minHarvestCredit = _minHarvestCredit;
    }

    receive() external payable {}
}
