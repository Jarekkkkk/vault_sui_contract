#[test_only]
#[allow(unused)]
module vault::multi_vault_admin_test{
    use sui::test_scenario::{Self as test, Scenario, next_tx, ctx};
    use sui::clock::{Self, Clock, increment_for_testing as add_time, set_for_testing as set_time};
    use sui::coin::{ Self, Coin, TreasuryCap, CoinMetadata, mint_for_testing as mint, burn_for_testing as burn};
    use sui::balance::{ Self, Balance, create_for_testing as create, destroy_for_testing as destroy};
    use sui::math;
    
    // pkg
    use vault::multi_asset_vault::{Self as mav, MultiAssetVault, AdminCap};
    use vault::mock_strategy::{Self, MockStrategy};
    use vault::utils::timestamp_sec;

    // coins
    use whusdce::coin::COIN as WHUSDCE;
    use whusdte::coin::COIN as WHUSDTE;
    use flask::sbuck::SBUCK;
    use slp::slp::{Self, SLP};

    // test
    use vault::main_test::{
        start_with_3_strategies
    };

    use vault::multi_vault_rebalance_test::{
        test_rebalance,
        start_with_positive_staking_rewards,
    };

    const START_TIME: u64 = 1_000_000_000;
    const DEFAULT_PROFIT_UNLOCK_DURATION_SEC: u64 = 60 * 60; // 1 hour

    fun people():(address, address, address){
        (@0xA, @0xB, @0xC)
    }

    #[test] 
    fun test_claim_fee():(Scenario, Clock){
        let (mut scenario, mut clock) = start_with_positive_staking_rewards();
        let s = &mut scenario;
        let (a, _, _) = people();

        let performance_fee = 100;

        // POST-validation
        next_tx(s,a);{
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            
            // >> USDC
            multi_asset_vault.assert_vault_info<WHUSDCE, SLP>(0, 0, 0, 0, performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());

            // >> USDT
            multi_asset_vault.assert_vault_info<WHUSDTE, SLP>(0, 0, 0, 0, performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());

            test::return_shared(multi_asset_vault);
        };

        next_tx(s,a);{
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let cap = test::take_from_sender<AdminCap<SLP>>(s);

            { // USDC
                let fee = mav::withdraw_performance_fee<WHUSDCE, SLP>(&cap, &mut multi_asset_vault, performance_fee);
                assert!(destroy(fee) == performance_fee, 404);
            };
            { // USDT
                let fee = mav::withdraw_performance_fee<WHUSDTE, SLP>(&cap, &mut multi_asset_vault, performance_fee);
                assert!(destroy(fee) == performance_fee, 404);
            };

            test::return_to_sender(s, cap);
            test::return_shared(multi_asset_vault);
        };

        // PAST-validation
        next_tx(s,a);{
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            
            // >> USDC
            multi_asset_vault.assert_vault_info<WHUSDCE, SLP>(0, 0, 0, 0, 0, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            // >> USDT
            multi_asset_vault.assert_vault_info<WHUSDTE, SLP>(0, 0, 0, 0, 0, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());

            test::return_shared(multi_asset_vault);
        };

        (scenario, clock)
    }

    #[test] 
    fun test_remove_strategy_without_any_external_actions():(Scenario, Clock){
        let (mut scenario, mut clock) = start_with_3_strategies();
        let s = &mut scenario;
        let (a, _, _) = people();

        next_tx(s,a);{
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let admin_cap = test::take_from_sender<AdminCap<SLP>>(s);
            let mut usdc_strategy = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let usdc_strategy_1 = test::take_shared<MockStrategy<WHUSDCE>>(s);

            let usdc_strategy_id = usdc_strategy.vault_access_id();
            let usdc_strategy_1_id = usdc_strategy_1.vault_access_id();

            let ticket = mock_strategy::remove_strategy_from_vault(&admin_cap, &mut usdc_strategy, &mut multi_asset_vault, vector[usdc_strategy_1_id], vector[10000], &clock, ctx(s));
            multi_asset_vault.remove_strategy(&admin_cap, ticket);

            let exist_in_strategies = multi_asset_vault.strategies().contains(&usdc_strategy_id);
            let exist_in_withdraw_priority = multi_asset_vault.strategy_withdraw_priority_order().contains(&usdc_strategy_id);

            assert!(exist_in_strategies == false, 404);
            assert!(exist_in_withdraw_priority == false, 404);

            test::return_shared(usdc_strategy);
            test::return_shared(usdc_strategy_1);
            test::return_shared(multi_asset_vault);
            test::return_to_sender(s, admin_cap);
        };

        (scenario, clock)
    }

    #[test, expected_failure(abort_code = vault::multi_asset_vault::ERR_INVALID_WEIGHTS)]
    fun test_remove_strategy_with_invalid_weights():(Scenario, Clock){
        let (mut scenario, mut clock) = start_with_3_strategies();
        let s = &mut scenario;
        let (a, _, _) = people();

        next_tx(s,a);{
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let admin_cap = test::take_from_sender<AdminCap<SLP>>(s);
            let mut usdc_strategy = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let usdc_strategy_1 = test::take_shared<MockStrategy<WHUSDCE>>(s);

            let usdc_strategy_id = usdc_strategy.vault_access_id();
            let usdc_strategy_1_id = usdc_strategy_1.vault_access_id();

            let ticket = mock_strategy::remove_strategy_from_vault(&admin_cap, &mut usdc_strategy, &mut multi_asset_vault, vector[usdc_strategy_1_id], vector[1000], &clock, ctx(s));
            multi_asset_vault.remove_strategy(&admin_cap, ticket);

            let exist_in_strategies = multi_asset_vault.strategies().contains(&usdc_strategy_id);
            let exist_in_withdraw_priority = multi_asset_vault.strategy_withdraw_priority_order().contains(&usdc_strategy_id);

            assert!(exist_in_strategies == false, 404);
            assert!(exist_in_withdraw_priority == false, 404);

            test::return_shared(usdc_strategy);
            test::return_shared(usdc_strategy_1);
            test::return_shared(multi_asset_vault);
            test::return_to_sender(s, admin_cap);
        };

        (scenario, clock)
    }

    #[test, expected_failure(abort_code = vault::multi_asset_vault::ERR_WEIGHT_BPS_NOT_FULLY_ASSIGNED)]
    fun test_remove_strategy_without_any_weight_bps_assigned():(Scenario, Clock){
        let (mut scenario, mut clock) = start_with_3_strategies();
        let s = &mut scenario;
        let (a, _, _) = people();

        next_tx(s,a);{
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let admin_cap = test::take_from_sender<AdminCap<SLP>>(s);
            let mut usdc_strategy = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let usdc_strategy_id = usdc_strategy.vault_access_id();

            let ticket = mock_strategy::remove_strategy_from_vault(&admin_cap, &mut usdc_strategy, &mut multi_asset_vault, vector[], vector[], &clock, ctx(s));
            multi_asset_vault.remove_strategy(&admin_cap, ticket);

            let exist_in_strategies = multi_asset_vault.strategies().contains(&usdc_strategy_id);
            let exist_in_withdraw_priority = multi_asset_vault.strategy_withdraw_priority_order().contains(&usdc_strategy_id);

            assert!(exist_in_strategies == false, 404);
            assert!(exist_in_withdraw_priority == false, 404);

            test::return_shared(usdc_strategy);
            test::return_shared(multi_asset_vault);
            test::return_to_sender(s, admin_cap);
        };

        (scenario, clock)
    }
}
