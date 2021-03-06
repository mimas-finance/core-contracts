pragma solidity 0.5.17;

import "./MmToken.sol";
import "./ErrorReporter.sol";
import "./PriceOracle.sol";
import "./ComptrollerInterface.sol";
import "./ComptrollerStorage.sol";
import "./Unitroller.sol";
import "./Governance/Mimas.sol";
import "./EIP20Interface.sol";

/**
 * @title Mimas' Comptroller Contract
 * @author Mimas
 */
contract Comptroller is ComptrollerVXStorage, ComptrollerInterface, ComptrollerErrorReporter, ExponentialNoError {
    /// @notice Emitted when an admin supports a market
    event MarketListed(MmToken mmToken);

    /// @notice Emitted when an account enters a market
    event MarketEntered(MmToken mmToken, address account);

    /// @notice Emitted when an account exits a market
    event MarketExited(MmToken mmToken, address account);

    /// @notice Emitted when close factor is changed by admin
    event NewCloseFactor(uint oldCloseFactorMantissa, uint newCloseFactorMantissa);

    /// @notice Emitted when a collateral factor is changed by admin
    event NewCollateralFactor(MmToken mmToken, uint oldCollateralFactorMantissa, uint newCollateralFactorMantissa);

    /// @notice Emitted when liquidation incentive is changed by admin
    event NewLiquidationIncentive(uint oldLiquidationIncentiveMantissa, uint newLiquidationIncentiveMantissa);

    /// @notice Emitted when price oracle is changed
    event NewPriceOracle(PriceOracle oldPriceOracle, PriceOracle newPriceOracle);

    /// @notice Emitted when pause guardian is changed
    event NewPauseGuardian(address oldPauseGuardian, address newPauseGuardian);

    /// @notice Emitted when an action is paused globally
    event ActionPaused(string action, bool pauseState);

    /// @notice Emitted when an action is paused on a market
    event ActionPaused(MmToken mmToken, string action, bool pauseState);

    /// @notice Emitted when a new borrow-side MIMAS or CRO speed is calculated for a market
    event BorrowSpeedUpdated(uint8 tokenType, MmToken indexed mmToken, uint newSpeed);

    /// @notice Emitted when a new supply-side MIMAS or CRO speed is calculated for a market
    event SupplySpeedUpdated(uint8 tokenType, MmToken indexed mmToken, uint newSpeed);

    /// @notice Emitted when a new MIMAS speed is set for a contributor
    event ContributorMimasSpeedUpdated(address indexed contributor, uint newSpeed);

    /// @notice Emitted when MIMAS or CRO is distributed to a borrower
    event DistributedBorrowerReward(uint8 indexed tokenType, MmToken indexed mmToken, address indexed borrower, uint mimasDelta, uint mimasBorrowIndex);

    /// @notice Emitted when MIMAS or CRO is distributed to a supplier
    event DistributedSupplierReward(uint8 indexed tokenType, MmToken indexed mmToken, address indexed borrower, uint mimasDelta, uint mimasBorrowIndex);

    /// @notice Emitted when borrow cap for a mmToken is changed
    event NewBorrowCap(MmToken indexed mmToken, uint newBorrowCap);

    /// @notice Emitted when borrow cap guardian is changed
    event NewBorrowCapGuardian(address oldBorrowCapGuardian, address newBorrowCapGuardian);

    /// @notice Emitted when MIMAS is granted by admin
    event MimasGranted(address recipient, uint amount);

    /// @notice The initial MIMAS and CRO index for a market
    uint224 public constant initialIndexConstant = 1e36;

    // closeFactorMantissa must be strictly greater than this value
    uint internal constant closeFactorMinMantissa = 0.05e18; // 0.05

    // closeFactorMantissa must not exceed this value
    uint internal constant closeFactorMaxMantissa = 0.9e18; // 0.9

    // No collateralFactorMantissa may exceed this value
    uint internal constant collateralFactorMaxMantissa = 0.9e18; // 0.9

    // reward token type to show MIMAS or CRO
    uint8 public constant rewardMimas = 0;
    uint8 public constant rewardCro = 1;

    constructor() public {
        admin = msg.sender;
    }

    /*** Assets You Are In ***/

    /**
     * @notice Returns the assets an account has entered
     * @param account The address of the account to pull assets for
     * @return A dynamic list with the assets the account has entered
     */
    function getAssetsIn(address account) external view returns (MmToken[] memory) {
        MmToken[] memory assetsIn = accountAssets[account];

        return assetsIn;
    }

    /**
     * @notice Returns whether the given account is entered in the given asset
     * @param account The address of the account to check
     * @param mmToken The mmToken to check
     * @return True if the account is in the asset, otherwise false.
     */
    function checkMembership(address account, MmToken mmToken) external view returns (bool) {
        return markets[address(mmToken)].accountMembership[account];
    }

    /**
     * @notice Add assets to be included in account liquidity calculation
     * @param mmTokens The list of addresses of the mmToken markets to be enabled
     * @return Success indicator for whether each corresponding market was entered
     */
    function enterMarkets(address[] memory mmTokens) public returns (uint[] memory) {
        uint len = mmTokens.length;

        uint[] memory results = new uint[](len);
        for (uint i = 0; i < len; i++) {
            MmToken mmToken = MmToken(mmTokens[i]);

            results[i] = uint(addToMarketInternal(mmToken, msg.sender));
        }

        return results;
    }

    /**
     * @notice Add the market to the borrower's "assets in" for liquidity calculations
     * @param mmToken The market to enter
     * @param borrower The address of the account to modify
     * @return Success indicator for whether the market was entered
     */
    function addToMarketInternal(MmToken mmToken, address borrower) internal returns (Error) {
        Market storage marketToJoin = markets[address(mmToken)];

        if (!marketToJoin.isListed) {
            // market is not listed, cannot join
            return Error.MARKET_NOT_LISTED;
        }

        if (marketToJoin.accountMembership[borrower] == true) {
            // already joined
            return Error.NO_ERROR;
        }

        // survived the gauntlet, add to list
        // NOTE: we store these somewhat redundantly as a significant optimization
        //  this avoids having to iterate through the list for the most common use cases
        //  that is, only when we need to perform liquidity checks
        //  and not whenever we want to check if an account is in a particular market
        marketToJoin.accountMembership[borrower] = true;
        accountAssets[borrower].push(mmToken);

        emit MarketEntered(mmToken, borrower);

        return Error.NO_ERROR;
    }

    /**
     * @notice Removes asset from sender's account liquidity calculation
     * @dev Sender must not have an outstanding borrow balance in the asset,
     *  or be providing necessary collateral for an outstanding borrow.
     * @param mmTokenAddress The address of the asset to be removed
     * @return Whether or not the account successfully exited the market
     */
    function exitMarket(address mmTokenAddress) external returns (uint) {
        MmToken mmToken = MmToken(mmTokenAddress);
        /* Get sender tokensHeld and amountOwed underlying from the mmToken */
        (uint oErr, uint tokensHeld, uint amountOwed, ) = mmToken.getAccountSnapshot(msg.sender);
        require(oErr == 0, "exitMarket: getAccountSnapshot failed"); // semi-opaque error code

        /* Fail if the sender has a borrow balance */
        if (amountOwed != 0) {
            return fail(Error.NONZERO_BORROW_BALANCE, FailureInfo.EXIT_MARKET_BALANCE_OWED);
        }

        /* Fail if the sender is not permitted to redeem all of their tokens */
        uint allowed = redeemAllowedInternal(mmTokenAddress, msg.sender, tokensHeld);
        if (allowed != 0) {
            return failOpaque(Error.REJECTION, FailureInfo.EXIT_MARKET_REJECTION, allowed);
        }

        Market storage marketToExit = markets[address(mmToken)];

        /* Return true if the sender is not already ???in??? the market */
        if (!marketToExit.accountMembership[msg.sender]) {
            return uint(Error.NO_ERROR);
        }

        /* Set mmToken account membership to false */
        delete marketToExit.accountMembership[msg.sender];

        /* Delete mmToken from the account???s list of assets */
        // load into memory for faster iteration
        MmToken[] memory userAssetList = accountAssets[msg.sender];
        uint len = userAssetList.length;
        uint assetIndex = len;
        for (uint i = 0; i < len; i++) {
            if (userAssetList[i] == mmToken) {
                assetIndex = i;
                break;
            }
        }

        // We *must* have found the asset in the list or our redundant data structure is broken
        assert(assetIndex < len);

        // copy last item in list to location of item to be removed, reduce length by 1
        MmToken[] storage storedList = accountAssets[msg.sender];
        storedList[assetIndex] = storedList[storedList.length - 1];
        storedList.length--;

        emit MarketExited(mmToken, msg.sender);

        return uint(Error.NO_ERROR);
    }

    /*** Policy Hooks ***/

    /**
     * @notice Checks if the account should be allowed to mint tokens in the given market
     * @param mmToken The market to verify the mint against
     * @param minter The account which would get the minted tokens
     * @param mintAmount The amount of underlying being supplied to the market in exchange for tokens
     * @return 0 if the mint is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function mintAllowed(address mmToken, address minter, uint mintAmount) external returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!mintGuardianPaused[mmToken], "mint is paused");

        // Shh - currently unused
        mintAmount;

        if (!markets[mmToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        // Keep the flywheel moving
        updateAndDistributeSupplierRewardsForToken(mmToken, minter);
        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates mint and reverts on rejection. May emit logs.
     * @param mmToken Asset being minted
     * @param minter The address minting the tokens
     * @param actualMintAmount The amount of the underlying asset being minted
     * @param mintTokens The number of tokens being minted
     */
    function mintVerify(address mmToken, address minter, uint actualMintAmount, uint mintTokens) external {
        // Shh - currently unused
        mmToken;
        minter;
        actualMintAmount;
        mintTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to redeem tokens in the given market
     * @param mmToken The market to verify the redeem against
     * @param redeemer The account which would redeem the tokens
     * @param redeemTokens The number of mmTokens to exchange for the underlying asset in the market
     * @return 0 if the redeem is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function redeemAllowed(address mmToken, address redeemer, uint redeemTokens) external returns (uint) {
        uint allowed = redeemAllowedInternal(mmToken, redeemer, redeemTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updateAndDistributeSupplierRewardsForToken(mmToken, redeemer);

        return uint(Error.NO_ERROR);
    }

    function redeemAllowedInternal(address mmToken, address redeemer, uint redeemTokens) internal view returns (uint) {
        if (!markets[mmToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        /* If the redeemer is not 'in' the market, then we can bypass the liquidity check */
        if (!markets[mmToken].accountMembership[redeemer]) {
            return uint(Error.NO_ERROR);
        }

        /* Otherwise, perform a hypothetical liquidity check to guard against shortfall */
        (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(redeemer, MmToken(mmToken), redeemTokens, 0);
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall > 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates redeem and reverts on rejection. May emit logs.
     * @param mmToken Asset being redeemed
     * @param redeemer The address redeeming the tokens
     * @param redeemAmount The amount of the underlying asset being redeemed
     * @param redeemTokens The number of tokens being redeemed
     */
    function redeemVerify(address mmToken, address redeemer, uint redeemAmount, uint redeemTokens) external {
        // Shh - currently unused
        mmToken;
        redeemer;

        // Require tokens is zero or amount is also zero
        if (redeemTokens == 0 && redeemAmount > 0) {
            revert("redeemTokens zero");
        }
    }

    /**
     * @notice Checks if the account should be allowed to borrow the underlying asset of the given market
     * @param mmToken The market to verify the borrow against
     * @param borrower The account which would borrow the asset
     * @param borrowAmount The amount of underlying the account would borrow
     * @return 0 if the borrow is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function borrowAllowed(address mmToken, address borrower, uint borrowAmount) external returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!borrowGuardianPaused[mmToken], "borrow is paused");

        if (!markets[mmToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (!markets[mmToken].accountMembership[borrower]) {
            // only mmTokens may call borrowAllowed if borrower not in market
            require(msg.sender == mmToken, "sender must be mmToken");

            // attempt to add borrower to the market
            Error err = addToMarketInternal(MmToken(msg.sender), borrower);
            if (err != Error.NO_ERROR) {
                return uint(err);
            }

            // it should be impossible to break the important invariant
            assert(markets[mmToken].accountMembership[borrower]);
        }

        if (oracle.getUnderlyingPrice(MmToken(mmToken)) == 0) {
            return uint(Error.PRICE_ERROR);
        }


        uint borrowCap = borrowCaps[mmToken];
        // Borrow cap of 0 corresponds to unlimited borrowing
        if (borrowCap != 0) {
            uint totalBorrows = MmToken(mmToken).totalBorrows();
            uint nextTotalBorrows = add_(totalBorrows, borrowAmount);
            require(nextTotalBorrows < borrowCap, "market borrow cap reached");
        }

        (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(borrower, MmToken(mmToken), 0, borrowAmount);
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall > 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        // Keep the flywheel moving
        Exp memory borrowIndex = Exp({mantissa: MmToken(mmToken).borrowIndex()});
        updateAndDistributeBorrowerRewardsForToken(mmToken, borrower, borrowIndex);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates borrow and reverts on rejection. May emit logs.
     * @param mmToken Asset whose underlying is being borrowed
     * @param borrower The address borrowing the underlying
     * @param borrowAmount The amount of the underlying asset requested to borrow
     */
    function borrowVerify(address mmToken, address borrower, uint borrowAmount) external {
        // Shh - currently unused
        mmToken;
        borrower;
        borrowAmount;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to repay a borrow in the given market
     * @param mmToken The market to verify the repay against
     * @param payer The account which would repay the asset
     * @param borrower The account which would borrowed the asset
     * @param repayAmount The amount of the underlying asset the account would repay
     * @return 0 if the repay is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function repayBorrowAllowed(
        address mmToken,
        address payer,
        address borrower,
        uint repayAmount) external returns (uint) {
        // Shh - currently unused
        payer;
        borrower;
        repayAmount;

        if (!markets[mmToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        // Keep the flywheel moving
        Exp memory borrowIndex = Exp({mantissa: MmToken(mmToken).borrowIndex()});
        updateAndDistributeBorrowerRewardsForToken(mmToken, borrower, borrowIndex);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates repayBorrow and reverts on rejection. May emit logs.
     * @param mmToken Asset being repaid
     * @param payer The address repaying the borrow
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function repayBorrowVerify(
        address mmToken,
        address payer,
        address borrower,
        uint actualRepayAmount,
        uint borrowerIndex) external {
        // Shh - currently unused
        mmToken;
        payer;
        borrower;
        actualRepayAmount;
        borrowerIndex;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the liquidation should be allowed to occur
     * @param mmTokenBorrowed Asset which was borrowed by the borrower
     * @param mmTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param repayAmount The amount of underlying being repaid
     */
    function liquidateBorrowAllowed(
        address mmTokenBorrowed,
        address mmTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount) external returns (uint) {
        // Shh - currently unused
        liquidator;

        if (!markets[mmTokenBorrowed].isListed || !markets[mmTokenCollateral].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        /* The borrower must have shortfall in order to be liquidatable */
        (Error err, , uint shortfall) = getAccountLiquidityInternal(borrower);
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall == 0) {
            return uint(Error.INSUFFICIENT_SHORTFALL);
        }

        /* The liquidator may not repay more than what is allowed by the closeFactor */
        uint borrowBalance = MmToken(mmTokenBorrowed).borrowBalanceStored(borrower);
        uint maxClose = mul_ScalarTruncate(Exp({mantissa: closeFactorMantissa}), borrowBalance);
        if (repayAmount > maxClose) {
            return uint(Error.TOO_MUCH_REPAY);
        }

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates liquidateBorrow and reverts on rejection. May emit logs.
     * @param mmTokenBorrowed Asset which was borrowed by the borrower
     * @param mmTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function liquidateBorrowVerify(
        address mmTokenBorrowed,
        address mmTokenCollateral,
        address liquidator,
        address borrower,
        uint actualRepayAmount,
        uint seizeTokens) external {
        // Shh - currently unused
        mmTokenBorrowed;
        mmTokenCollateral;
        liquidator;
        borrower;
        actualRepayAmount;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the seizing of assets should be allowed to occur
     * @param mmTokenCollateral Asset which was used as collateral and will be seized
     * @param mmTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeAllowed(
        address mmTokenCollateral,
        address mmTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) external returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!seizeGuardianPaused, "seize is paused");

        // Shh - currently unused
        seizeTokens;

        if (!markets[mmTokenCollateral].isListed || !markets[mmTokenBorrowed].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (MmToken(mmTokenCollateral).comptroller() != MmToken(mmTokenBorrowed).comptroller()) {
            return uint(Error.COMPTROLLER_MISMATCH);
        }

        // Keep the flywheel moving
        updateAndDistributeSupplierRewardsForToken(mmTokenCollateral, borrower);
        updateAndDistributeSupplierRewardsForToken(mmTokenCollateral, liquidator);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates seize and reverts on rejection. May emit logs.
     * @param mmTokenCollateral Asset which was used as collateral and will be seized
     * @param mmTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeVerify(
        address mmTokenCollateral,
        address mmTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) external {
        // Shh - currently unused
        mmTokenCollateral;
        mmTokenBorrowed;
        liquidator;
        borrower;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to transfer tokens in the given market
     * @param mmToken The market to verify the transfer against
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of mmTokens to transfer
     * @return 0 if the transfer is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function transferAllowed(address mmToken, address src, address dst, uint transferTokens) external returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!transferGuardianPaused, "transfer is paused");

        // Currently the only consideration is whether or not
        //  the src is allowed to redeem this many tokens
        uint allowed = redeemAllowedInternal(mmToken, src, transferTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updateAndDistributeSupplierRewardsForToken(mmToken, src);
        updateAndDistributeSupplierRewardsForToken(mmToken, dst);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates transfer and reverts on rejection. May emit logs.
     * @param mmToken Asset being transferred
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of mmTokens to transfer
     */
    function transferVerify(address mmToken, address src, address dst, uint transferTokens) external {
        // Shh - currently unused
        mmToken;
        src;
        dst;
        transferTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /*** Liquidity/Liquidation Calculations ***/

    /**
     * @dev Local vars for avoiding stack-depth limits in calculating account liquidity.
     *  Note that `mmTokenBalance` is the number of mmTokens the account owns in the market,
     *  whereas `borrowBalance` is the amount of underlying that the account has borrowed.
     */
    struct AccountLiquidityLocalVars {
        uint sumCollateral;
        uint sumBorrowPlusEffects;
        uint mmTokenBalance;
        uint borrowBalance;
        uint exchangeRateMantissa;
        uint oraclePriceMantissa;
        Exp collateralFactor;
        Exp exchangeRate;
        Exp oraclePrice;
        Exp tokensToDenom;
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code (semi-opaque),
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidity(address account) public view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, MmToken(0), 0, 0);

        return (uint(err), liquidity, shortfall);
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code,
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidityInternal(address account) internal view returns (Error, uint, uint) {
        return getHypotheticalAccountLiquidityInternal(account, MmToken(0), 0, 0);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param mmTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @return (possible error code (semi-opaque),
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidity(
        address account,
        address mmTokenModify,
        uint redeemTokens,
        uint borrowAmount) public view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, MmToken(mmTokenModify), redeemTokens, borrowAmount);
        return (uint(err), liquidity, shortfall);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param mmTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @dev Note that we calculate the exchangeRateStored for each collateral mmToken using stored data,
     *  without calculating accumulated interest.
     * @return (possible error code,
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidityInternal(
        address account,
        MmToken mmTokenModify,
        uint redeemTokens,
        uint borrowAmount) internal view returns (Error, uint, uint) {

        AccountLiquidityLocalVars memory vars; // Holds all our calculation results
        uint oErr;

        // For each asset the account is in
        MmToken[] memory assets = accountAssets[account];
        for (uint i = 0; i < assets.length; i++) {
            MmToken asset = assets[i];

            // Read the balances and exchange rate from the mmToken
            (oErr, vars.mmTokenBalance, vars.borrowBalance, vars.exchangeRateMantissa) = asset.getAccountSnapshot(account);
            if (oErr != 0) { // semi-opaque error code, we assume NO_ERROR == 0 is invariant between upgrades
                return (Error.SNAPSHOT_ERROR, 0, 0);
            }
            vars.collateralFactor = Exp({mantissa: markets[address(asset)].collateralFactorMantissa});
            vars.exchangeRate = Exp({mantissa: vars.exchangeRateMantissa});

            // Get the normalized price of the asset
            vars.oraclePriceMantissa = oracle.getUnderlyingPrice(asset);
            if (vars.oraclePriceMantissa == 0) {
                return (Error.PRICE_ERROR, 0, 0);
            }
            vars.oraclePrice = Exp({mantissa: vars.oraclePriceMantissa});

            // Pre-compute a conversion factor from tokens -> usd (normalized price value)
            vars.tokensToDenom = mul_(mul_(vars.collateralFactor, vars.exchangeRate), vars.oraclePrice);

            // sumCollateral += tokensToDenom * mmTokenBalance
            vars.sumCollateral = mul_ScalarTruncateAddUInt(vars.tokensToDenom, vars.mmTokenBalance, vars.sumCollateral);

            // sumBorrowPlusEffects += oraclePrice * borrowBalance
            vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.oraclePrice, vars.borrowBalance, vars.sumBorrowPlusEffects);

            // Calculate effects of interacting with mmTokenModify
            if (asset == mmTokenModify) {
                // redeem effect
                // sumBorrowPlusEffects += tokensToDenom * redeemTokens
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.tokensToDenom, redeemTokens, vars.sumBorrowPlusEffects);

                // borrow effect
                // sumBorrowPlusEffects += oraclePrice * borrowAmount
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.oraclePrice, borrowAmount, vars.sumBorrowPlusEffects);
            }
        }

        // These are safe, as the underflow condition is checked first
        if (vars.sumCollateral > vars.sumBorrowPlusEffects) {
            return (Error.NO_ERROR, vars.sumCollateral - vars.sumBorrowPlusEffects, 0);
        } else {
            return (Error.NO_ERROR, 0, vars.sumBorrowPlusEffects - vars.sumCollateral);
        }
    }

    /**
     * @notice Calculate number of tokens of collateral asset to seize given an underlying amount
     * @dev Used in liquidation (called in mmToken.liquidateBorrowFresh)
     * @param mmTokenBorrowed The address of the borrowed mmToken
     * @param mmTokenCollateral The address of the collateral mmToken
     * @param actualRepayAmount The amount of mmTokenBorrowed underlying to convert into mmTokenCollateral tokens
     * @return (errorCode, number of mmTokenCollateral tokens to be seized in a liquidation)
     */
    function liquidateCalculateSeizeTokens(address mmTokenBorrowed, address mmTokenCollateral, uint actualRepayAmount) external view returns (uint, uint) {
        /* Read oracle prices for borrowed and collateral markets */
        uint priceBorrowedMantissa = oracle.getUnderlyingPrice(MmToken(mmTokenBorrowed));
        uint priceCollateralMantissa = oracle.getUnderlyingPrice(MmToken(mmTokenCollateral));
        if (priceBorrowedMantissa == 0 || priceCollateralMantissa == 0) {
            return (uint(Error.PRICE_ERROR), 0);
        }

        /*
         * Get the exchange rate and calculate the number of collateral tokens to seize:
         *  seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
         *  seizeTokens = seizeAmount / exchangeRate
         *   = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
         */
        uint exchangeRateMantissa = MmToken(mmTokenCollateral).exchangeRateStored(); // Note: reverts on error
        uint seizeTokens;
        Exp memory numerator;
        Exp memory denominator;
        Exp memory ratio;

        numerator = mul_(Exp({mantissa: liquidationIncentiveMantissa}), Exp({mantissa: priceBorrowedMantissa}));
        denominator = mul_(Exp({mantissa: priceCollateralMantissa}), Exp({mantissa: exchangeRateMantissa}));
        ratio = div_(numerator, denominator);

        seizeTokens = mul_ScalarTruncate(ratio, actualRepayAmount);

        return (uint(Error.NO_ERROR), seizeTokens);
    }

    /*** Admin Functions ***/

    /**
      * @notice Sets a new price oracle for the comptroller
      * @dev Admin function to set a new price oracle
      * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
      */
    function _setPriceOracle(PriceOracle newOracle) public returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PRICE_ORACLE_OWNER_CHECK);
        }

        // Track the old oracle for the comptroller
        PriceOracle oldOracle = oracle;

        // Set comptroller's oracle to newOracle
        oracle = newOracle;

        // Emit NewPriceOracle(oldOracle, newOracle)
        emit NewPriceOracle(oldOracle, newOracle);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets the closeFactor used when liquidating borrows
      * @dev Admin function to set closeFactor
      * @param newCloseFactorMantissa New close factor, scaled by 1e18
      * @return uint 0=success, otherwise a failure
      */
    function _setCloseFactor(uint newCloseFactorMantissa) external returns (uint) {
        // Check caller is admin
    	require(msg.sender == admin, "only admin can set close factor");

        uint oldCloseFactorMantissa = closeFactorMantissa;
        closeFactorMantissa = newCloseFactorMantissa;
        emit NewCloseFactor(oldCloseFactorMantissa, closeFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets the collateralFactor for a market
      * @dev Admin function to set per-market collateralFactor
      * @param mmToken The market to set the factor on
      * @param newCollateralFactorMantissa The new collateral factor, scaled by 1e18
      * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
      */
    function _setCollateralFactor(MmToken mmToken, uint newCollateralFactorMantissa) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_COLLATERAL_FACTOR_OWNER_CHECK);
        }

        // Verify market is listed
        Market storage market = markets[address(mmToken)];
        if (!market.isListed) {
            return fail(Error.MARKET_NOT_LISTED, FailureInfo.SET_COLLATERAL_FACTOR_NO_EXISTS);
        }

        Exp memory newCollateralFactorExp = Exp({mantissa: newCollateralFactorMantissa});

        // Check collateral factor <= 0.9
        Exp memory highLimit = Exp({mantissa: collateralFactorMaxMantissa});
        if (lessThanExp(highLimit, newCollateralFactorExp)) {
            return fail(Error.INVALID_COLLATERAL_FACTOR, FailureInfo.SET_COLLATERAL_FACTOR_VALIDATION);
        }

        // If collateral factor != 0, fail if price == 0
        if (newCollateralFactorMantissa != 0 && oracle.getUnderlyingPrice(mmToken) == 0) {
            return fail(Error.PRICE_ERROR, FailureInfo.SET_COLLATERAL_FACTOR_WITHOUT_PRICE);
        }

        // Set market's collateral factor to new collateral factor, remember old value
        uint oldCollateralFactorMantissa = market.collateralFactorMantissa;
        market.collateralFactorMantissa = newCollateralFactorMantissa;

        // Emit event with asset, old collateral factor, and new collateral factor
        emit NewCollateralFactor(mmToken, oldCollateralFactorMantissa, newCollateralFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets liquidationIncentive
      * @dev Admin function to set liquidationIncentive
      * @param newLiquidationIncentiveMantissa New liquidationIncentive scaled by 1e18
      * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
      */
    function _setLiquidationIncentive(uint newLiquidationIncentiveMantissa) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_LIQUIDATION_INCENTIVE_OWNER_CHECK);
        }

        // Save current value for use in log
        uint oldLiquidationIncentiveMantissa = liquidationIncentiveMantissa;

        // Set liquidation incentive to new incentive
        liquidationIncentiveMantissa = newLiquidationIncentiveMantissa;

        // Emit event with old incentive, new incentive
        emit NewLiquidationIncentive(oldLiquidationIncentiveMantissa, newLiquidationIncentiveMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Add the market to the markets mapping and set it as listed
      * @dev Admin function to set isListed and add support for the market
      * @param mmToken The address of the market (token) to list
      * @return uint 0=success, otherwise a failure. (See enum Error for details)
      */
    function _supportMarket(MmToken mmToken) external returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SUPPORT_MARKET_OWNER_CHECK);
        }

        if (markets[address(mmToken)].isListed) {
            return fail(Error.MARKET_ALREADY_LISTED, FailureInfo.SUPPORT_MARKET_EXISTS);
        }

        mmToken.isMmToken(); // Sanity check to make sure its really a MmToken

        // Note that isMimed is not in active use anymore
        markets[address(mmToken)] = Market({isListed: true, isMimed: false, collateralFactorMantissa: 0});

        _addMarketInternal(address(mmToken));

        // Initialize all markets for all reward types
        for (uint8 rewardType = 0; rewardType < maxRewardTokens; rewardType++) {
            _initializeMarket(rewardType, address(mmToken));
        }

        emit MarketListed(mmToken);

        return uint(Error.NO_ERROR);
    }

    function _initializeMarket(uint8 rewardType, address mmToken) internal {
        uint32 blockTimestamp = safe32(getBlockTimestamp(), "block timestamp exceeds 32 bits");

        RewardMarketState storage supplyState = rewardSupplyState[rewardType][mmToken];
        RewardMarketState storage borrowState = rewardBorrowState[rewardType][mmToken];

        /*
         * Update market state indices
         */
        if (supplyState.index == 0) {
            // Initialize supply state index with default value
            supplyState.index = initialIndexConstant;
        }

        if (borrowState.index == 0) {
            // Initialize borrow state index with default value
            borrowState.index = initialIndexConstant;
        }

        /*
         * Update market state block numbers
         */
         supplyState.timestamp = borrowState.timestamp = blockTimestamp;
    }

    function _addMarketInternal(address mmToken) internal {
        for (uint i = 0; i < allMarkets.length; i ++) {
            require(allMarkets[i] != MmToken(mmToken), "market already added");
        }
        allMarkets.push(MmToken(mmToken));
    }


    /**
      * @notice Set the given borrow caps for the given mmToken markets. Borrowing that brings total borrows to or above borrow cap will revert.
      * @dev Admin or borrowCapGuardian function to set the borrow caps. A borrow cap of 0 corresponds to unlimited borrowing.
      * @param mmTokens The addresses of the markets (tokens) to change the borrow caps for
      * @param newBorrowCaps The new borrow cap values in underlying to be set. A value of 0 corresponds to unlimited borrowing.
      */
    function _setMarketBorrowCaps(MmToken[] calldata mmTokens, uint[] calldata newBorrowCaps) external {
    	require(msg.sender == admin || msg.sender == borrowCapGuardian, "only admin or borrow cap guardian can set borrow caps"); 

        uint numMarkets = mmTokens.length;
        uint numBorrowCaps = newBorrowCaps.length;

        require(numMarkets != 0 && numMarkets == numBorrowCaps, "invalid input");

        for(uint i = 0; i < numMarkets; i++) {
            borrowCaps[address(mmTokens[i])] = newBorrowCaps[i];
            emit NewBorrowCap(mmTokens[i], newBorrowCaps[i]);
        }
    }

    /**
     * @notice Admin function to change the Borrow Cap Guardian
     * @param newBorrowCapGuardian The address of the new Borrow Cap Guardian
     */
    function _setBorrowCapGuardian(address newBorrowCapGuardian) external {
        require(msg.sender == admin, "only admin can set borrow cap guardian");

        // Save current value for inclusion in log
        address oldBorrowCapGuardian = borrowCapGuardian;

        // Store borrowCapGuardian with value newBorrowCapGuardian
        borrowCapGuardian = newBorrowCapGuardian;

        // Emit NewBorrowCapGuardian(OldBorrowCapGuardian, NewBorrowCapGuardian)
        emit NewBorrowCapGuardian(oldBorrowCapGuardian, newBorrowCapGuardian);
    }

    /**
     * @notice Admin function to change the Pause Guardian
     * @param newPauseGuardian The address of the new Pause Guardian
     * @return uint 0=success, otherwise a failure. (See enum Error for details)
     */
    function _setPauseGuardian(address newPauseGuardian) public returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PAUSE_GUARDIAN_OWNER_CHECK);
        }

        // Save current value for inclusion in log
        address oldPauseGuardian = pauseGuardian;

        // Store pauseGuardian with value newPauseGuardian
        pauseGuardian = newPauseGuardian;

        // Emit NewPauseGuardian(OldPauseGuardian, NewPauseGuardian)
        emit NewPauseGuardian(oldPauseGuardian, pauseGuardian);

        return uint(Error.NO_ERROR);
    }

    function _setMintPaused(MmToken mmToken, bool state) public returns (bool) {
        require(markets[address(mmToken)].isListed, "cannot pause a market that is not listed");
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        mintGuardianPaused[address(mmToken)] = state;
        emit ActionPaused(mmToken, "Mint", state);
        return state;
    }

    function _setBorrowPaused(MmToken mmToken, bool state) public returns (bool) {
        require(markets[address(mmToken)].isListed, "cannot pause a market that is not listed");
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        borrowGuardianPaused[address(mmToken)] = state;
        emit ActionPaused(mmToken, "Borrow", state);
        return state;
    }

    function _setTransferPaused(bool state) public returns (bool) {
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        transferGuardianPaused = state;
        emit ActionPaused("Transfer", state);
        return state;
    }

    function _setSeizePaused(bool state) public returns (bool) {
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        seizeGuardianPaused = state;
        emit ActionPaused("Seize", state);
        return state;
    }

    function _become(Unitroller unitroller) public {
        require(msg.sender == unitroller.admin(), "only unitroller admin can change brains");
        require(unitroller._acceptImplementation() == 0, "change not authorized");
    }

    /**
     * @notice Checks caller is admin, or this contract is becoming the new implementation
     */
    function adminOrInitializing() internal view returns (bool) {
        return msg.sender == admin || msg.sender == comptrollerImplementation;
    }

    /*** Mimas Distribution ***/

    /**
     * @notice Set MIMAS/CRO speed for a single market
     * @param rewardType  0: MIMAS, 1: CRO, 2: other, ...
     * @param mmToken The market whose MIMAS / CRO speed to update
     * @param supplySpeed New supply-side MIMAS / CRO speed for market
     * @param borrowSpeed New borrow-side MIMAS / CRO speed for market
     */
    function setRewardSpeedInternal(uint8 rewardType, MmToken mmToken, uint supplySpeed, uint borrowSpeed) internal {
        Market storage market = markets[address(mmToken)];
        require(market.isListed, "Mimas market is not listed");

        if (rewardSupplySpeeds[rewardType][address(mmToken)] != supplySpeed) {
            // Supply speed updated so let's update supply state to ensure that
            //  1. Reward accrued properly for the old speed, and
            //  2. Reward accrued at the new speed starts after this block.
            updateRewardSupplyIndex(rewardType, address(mmToken));

            // Update speed and emit event
            rewardSupplySpeeds[rewardType][address(mmToken)] = supplySpeed;
            emit SupplySpeedUpdated(rewardType, mmToken, supplySpeed);
        }

        if (rewardBorrowSpeeds[rewardType][address(mmToken)] != borrowSpeed) {
            // Borrow speed updated so let's update borrow state to ensure that
            //  1. Reward accrued properly for the old speed, and
            //  2. Reward accrued at the new speed starts after this block.
            Exp memory borrowIndex = Exp({mantissa: mmToken.borrowIndex()});
            updateRewardBorrowIndex(rewardType, address(mmToken), borrowIndex);

            // Update speed and emit event
            rewardBorrowSpeeds[rewardType][address(mmToken)] = borrowSpeed;
            emit BorrowSpeedUpdated(rewardType, mmToken, borrowSpeed);
        }
    }

    /**
     * @notice Accrue MIMAS to the market by updating the supply index
     * @param rewardType  0: MIMAS, 1: CRO, 2: other, ...
     * @param mmToken The market whose supply index to update
     */
    function updateRewardSupplyIndex(uint8 rewardType, address mmToken) internal {
        require(rewardType < maxRewardTokens, "rewardType is invalid");
        RewardMarketState storage supplyState = rewardSupplyState[rewardType][mmToken];
        uint supplySpeed = rewardSupplySpeeds[rewardType][mmToken];
        uint32 blockTimestamp = safe32(getBlockTimestamp(), "block timestamp exceeds 32 bits");
        uint deltaTimestamps = sub_(uint(blockTimestamp), uint(supplyState.timestamp));
        if (deltaTimestamps > 0 && supplySpeed > 0) {
            uint supplyTokens = MmToken(mmToken).totalSupply();
            uint mimasAccrued = mul_(deltaTimestamps, supplySpeed);
            Double memory ratio = supplyTokens > 0 ? fraction(mimasAccrued, supplyTokens) : Double({mantissa: 0});
            supplyState.index = safe224(add_(Double({mantissa: supplyState.index}), ratio).mantissa, "new index exceeds 224 bits");
            supplyState.timestamp = blockTimestamp;
        } else if (deltaTimestamps > 0) {
            supplyState.timestamp = blockTimestamp;
        }
    }

    /**
     * @notice Accrue MIMAS to the market by updating the borrow index
     * @param rewardType  0: MIMAS, 1: CRO, 2: other, ...
     * @param mmToken The market whose borrow index to update
     */
    function updateRewardBorrowIndex(uint8 rewardType, address mmToken, Exp memory marketBorrowIndex) internal {
        require(rewardType < maxRewardTokens, "rewardType is invalid");
        RewardMarketState storage borrowState = rewardBorrowState[rewardType][mmToken];
        uint borrowSpeed = rewardBorrowSpeeds[rewardType][mmToken];
        uint32 blockTimestamp = safe32(getBlockTimestamp(), "block timestamp exceeds 32 bits");
        uint deltaTimestamps = sub_(uint(blockTimestamp), uint(borrowState.timestamp));
        if (deltaTimestamps > 0 && borrowSpeed > 0) {
            uint borrowAmount = div_(MmToken(mmToken).totalBorrows(), marketBorrowIndex);
            uint mimasAccrued = mul_(deltaTimestamps, borrowSpeed);
            Double memory ratio = borrowAmount > 0 ? fraction(mimasAccrued, borrowAmount) : Double({mantissa: 0});
            borrowState.index = safe224(add_(Double({mantissa: borrowState.index}), ratio).mantissa, "new index exceeds 224 bits");
            borrowState.timestamp = blockTimestamp;
        } else if (deltaTimestamps > 0) {
            borrowState.timestamp = blockTimestamp;
        }
    }

    /**
     * @notice Refactored function to calc and rewards accounts supplier rewards
     * @param mmToken The market to verify the mint against
     * @param account The acount to whom reward tokens (MIMAS, CRO, others) are rewarded
     */
    function updateAndDistributeSupplierRewardsForToken(address mmToken, address account) internal {
        for (uint8 rewardType = 0; rewardType < maxRewardTokens; rewardType++) {
            updateRewardSupplyIndex(rewardType, mmToken);
            distributeSupplierReward(rewardType, mmToken, account);
        }
    }

    /**
     * @notice Calculate MIMAS/CRO accrued by a supplier and possibly transfer it to them
     * @param rewardType  0: MIMAS, 1: CRO, 2: other, ...
     * @param mmToken The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute MIMAS to
     */
    function distributeSupplierReward(uint8 rewardType, address mmToken, address supplier) internal {
        // TODO: Don't distribute supplier rewards if the user is not in the supplier market.
        // This check should be as gas efficient as possible as distributeSupplierComp is called in many places.
        // - We really don't want to call an external contract as that's quite expensive.

        require(rewardType < maxRewardTokens, "rewardType is invalid");
        RewardMarketState storage supplyState = rewardSupplyState[rewardType][mmToken];
        uint supplyIndex = supplyState.index;
        uint supplierIndex = rewardSupplierIndex[rewardType][mmToken][supplier];

        // Update supplier's index to the current index since we are distributing accrued rewards
        rewardSupplierIndex[rewardType][mmToken][supplier] = supplyIndex;

        if (supplierIndex == 0 && supplyIndex >= initialIndexConstant) {
            // Covers the case where users supplied tokens before the market's supply state index was set.
            // Rewards the user with rewards accrued from the start of when supplier rewards were first
            // set for the market.
            supplierIndex = initialIndexConstant;
        }

        // Calculate change in the cumulative sum of the rewards per mmToken accrued
        Double memory deltaIndex = Double({mantissa: sub_(supplyIndex, supplierIndex)});

        uint supplierTokens = MmToken(mmToken).balanceOf(supplier);

        // Calculate rewards accrued: mmTokenAmount * accruedPerMmToken
        uint supplierDelta = mul_(supplierTokens, deltaIndex);

        uint supplierAccrued = add_(rewardAccrued[rewardType][supplier], supplierDelta);

        rewardAccrued[rewardType][supplier] = supplierAccrued;
        emit DistributedSupplierReward(rewardType, MmToken(mmToken), supplier, supplierDelta, supplyIndex);
    }

   /**
     * @notice Refactored function to calc and rewards accounts supplier rewards
     * @param mmToken The market to verify the mint against
     * @param borrower Borrower to be rewarded
     */
    function updateAndDistributeBorrowerRewardsForToken(address mmToken, address borrower, Exp memory marketBorrowIndex) internal {
        for (uint8 rewardType = 0; rewardType < maxRewardTokens; rewardType++) {
            updateRewardBorrowIndex(rewardType, mmToken, marketBorrowIndex);
            distributeBorrowerReward(rewardType, mmToken, borrower, marketBorrowIndex);
        }
    }

    /**
     * @notice Calculate MIMAS accrued by a borrower and possibly transfer it to them
     * @dev Borrowers will not begin to accrue until after the first interaction with the protocol.
     * @param rewardType  0: MIMAS, 1: CRO, 2: other, ...
     * @param mmToken The market in which the borrower is interacting
     * @param borrower The address of the borrower to distribute MIMAS to
     */
    function distributeBorrowerReward(uint8 rewardType, address mmToken, address borrower, Exp memory marketBorrowIndex) internal {
        // TODO: Don't distribute supplier rewards if the user is not in the borrower market.
        // This check should be as gas efficient as possible as distributeBorrowerReward is called in many places.
        // - We really don't want to call an external contract as that's quite expensive.

        require(rewardType < maxRewardTokens, "rewardType is invalid");
        RewardMarketState storage borrowState = rewardBorrowState[rewardType][mmToken];
        uint borrowIndex = borrowState.index;
        uint borrowerIndex = rewardBorrowerIndex[rewardType][mmToken][borrower];

        // Update borrowers's index to the current index since we are distributing accrued rewards.
        rewardBorrowerIndex[rewardType][mmToken][borrower] = borrowIndex;

        if (borrowerIndex == 0 && borrowIndex >= initialIndexConstant) {
            // Covers the case where users borrowed tokens before the market's borrow state index was set.
            // Rewards the user with rewards accrued from the start of when borrower rewards were first
            // set for the market.
            borrowerIndex = initialIndexConstant;
        }

        // Calculate change in the cumulative sum of the COMP per borrowed unit accrued
        Double memory deltaIndex = Double({mantissa: sub_(borrowIndex, borrowerIndex)});

        uint borrowerAmount = div_(MmToken(mmToken).borrowBalanceStored(borrower), marketBorrowIndex);

        // Calculate rewards accrued: mmTokenAmount * accruedPerBorrowedUnit
        uint borrowerDelta = mul_(borrowerAmount, deltaIndex);

        uint borrowerAccrued = add_(rewardAccrued[rewardType][borrower], borrowerDelta);
        rewardAccrued[rewardType][borrower] = borrowerAccrued;

        emit DistributedBorrowerReward(rewardType, MmToken(mmToken), borrower, borrowerDelta, borrowIndex);
    }

    /**
     * @notice Claim all the MIMAS/CRO/other accrued by holder in all markets
     * @param holder The address to claim MIMAS for
     */
    function claimReward(uint8 rewardType, address payable holder) public {
        return claimReward(rewardType,holder, allMarkets);
    }

    /**
     * @notice Claim all the mimas accrued by holder in the specified markets
     * @param holder The address to claim MIMAS/CRO/other for
     * @param mmTokens The list of markets to claim MIMAS in
     */
    function claimReward(uint8 rewardType, address payable holder, MmToken[] memory mmTokens) public {
        address payable [] memory holders = new address payable[](1);
        holders[0] = holder;
        claimReward(rewardType, holders, mmTokens, true, true);
    }

    /**
     * @notice Claim all MIMAS or CRO accrued by the holders
     * @param rewardType  0: MIMAS, 1: CRO, 2: other, ...
     * @param holders The addresses to claim CRO for
     * @param mmTokens The list of markets to claim CRO in
     * @param borrowers Whether or not to claim CRO earned by borrowing
     * @param suppliers Whether or not to claim CRO earned by supplying
     */
    function claimReward(uint8 rewardType, address payable[] memory holders, MmToken[] memory mmTokens, bool borrowers, bool suppliers) public payable {
        require(rewardType < maxRewardTokens, "rewardType is invalid");
        for (uint i = 0; i < mmTokens.length; i++) {
            MmToken mmToken = mmTokens[i];
            require(markets[address(mmToken)].isListed, "market must be listed");
            if (borrowers == true) {
                Exp memory borrowIndex = Exp({mantissa: mmToken.borrowIndex()});
                updateRewardBorrowIndex(rewardType,address(mmToken), borrowIndex);
                for (uint j = 0; j < holders.length; j++) {
                    distributeBorrowerReward(rewardType,address(mmToken), holders[j], borrowIndex);
                    rewardAccrued[rewardType][holders[j]] = grantRewardInternal(rewardType, holders[j], rewardAccrued[rewardType][holders[j]]);
                }
            }
            if (suppliers == true) {
                updateRewardSupplyIndex(rewardType,address(mmToken));
                for (uint j = 0; j < holders.length; j++) {
                    distributeSupplierReward(rewardType,address(mmToken), holders[j]);
                    rewardAccrued[rewardType][holders[j]] = grantRewardInternal(rewardType, holders[j], rewardAccrued[rewardType][holders[j]]);
                }
            }
        }
    }

    /**
     * @notice Transfer MIMAS/CRO to the user
     * @dev Note: If there is not enough MIMAS/CRO/other, we do not perform the transfer all.
     * @param user The address of the user to transfer CRO to
     * @param amount The amount of CRO to (possibly) transfer
     * @return The amount of CRO which was NOT transferred to the user
     */
    function grantRewardInternal(uint8 rewardType, address payable user, uint amount) internal returns (uint) {
        require (rewardType < maxRewardTokens, "rewardType is invalid");
        if (rewardType == nativeTokenRewardType) {
            // Native token rewards.
            uint nativeRemaining = address(this).balance;
            if (amount > 0 && amount <= nativeRemaining) {
                user.transfer(amount);
                return 0;
            }
        } else if (rewardTokenAddress[rewardType] != address(0)){
            // Other ERC20 reward tokens, including the protocol token (MIMAS).
            //
            // If the reward token is not set, then don't grant rewards, but it would
            // still keep accruing.
            EIP20Interface erc20 = EIP20Interface(rewardTokenAddress[rewardType]);
            uint erc20Remaining = erc20.balanceOf(address(this));
            if (amount > 0 && amount <= erc20Remaining) {
                erc20.transfer(user, amount);
                return 0;
            }
        }
        return amount;
    }

    /*** Mimas Distribution Admin ***/

    /**
     * @notice Transfer MIMAS to the recipient
     * @dev Note: If there is not enough MIMAS, we do not perform the transfer all.
     * @param recipient The address of the recipient to transfer MIMAS to
     * @param amount The amount of MIMAS to (possibly) transfer
     */
    function _grantMimas(address payable recipient, uint amount) public {
        require(adminOrInitializing(), "only admin can grant mimas");
        uint amountLeft = grantRewardInternal(protocolTokenRewardType, recipient, amount);
        require(amountLeft == 0, "insufficient mimas for grant");
        emit MimasGranted(recipient, amount);
    }

    /**
     * @notice Set reward speed for a single market
     * @param rewardType 0 = MIMAS, 1 = CRO, 2: other, ...
     * @param mmToken The market whose reward speed to update
     * @param supplySpeed New supply-side reward speed for the corresponding market.
     * @param borrowSpeed New borrow-side reward speed for the corresponding market.
     */
    function _setRewardSpeed(uint8 rewardType, MmToken mmToken, uint supplySpeed, uint borrowSpeed) public {
        require(rewardType < maxRewardTokens, "rewardType is invalid");
        require(adminOrInitializing(), "only admin can set reward speed");
        setRewardSpeedInternal(rewardType, mmToken, supplySpeed, borrowSpeed);
    }

    /**
     * @notice Return all of the markets
     * @dev The automatic getter may be used to access an individual market.
     * @return The list of market addresses
     */
    function getAllMarkets() public view returns (MmToken[] memory) {
        return allMarkets;
    }

    function getBlockTimestamp() public view returns (uint) {
        return block.timestamp;
    }

    /**
     * @notice Set the ERC20 reward tokens in addition to the native token (CRO).
     */
    function setRewardTokenAddress(uint8 rewardType, address tokenAddress) public {
        require(msg.sender == admin);
        require(rewardType < maxRewardTokens, "rewardType is invalid");
        require(rewardType != nativeTokenRewardType, "native token should not be set");

        rewardTokenAddress[rewardType] = tokenAddress;
    }

    /**
     * @notice Returns the address of the protocol token (MIMAS).
     */
    function mimasAddress() public view returns (address) {
        return rewardTokenAddress[protocolTokenRewardType];
    }

    /**
     * @notice payable function needed to receive CRO
     */
    function () payable external {
    }
}
