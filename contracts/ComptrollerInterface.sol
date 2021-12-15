pragma solidity 0.5.17;

contract ComptrollerInterface {
    /// @notice Indicator that this is a Comptroller contract (for inspection)
    bool public constant isComptroller = true;

    /*** Assets You Are In ***/

    function enterMarkets(address[] calldata mmTokens) external returns (uint[] memory);
    function exitMarket(address mmToken) external returns (uint);

    /*** Policy Hooks ***/

    function mintAllowed(address mmToken, address minter, uint mintAmount) external returns (uint);
    function mintVerify(address mmToken, address minter, uint mintAmount, uint mintTokens) external;

    function redeemAllowed(address mmToken, address redeemer, uint redeemTokens) external returns (uint);
    function redeemVerify(address mmToken, address redeemer, uint redeemAmount, uint redeemTokens) external;

    function borrowAllowed(address mmToken, address borrower, uint borrowAmount) external returns (uint);
    function borrowVerify(address mmToken, address borrower, uint borrowAmount) external;

    function repayBorrowAllowed(
        address mmToken,
        address payer,
        address borrower,
        uint repayAmount) external returns (uint);
    function repayBorrowVerify(
        address mmToken,
        address payer,
        address borrower,
        uint repayAmount,
        uint borrowerIndex) external;

    function liquidateBorrowAllowed(
        address mmTokenBorrowed,
        address mmTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount) external returns (uint);
    function liquidateBorrowVerify(
        address mmTokenBorrowed,
        address mmTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount,
        uint seizeTokens) external;

    function seizeAllowed(
        address mmTokenCollateral,
        address mmTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) external returns (uint);
    function seizeVerify(
        address mmTokenCollateral,
        address mmTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) external;

    function transferAllowed(address mmToken, address src, address dst, uint transferTokens) external returns (uint);
    function transferVerify(address mmToken, address src, address dst, uint transferTokens) external;

    /*** Liquidity/Liquidation Calculations ***/

    function liquidateCalculateSeizeTokens(
        address mmTokenBorrowed,
        address mmTokenCollateral,
        uint repayAmount) external view returns (uint, uint);
}
