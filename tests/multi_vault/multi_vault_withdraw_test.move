#[test_only]
#[allow(unused)]
module vault::multi_vault_withdraw_test{
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
    fun test_withdraw_without_rewards():(Scenario, Clock){
        let (mut scenario, clock) = test_rebalance();
        let s = &mut scenario;
        let (a, _, _) = people();

        next_tx(s,a);{
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let admin_cap = test::take_from_sender<AdminCap<SLP>>(s);

            let mut usdc_strategy = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let usdc_strategy_id = usdc_strategy.vault_access_id();
            let mut usdt_strategy = test::take_shared<MockStrategy<WHUSDTE>>(s);
            let usdt_strategy_id = usdt_strategy.vault_access_id();

            // initialize withdrawal ticket
            let redeem_lp_token = create<SLP>(math::pow(10, 9));
            let mut ticket = multi_asset_vault.prepare_withdraw_ticket(redeem_lp_token, ctx(s));
            { // update withdrawal ticket info for respective assets

                // >> USDC
                multi_asset_vault.withdraw<WHUSDCE, SLP>(&mut ticket, &clock);
                // >> USDT
                multi_asset_vault.withdraw<WHUSDTE, SLP>(&mut ticket, &clock);
            };
            { // withdraw all the assets in portion from all strategies

                // >> USDC
                usdc_strategy.withdraw(&mut ticket);
                // >> USDT
                usdt_strategy.withdraw(&mut ticket);
            };
            {
                // >> USDC
                let usdc = multi_asset_vault.redeem_withdraw_ticket<WHUSDCE, SLP>(&mut ticket);
                assert!(destroy(usdc) == math::pow(10, 9), 404);
                // >> USDT
                let usdt = multi_asset_vault.redeem_withdraw_ticket<WHUSDTE, SLP>(&mut ticket);
                assert!(destroy(usdt) == math::pow(10, 9), 404);
            };
            
            multi_asset_vault.settle_withdraw_ticket(ticket);


            let now = timestamp_sec(&clock);
            // validation
            // >> USDC
            multi_asset_vault.assert_vault_info<WHUSDCE, SLP>(0, 0, 0, 0, 0, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDCE, SLP>(usdc_strategy_id, 0, 10000, option::none());
            multi_asset_vault.time_locked_profit<WHUSDCE, SLP>().assert_time_locked_balance_info<WHUSDCE>(0, now, 0, 0, 0, now);
            let scoin_val = 0;
            usdc_strategy.assert_strategy_info(0, 0, 0);
            // >> USDT
            multi_asset_vault.assert_vault_info<WHUSDTE, SLP>(0, 0, 0, 0, 0, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDTE, SLP>(usdt_strategy_id, 0, 10000, option::none());
            multi_asset_vault.time_locked_profit<WHUSDTE, SLP>().assert_time_locked_balance_info<WHUSDTE>(0, now, 0, 0, 0, now);
            usdt_strategy.assert_strategy_info(0, 0, 0);


            test::return_shared(multi_asset_vault);
            test::return_shared(usdc_strategy);
            test::return_shared(usdt_strategy);
            test::return_to_sender(s, admin_cap);
        };

        (scenario, clock)
    }

    #[test] 
    fun test_withdraw_with_positive_rewards():(Scenario, Clock){
        let (mut scenario, mut clock) = start_with_positive_staking_rewards();
        let s = &mut scenario;
        let (a, _, _) = people();

        next_tx(s,a);{
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let admin_cap = test::take_from_sender<AdminCap<SLP>>(s);

            let mut usdc_strategy = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let usdc_strategy_id = usdc_strategy.vault_access_id();
            let mut usdt_strategy = test::take_shared<MockStrategy<WHUSDTE>>(s);
            let usdt_strategy_id = usdt_strategy.vault_access_id();


            // initialize withdrawal ticket
            let redeem_lp_token = create<SLP>(math::pow(10, 9));
            let mut ticket = multi_asset_vault.prepare_withdraw_ticket(redeem_lp_token, ctx(s));
            {
                // >> USDC
                multi_asset_vault.withdraw<WHUSDCE, SLP>(&mut ticket, &clock);
                // >> USDT
                multi_asset_vault.withdraw<WHUSDTE, SLP>(&mut ticket, &clock);
            };
            {
                // >> USDC
                usdc_strategy.withdraw(&mut ticket);
                // >> USDT
                usdt_strategy.withdraw(&mut ticket);
            };
            {
                // >> USDC
                let usdc = multi_asset_vault.redeem_withdraw_ticket<WHUSDCE, SLP>(&mut ticket);
                assert!(destroy(usdc) == math::pow(10, 9) + 900, 404);
                // >> USDT
                let usdt = multi_asset_vault.redeem_withdraw_ticket<WHUSDTE, SLP>(&mut ticket);
                assert!(destroy(usdt) == math::pow(10, 9) + 900, 404);
            };
            
            multi_asset_vault.settle_withdraw_ticket(ticket);


            // validation
            let now = timestamp_sec(&clock);
            let scoin_val = 0;
            let collected_performance_fee = 100;
            // >> USDC
            multi_asset_vault.assert_vault_info<WHUSDCE, SLP>(0, 0, 0, 0, collected_performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDCE, SLP>(usdc_strategy_id, 0, 10000, option::none());
            multi_asset_vault.time_locked_profit<WHUSDCE, SLP>().assert_time_locked_balance_info<WHUSDCE>(0, now, 0, 0, 0, now);
            // >> USDT
            multi_asset_vault.assert_vault_info<WHUSDTE, SLP>(0, 0, 0, 0, collected_performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDTE, SLP>(usdt_strategy_id, 0, 10000, option::none());
            multi_asset_vault.time_locked_profit<WHUSDTE, SLP>().assert_time_locked_balance_info<WHUSDTE>(0, now, 0, 0, 0, now);

            // the rewards happend after rebalance, it will be kept in underlying value
            usdc_strategy.assert_strategy_info(0, 0, 0);


            test::return_shared(multi_asset_vault);
            test::return_shared(usdc_strategy);
            test::return_shared(usdt_strategy);
            test::return_to_sender(s, admin_cap);
        };

        (scenario, clock)
    }

    #[test, expected_failure(abort_code = vault::multi_asset_vault::ERR_WITHDRAW_TICKET_ISSUED)]
    fun test_withdraw_reclaim_withdraw_ticket():(Scenario, Clock){
        let (mut scenario, mut clock) = start_with_positive_staking_rewards();
        let s = &mut scenario;
        let (a, _, _) = people();

        next_tx(s,a);{
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let admin_cap = test::take_from_sender<AdminCap<SLP>>(s);

            let mut usdc_strategy = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let usdc_strategy_id = usdc_strategy.vault_access_id();
            let mut usdt_strategy = test::take_shared<MockStrategy<WHUSDTE>>(s);
            let usdt_strategy_id = usdt_strategy.vault_access_id();


            // initialize withdrawal ticket
            let mut ticket = multi_asset_vault.prepare_withdraw_ticket(create<SLP>(math::pow(10, 9)), ctx(s));
            let mut ticket_2 = multi_asset_vault.prepare_withdraw_ticket(create<SLP>(math::pow(10, 9)), ctx(s));
            { // update withdrawal ticket info for respective assets

                // >> USDC
                multi_asset_vault.withdraw<WHUSDCE, SLP>(&mut ticket, &clock);
                // >> USDT
                multi_asset_vault.withdraw<WHUSDTE, SLP>(&mut ticket, &clock);
            };
            { // withdraw all the assets in portion from all strategies

                // >> USDC
                usdc_strategy.withdraw(&mut ticket);
                // >> USDT
                usdt_strategy.withdraw(&mut ticket);
            };
            {
                // >> USDC
                let usdc = multi_asset_vault.redeem_withdraw_ticket<WHUSDCE, SLP>(&mut ticket);
                destroy(usdc);
                // >> USDT
                let usdt = multi_asset_vault.redeem_withdraw_ticket<WHUSDTE, SLP>(&mut ticket);
                destroy(usdt);
            };
            
            multi_asset_vault.settle_withdraw_ticket(ticket);
            multi_asset_vault.settle_withdraw_ticket(ticket_2);


            test::return_shared(multi_asset_vault);
            test::return_shared(usdc_strategy);
            test::return_shared(usdt_strategy);
            test::return_to_sender(s, admin_cap);
        };

        (scenario, clock)
    }

    #[test, expected_failure(abort_code = vault::multi_asset_vault::ERR_WITHDRAW_TICKET_NOT_SETUP)]
    fun test_withdraw_reentrancy():(Scenario, Clock){
        let (mut scenario, mut clock) = start_with_positive_staking_rewards();
        let s = &mut scenario;
        let (a, _, _) = people();

        next_tx(s,a);{
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let admin_cap = test::take_from_sender<AdminCap<SLP>>(s);

            let mut usdc_strategy = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let usdc_strategy_id = usdc_strategy.vault_access_id();
            let mut usdt_strategy = test::take_shared<MockStrategy<WHUSDTE>>(s);
            let usdt_strategy_id = usdt_strategy.vault_access_id();


            // initialize withdrawal ticket
            let redeem_lp_token = create<SLP>(math::pow(10, 9));
            let mut ticket = multi_asset_vault.prepare_withdraw_ticket(redeem_lp_token, ctx(s));
            { // update withdrawal ticket info for respective assets

                // >> USDC
                multi_asset_vault.withdraw<WHUSDCE, SLP>(&mut ticket, &clock);
                // >> USDT
                multi_asset_vault.withdraw<WHUSDTE, SLP>(&mut ticket, &clock);
            };
            { // withdraw all the assets in portion from all strategies

                // >> USDC
                usdc_strategy.withdraw(&mut ticket);
                // >> USDT
                usdt_strategy.withdraw(&mut ticket);
            };
            {
                // >> USDC
                let usdc = multi_asset_vault.redeem_withdraw_ticket<WHUSDCE, SLP>(&mut ticket);
                destroy(usdc);
                // >> USDT
                let usdt = multi_asset_vault.redeem_withdraw_ticket<WHUSDTE, SLP>(&mut ticket);
                destroy(usdt);
            };
            {
                // >> USDC
                let usdc = multi_asset_vault.redeem_withdraw_ticket<WHUSDCE, SLP>(&mut ticket);
                destroy(usdc);
                // >> USDT
                let usdt = multi_asset_vault.redeem_withdraw_ticket<WHUSDTE, SLP>(&mut ticket);
                destroy(usdt);
            };
            
            multi_asset_vault.settle_withdraw_ticket(ticket);


            test::return_shared(multi_asset_vault);
            test::return_shared(usdc_strategy);
            test::return_shared(usdt_strategy);
            test::return_to_sender(s, admin_cap);
        };

        (scenario, clock)
    }
    
    #[test, expected_failure(abort_code = vault::multi_asset_vault::ERR_WITHDRAW_TICKET_NOT_SETUP)]
    fun test_withdraw_missing_type_to_setup_ticket():(Scenario, Clock){
        let (mut scenario, mut clock) = start_with_positive_staking_rewards();
        let s = &mut scenario;
        let (a, _, _) = people();

        next_tx(s,a);{
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let admin_cap = test::take_from_sender<AdminCap<SLP>>(s);

            let mut usdc_strategy = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let usdc_strategy_id = usdc_strategy.vault_access_id();
            let mut usdt_strategy = test::take_shared<MockStrategy<WHUSDTE>>(s);
            let usdt_strategy_id = usdt_strategy.vault_access_id();


            // initialize withdrawal ticket
            let redeem_lp_token = create<SLP>(math::pow(10, 9));
            let mut ticket = multi_asset_vault.prepare_withdraw_ticket(redeem_lp_token, ctx(s));
            {
                // >> USDC
                multi_asset_vault.withdraw<WHUSDCE, SLP>(&mut ticket, &clock);
                // >> USDT
                // multi_asset_vault.withdraw<WHUSDTE, SLP>(&mut ticket, &clock);
            };
            {
                // >> USDC
                usdc_strategy.withdraw(&mut ticket);
                // >> USDT
                usdt_strategy.withdraw(&mut ticket);
            };
            {
                // >> USDC
                let usdc = multi_asset_vault.redeem_withdraw_ticket<WHUSDCE, SLP>(&mut ticket);
                assert!(destroy(usdc) == math::pow(10, 9) + 900, 404);
                // >> USDT
                let usdt = multi_asset_vault.redeem_withdraw_ticket<WHUSDTE, SLP>(&mut ticket);
                assert!(destroy(usdt) == math::pow(10, 9) + 900, 404);
            };
            
            multi_asset_vault.settle_withdraw_ticket(ticket);


            // validation
            let now = timestamp_sec(&clock);
            let scoin_val = 0;
            let collected_performance_fee = 100;
            // >> USDC
            multi_asset_vault.assert_vault_info<WHUSDCE, SLP>(0, 0, 0, 0, collected_performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDCE, SLP>(usdc_strategy_id, 0, 10000, option::none());
            multi_asset_vault.time_locked_profit<WHUSDCE, SLP>().assert_time_locked_balance_info<WHUSDCE>(0, now, 0, 0, 0, now);
            // >> USDT
            multi_asset_vault.assert_vault_info<WHUSDTE, SLP>(0, 0, 0, 0, collected_performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDTE, SLP>(usdt_strategy_id, 0, 10000, option::none());
            multi_asset_vault.time_locked_profit<WHUSDTE, SLP>().assert_time_locked_balance_info<WHUSDTE>(0, now, 0, 0, 0, now);

            // the rewards happend after rebalance, it will be kept in underlying value
            usdc_strategy.assert_strategy_info(0, 0, 0);


            test::return_shared(multi_asset_vault);
            test::return_shared(usdc_strategy);
            test::return_shared(usdt_strategy);
            test::return_to_sender(s, admin_cap);
        };


        (scenario, clock)
    }

    #[test, expected_failure(abort_code = vault::multi_asset_vault::ERR_STRATEGY_NOT_WITHDRAWN)]
    fun test_withdraw_integrated_strategy_not_withdrawn():(Scenario, Clock){
        let (mut scenario, mut clock) = start_with_positive_staking_rewards();
        let s = &mut scenario;
        let (a, _, _) = people();

        next_tx(s,a);{
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let admin_cap = test::take_from_sender<AdminCap<SLP>>(s);

            let mut usdc_strategy = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let usdc_strategy_id = usdc_strategy.vault_access_id();
            let mut usdt_strategy = test::take_shared<MockStrategy<WHUSDTE>>(s);
            let usdt_strategy_id = usdt_strategy.vault_access_id();


            // initialize withdrawal ticket
            let redeem_lp_token = create<SLP>(math::pow(10, 9));
            let mut ticket = multi_asset_vault.prepare_withdraw_ticket(redeem_lp_token, ctx(s));
            {
                // >> USDC
                multi_asset_vault.withdraw<WHUSDCE, SLP>(&mut ticket, &clock);
            };
            {
                // >> USDT
                usdt_strategy.withdraw(&mut ticket);
            };
            {
                // >> USDC
                let usdc = multi_asset_vault.redeem_withdraw_ticket<WHUSDCE, SLP>(&mut ticket);
                assert!(destroy(usdc) == math::pow(10, 9) + 900, 404);
                // >> USDT
                let usdt = multi_asset_vault.redeem_withdraw_ticket<WHUSDTE, SLP>(&mut ticket);
                assert!(destroy(usdt) == math::pow(10, 9) + 900, 404);
            };
            
            multi_asset_vault.settle_withdraw_ticket(ticket);


            // validation
            let now = timestamp_sec(&clock);
            let scoin_val = 0;
            let collected_performance_fee = 100;
            // >> USDC
            multi_asset_vault.assert_vault_info<WHUSDCE, SLP>(0, 0, 0, 0, collected_performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDCE, SLP>(usdc_strategy_id, 0, 10000, option::none());
            multi_asset_vault.time_locked_profit<WHUSDCE, SLP>().assert_time_locked_balance_info<WHUSDCE>(0, now, 0, 0, 0, now);
            // >> USDT
            multi_asset_vault.assert_vault_info<WHUSDTE, SLP>(0, 0, 0, 0, collected_performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDTE, SLP>(usdt_strategy_id, 0, 10000, option::none());
            multi_asset_vault.time_locked_profit<WHUSDTE, SLP>().assert_time_locked_balance_info<WHUSDTE>(0, now, 0, 0, 0, now);

            // the rewards happend after rebalance, it will be kept in underlying value
            usdc_strategy.assert_strategy_info(0, 0, 0);


            test::return_shared(multi_asset_vault);
            test::return_shared(usdc_strategy);
            test::return_shared(usdt_strategy);
            test::return_to_sender(s, admin_cap);
        };


        (scenario, clock)
    }

    #[test, expected_failure(abort_code = vault::multi_asset_vault::ERR_ASSET_ALREADY_WITHDREW)]
    fun test_withdraw_with_repeated_setup_ticket():(Scenario, Clock){
        let (mut scenario, mut clock) = start_with_positive_staking_rewards();
        let s = &mut scenario;
        let (a, _, _) = people();

        next_tx(s,a);{
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let admin_cap = test::take_from_sender<AdminCap<SLP>>(s);

            let mut usdc_strategy = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let usdc_strategy_id = usdc_strategy.vault_access_id();
            let mut usdt_strategy = test::take_shared<MockStrategy<WHUSDTE>>(s);
            let usdt_strategy_id = usdt_strategy.vault_access_id();


            // initialize withdrawal ticket
            let redeem_lp_token = create<SLP>(math::pow(10, 9));
            let mut ticket = multi_asset_vault.prepare_withdraw_ticket(redeem_lp_token, ctx(s));
            {
                // >> USDC
                multi_asset_vault.withdraw<WHUSDCE, SLP>(&mut ticket, &clock);
                multi_asset_vault.withdraw<WHUSDCE, SLP>(&mut ticket, &clock); // repeated setup
                // >> USDT
                multi_asset_vault.withdraw<WHUSDTE, SLP>(&mut ticket, &clock);
            };
            {
                // >> USDC
                usdc_strategy.withdraw(&mut ticket);
                // >> USDT
                usdt_strategy.withdraw(&mut ticket);
            };
            {
                // >> USDC
                let usdc = multi_asset_vault.redeem_withdraw_ticket<WHUSDCE, SLP>(&mut ticket);
                assert!(destroy(usdc) == math::pow(10, 9) + 900, 404);
                // >> USDT
                let usdt = multi_asset_vault.redeem_withdraw_ticket<WHUSDTE, SLP>(&mut ticket);
                assert!(destroy(usdt) == math::pow(10, 9) + 900, 404);
            };
            
            multi_asset_vault.settle_withdraw_ticket(ticket);


            // validation
            let now = timestamp_sec(&clock);
            let scoin_val = 0;
            let collected_performance_fee = 100;
            // >> USDC
            multi_asset_vault.assert_vault_info<WHUSDCE, SLP>(0, 0, 0, 0, collected_performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDCE, SLP>(usdc_strategy_id, 0, 10000, option::none());
            multi_asset_vault.time_locked_profit<WHUSDCE, SLP>().assert_time_locked_balance_info<WHUSDCE>(0, now, 0, 0, 0, now);
            // >> USDT
            multi_asset_vault.assert_vault_info<WHUSDTE, SLP>(0, 0, 0, 0, collected_performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDTE, SLP>(usdt_strategy_id, 0, 10000, option::none());
            multi_asset_vault.time_locked_profit<WHUSDTE, SLP>().assert_time_locked_balance_info<WHUSDTE>(0, now, 0, 0, 0, now);

            // the rewards happend after rebalance, it will be kept in underlying value
            usdc_strategy.assert_strategy_info(0, 0, 0);


            test::return_shared(multi_asset_vault);
            test::return_shared(usdc_strategy);
            test::return_shared(usdt_strategy);
            test::return_to_sender(s, admin_cap);
        };

        (scenario, clock)
    }

    #[test, expected_failure(abort_code = vault::multi_asset_vault::ERR_ASSET_ALREADY_WITHDREW)]
    fun test_withdraw_with_repeated_integrated_strategy_withdraw():(Scenario, Clock){
        let (mut scenario, mut clock) = start_with_positive_staking_rewards();
        let s = &mut scenario;
        let (a, _, _) = people();

        next_tx(s,a);{
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let admin_cap = test::take_from_sender<AdminCap<SLP>>(s);

            let mut usdc_strategy = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let usdc_strategy_id = usdc_strategy.vault_access_id();
            let mut usdt_strategy = test::take_shared<MockStrategy<WHUSDTE>>(s);
            let usdt_strategy_id = usdt_strategy.vault_access_id();


            // initialize withdrawal ticket
            let redeem_lp_token = create<SLP>(math::pow(10, 9));
            let mut ticket = multi_asset_vault.prepare_withdraw_ticket(redeem_lp_token, ctx(s));
            {
                // >> USDC
                multi_asset_vault.withdraw<WHUSDCE, SLP>(&mut ticket, &clock);
                // >> USDT
                multi_asset_vault.withdraw<WHUSDTE, SLP>(&mut ticket, &clock);
            };
            {
                // >> USDC
                usdc_strategy.withdraw(&mut ticket);
                // >> USDT
                usdt_strategy.withdraw(&mut ticket);
            };
            // ===== Repated Withdraw =====
            {
                // >> USDC
                multi_asset_vault.withdraw<WHUSDCE, SLP>(&mut ticket, &clock);
                // >> USDT
                multi_asset_vault.withdraw<WHUSDTE, SLP>(&mut ticket, &clock);
            };
            {
                // >> USDC
                usdc_strategy.withdraw(&mut ticket);
                // >> USDT
                usdt_strategy.withdraw(&mut ticket);
            };
            {
                // >> USDC
                let usdc = multi_asset_vault.redeem_withdraw_ticket<WHUSDCE, SLP>(&mut ticket);
                assert!(destroy(usdc) == math::pow(10, 9) + 900, 404);
                // >> USDT
                let usdt = multi_asset_vault.redeem_withdraw_ticket<WHUSDTE, SLP>(&mut ticket);
                assert!(destroy(usdt) == math::pow(10, 9) + 900, 404);
            };
            
            multi_asset_vault.settle_withdraw_ticket(ticket);


            // validation
            let now = timestamp_sec(&clock);
            let scoin_val = 0;
            let collected_performance_fee = 100;
            // >> USDC
            multi_asset_vault.assert_vault_info<WHUSDCE, SLP>(0, 0, 0, 0, collected_performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDCE, SLP>(usdc_strategy_id, 0, 10000, option::none());
            multi_asset_vault.time_locked_profit<WHUSDCE, SLP>().assert_time_locked_balance_info<WHUSDCE>(0, now, 0, 0, 0, now);
            // >> USDT
            multi_asset_vault.assert_vault_info<WHUSDTE, SLP>(0, 0, 0, 0, collected_performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDTE, SLP>(usdt_strategy_id, 0, 10000, option::none());
            multi_asset_vault.time_locked_profit<WHUSDTE, SLP>().assert_time_locked_balance_info<WHUSDTE>(0, now, 0, 0, 0, now);

            // the rewards happend after rebalance, it will be kept in underlying value
            usdc_strategy.assert_strategy_info(0, 0, 0);


            test::return_shared(multi_asset_vault);
            test::return_shared(usdc_strategy);
            test::return_shared(usdt_strategy);
            test::return_to_sender(s, admin_cap);
        };

        (scenario, clock)
    }

    #[test] 
    fun test_deposit_after_withdraw_all():(Scenario, Clock){
        let (mut scenario, mut clock) = test_withdraw_with_positive_rewards();
        let s = &mut scenario;
        let (a, _, _) = people();

        let deposit_usdc_value = math::pow(10, 9);
        next_tx(s,a);{
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);

            let expected_yt = multi_asset_vault.get_expected_yt_by_given_deposit<WHUSDCE,SLP>(deposit_usdc_value, &clock);
            let mut ticket = multi_asset_vault.prepare_deposit_ticket(expected_yt);

            { // USDC
                let surplus = multi_asset_vault.deposit_by_asset<WHUSDCE, SLP>(create<WHUSDCE>(deposit_usdc_value), &mut ticket, &clock);
                assert!(destroy(surplus) == 0, 404);
            };
            { // USDT
                let required_deposit = multi_asset_vault.get_required_deposit_by_given_yt<WHUSDTE, SLP>(expected_yt, &clock);
                assert!(required_deposit == deposit_usdc_value, 404);
                let surplus = multi_asset_vault.deposit_by_asset<WHUSDTE, SLP>(create<WHUSDTE>(required_deposit), &mut ticket, &clock);
                assert!(destroy(surplus) == 0, 404);
            };

            let yt_bal = multi_asset_vault.settle_deposit_ticket(ticket);
            assert!(destroy(yt_bal) == deposit_usdc_value, 404);

            test::return_shared(multi_asset_vault);
        };

        // validation
        next_tx(s,a);{
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let performance_fee = 100;
            
            // >> USDC
            multi_asset_vault.assert_vault_info<WHUSDCE, SLP>(deposit_usdc_value, 0, 0, 0, performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());

            // >> USDT
            multi_asset_vault.assert_vault_info<WHUSDTE, SLP>(deposit_usdc_value, 0, 0, 0, performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());

            test::return_shared(multi_asset_vault);
        };

        (scenario, clock)
    }
}
