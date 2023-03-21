// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.17;

import "test/helpers/IntegrationTest.sol";

contract TestIntegrationMorphoGetters is IntegrationTest {
    using WadRayMath for uint256;

    function testDomainSeparator() public {
        assertEq(
            morpho.DOMAIN_SEPARATOR(),
            keccak256(
                abi.encode(
                    Constants.EIP712_DOMAIN_TYPEHASH,
                    keccak256(bytes(Constants.EIP712_NAME)),
                    keccak256(bytes(Constants.EIP712_VERSION)),
                    block.chainid,
                    address(morpho)
                )
            )
        );
    }

    function testPool() public {
        assertEq(morpho.pool(), address(pool));
    }

    function testAddressesProvider() public {
        assertEq(morpho.addressesProvider(), address(addressesProvider));
    }

    function testPositionsManager() public {
        assertEq(morpho.positionsManager(), address(positionsManager));
    }

    function testRewardsManager() public {
        assertEq(morpho.rewardsManager(), address(rewardsManager));
    }

    function testIsClaimRewardsPaused() public {
        assertEq(morpho.isClaimRewardsPaused(), false);
    }

    function testEModeCategoryId() public {
        assertEq(morpho.eModeCategoryId(), pool.getUserEMode(address(morpho)));
    }

    function testMarketsCreated() public {
        address[] memory markets = morpho.marketsCreated();

        for (uint256 i; i < markets.length; ++i) {
            assertEq(markets[i], allUnderlyings[i]);
        }
    }

    function testDefaultIterations() public {
        Types.Iterations memory defaultIterations = morpho.defaultIterations();

        assertEq(defaultIterations.repay, DEFAULT_MAX_ITERATIONS);
        assertEq(defaultIterations.withdraw, DEFAULT_MAX_ITERATIONS);
    }

    function testUpdatedPoolIndexes(uint256 blocks, uint256 supplied, uint256 borrowed) public {
        blocks = _boundBlocks(blocks);

        for (uint256 marketIndex; marketIndex < allUnderlyings.length; ++marketIndex) {
            _revert();

            TestMarket storage market = testMarkets[allUnderlyings[marketIndex]];

            supplied = _boundSupply(market, supplied);
            borrowed = _boundBorrow(market, borrowed);

            user.approve(market.underlying, supplied);
            user.supply(market.underlying, supplied);
            if (market.isBorrowable) {
                _borrowWithoutCollateral(
                    address(user), market, supplied, address(user), address(user), DEFAULT_MAX_ITERATIONS
                );
            }

            _forward(blocks);

            Types.Indexes256 memory indexes = morpho.updatedIndexes(market.underlying);

            assertEq(
                indexes.supply.poolIndex,
                pool.getReserveNormalizedIncome(market.underlying),
                "poolSupplyIndex != truePoolSupplyIndex"
            );

            assertEq(
                indexes.borrow.poolIndex,
                pool.getReserveNormalizedVariableDebt(market.underlying),
                "poolBorrowIndex != truePoolBorrowIndex"
            );
        }
    }
}
