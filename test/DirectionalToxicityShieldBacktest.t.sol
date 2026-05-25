// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DirectionalToxicityShieldBacktest} from "../script/DirectionalToxicityShieldBacktest.s.sol";

contract DirectionalToxicityShieldBacktestTest is Test {
    DirectionalToxicityShieldBacktest private backtest;

    function setUp() public {
        backtest = new DirectionalToxicityShieldBacktest();
    }

    function testAdverseTrendBacktestComparesPrizeHookModels() public view {
        DirectionalToxicityShieldBacktest.BacktestResult memory result = backtest.backtestAdverseTrend();

        assertGt(result.shieldFees, result.staticFees, "shield prices adverse trend above static");
        assertGt(result.antiToxicityFees, result.staticFees, "anti-toxicity prices adverse trend above static");
        assertGt(result.detoxOracleFees, result.shieldFees, "oracle arbitrage model should be more aggressive");
        assertLe(result.shieldMaxFee, 3500, "shield stays bounded by max step in this path");
        assertLe(result.shieldFinalPressure, 500, "shield pressure remains capped");
    }

    function testMeanReversionBacktestRewardsCounterFlow() public view {
        DirectionalToxicityShieldBacktest.BacktestResult memory result = backtest.backtestMeanReversion();

        assertLt(result.shieldFees, result.staticFees, "shield discounts counter-pressure flow");
        assertLt(result.antiToxicityFees, result.staticFees, "anti-toxicity discounts rebalancing flow");
        assertGt(result.dynamicAmmFees, result.staticFees, "volatility-only stays high despite reversion");
        assertLe(result.shieldMaxFee, 3500, "shield remains bounded by max step in reversion path");
    }

    function testQuietAfterToxicBacktestShowsDecayAdvantage() public view {
        DirectionalToxicityShieldBacktest.BacktestResult memory result = backtest.backtestQuietAfterToxic();

        assertGt(result.jdsLastFee, result.shieldLastFee, "previous-move model keeps charging after quiet period");
        assertEq(result.shieldLastFee, 3000, "shield returns final quiet quote to base fee");
        assertLt(result.shieldFinalPressure, 150, "shield pressure decays before the final swap");
    }
}
