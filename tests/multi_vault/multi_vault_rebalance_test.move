#[test_only]
#[allow(unused)]
module vault::multi_vault_rebalance_test{
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
    use vault::multi_vault_deposit_test::{
        test_deposit,
        test_deposit_with_identical_borrowed_assets_strategies
    };

    const START_TIME: u64 = 1_000_000_000;
    const DEFAULT_PROFIT_UNLOCK_DURATION_SEC: u64 = 60 * 60; // 1 hour

    fun people():(address, address, address){
        (@0xA, @0xB, @0xC)
    }

    #[test] 
    public fun test_rebalance():(Scenario, Clock){
        let (mut scenario, mut clock) = test_deposit();
        let s = &mut scenario;
        let (a, _, _) = people();

        // past 1 HOUR
        clock.add_time(3600 * 1000);
 
        next_tx(s,a);{
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let admin_cap = test::take_from_sender<AdminCap<SLP>>(s);

            let mut usdc_strategy = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let mut usdt_strategy = test::take_shared<MockStrategy<WHUSDTE>>(s);
            // set target alloc points
            admin_cap.set_strategy_target_alloc_weights_bps<WHUSDCE, SLP>(&mut multi_asset_vault, vector[usdc_strategy.vault_access_id()], vector[ 10000 ]);
            admin_cap.set_strategy_target_alloc_weights_bps<WHUSDTE, SLP>(&mut multi_asset_vault, vector[usdt_strategy.vault_access_id()], vector[ 10000 ]);

            // >> USDC
            let profit = balance::zero();
            mock_strategy::deposit_external_profits(&admin_cap, &mut usdc_strategy, &mut multi_asset_vault, profit, &clock);
            let usdc_rebalance_amounts = multi_asset_vault.calc_rebalance_amounts_by_asset<WHUSDCE, SLP>(&clock);
            mock_strategy::rebalance(&mut usdc_strategy, &admin_cap, &mut multi_asset_vault, &usdc_rebalance_amounts);
            // >> USDT
            let profit = balance::zero();
            mock_strategy::deposit_external_profits(&admin_cap, &mut usdt_strategy, &mut multi_asset_vault, profit, &clock);
            let usdt_rebalance_amounts = multi_asset_vault.calc_rebalance_amounts_by_asset<WHUSDTE, SLP>(&clock);
            mock_strategy::rebalance(&mut usdt_strategy, &admin_cap, &mut multi_asset_vault, &usdt_rebalance_amounts);

            // validation
            let deposited_val = 0;
            let borrowed_val = math::pow(10, 9);
            let usdc_strategy_id = usdc_strategy.vault_access_id();
            let usdt_strategy_id = usdt_strategy.vault_access_id();
            let now = timestamp_sec(&clock);
            // USDC
            multi_asset_vault.assert_vault_info<WHUSDCE, SLP>(0, 0, 0, 0, 0, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDCE, SLP>(usdc_strategy_id, borrowed_val, 10000, option::none());
            multi_asset_vault.time_locked_profit<WHUSDCE, SLP>().assert_time_locked_balance_info<WHUSDCE>(0, now, 0, 0, 0, now);
            let scoin_val = math::pow(10, 9);
            usdc_strategy.assert_strategy_info(scoin_val, scoin_val, 0);
            // USDT
            multi_asset_vault.assert_vault_info<WHUSDTE, SLP>(0, 0, 0, 0, 0, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDTE, SLP>(usdt_strategy_id, borrowed_val, 10000, option::none());
            multi_asset_vault.time_locked_profit<WHUSDTE, SLP>().assert_time_locked_balance_info<WHUSDTE>(0, now, 0, 0, 0, now);
            usdt_strategy.assert_strategy_info(scoin_val, scoin_val, 0);


            test::return_shared(multi_asset_vault);
            test::return_shared(usdc_strategy);
            test::return_shared(usdt_strategy);
            test::return_to_sender(s, admin_cap);
        };

        (scenario, clock)
    }

    #[test]
    public fun start_with_positive_staking_rewards():(Scenario, Clock){
        let (mut scenario, mut clock) = test_rebalance();
        let s = &mut scenario;
        let (a, _, _) = people();

        let added_rewards = 1000;
        // increase rewards for mock_strategoes
        next_tx(s,a);{
            let mut usdc_strategy = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let mut usdt_strategy = test::take_shared<MockStrategy<WHUSDTE>>(s);

            usdc_strategy.acc_rewards(create<WHUSDCE>(added_rewards));
            usdt_strategy.acc_rewards(create<WHUSDTE>(added_rewards));

            test::return_shared(usdc_strategy);
            test::return_shared(usdt_strategy);
        };

        next_tx(s,a);{
            // move the balance out
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let admin_cap = test::take_from_sender<AdminCap<SLP>>(s);
            let mut usdc_strategy = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let mut usdt_strategy = test::take_shared<MockStrategy<WHUSDTE>>(s);
            let usdc_strategy_id = usdc_strategy.vault_access_id();
            let usdt_strategy_id = usdt_strategy.vault_access_id();

            // >> USDC
            usdc_strategy.skim_base_profits(&admin_cap);
            let profit = balance::zero();
            mock_strategy::deposit_external_profits(&admin_cap, &mut usdc_strategy, &mut multi_asset_vault, profit, &clock);
            let usdc_rebalance_amounts = multi_asset_vault.calc_rebalance_amounts_by_asset<WHUSDCE, SLP>(&clock);
            mock_strategy::rebalance(&mut usdc_strategy, &admin_cap, &mut multi_asset_vault, &usdc_rebalance_amounts);
            // >> USDT
            usdt_strategy.skim_base_profits(&admin_cap);
            let profit = balance::zero();
            mock_strategy::deposit_external_profits(&admin_cap, &mut usdt_strategy, &mut multi_asset_vault, profit, &clock);
            let usdt_rebalance_amounts = multi_asset_vault.calc_rebalance_amounts_by_asset<WHUSDTE, SLP>(&clock);
            mock_strategy::rebalance(&mut usdt_strategy, &admin_cap, &mut multi_asset_vault, &usdt_rebalance_amounts);

            // validation ( Move all the collected rewards to locked_balance )
            let now = timestamp_sec(&clock);
            let collected_performance_fee = 100;
            // strategies
            let borrowed_val = math::pow(10, 9);
            // TLB
            let locked_balance = 900;
            let unlock_per_second = math::divide_and_round_up(locked_balance, DEFAULT_PROFIT_UNLOCK_DURATION_SEC);
            let unlock_start_ts_sec = now;
            let unlocked_balance = 0;
            let final_unlock_ts_sec = unlock_start_ts_sec + locked_balance/unlock_per_second;
            // >> USDC
            multi_asset_vault.assert_vault_info<WHUSDCE, SLP>(0, locked_balance, 0, unlock_per_second, collected_performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDCE, SLP>(usdc_strategy_id, borrowed_val, 10000, option::none());
            multi_asset_vault.time_locked_profit<WHUSDCE, SLP>().assert_time_locked_balance_info<WHUSDCE>(locked_balance, now, unlock_per_second, 0, final_unlock_ts_sec, now);
            // >> USDT
            multi_asset_vault.assert_vault_info<WHUSDTE, SLP>(0, locked_balance, 0, unlock_per_second, collected_performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDTE, SLP>(usdt_strategy_id, borrowed_val, 10000, option::none());
            multi_asset_vault.time_locked_profit<WHUSDTE, SLP>().assert_time_locked_balance_info<WHUSDTE>(locked_balance, now, unlock_per_second, 0, final_unlock_ts_sec, now);

            test::return_shared(multi_asset_vault);
            test::return_shared(usdc_strategy);
            test::return_shared(usdt_strategy);
            test::return_to_sender(s, admin_cap);
        };

        clock.add_time(3600 * 1000);

        next_tx(s,a);{
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let admin_cap = test::take_from_sender<AdminCap<SLP>>(s);
            let mut usdc_strategy = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let mut usdt_strategy = test::take_shared<MockStrategy<WHUSDTE>>(s);
            let usdc_strategy_id = usdc_strategy.vault_access_id();
            let usdt_strategy_id = usdt_strategy.vault_access_id();

            // >> USDC
            usdc_strategy.skim_base_profits(&admin_cap);
            let profit = balance::zero();
            mock_strategy::deposit_external_profits(&admin_cap, &mut usdc_strategy, &mut multi_asset_vault, profit, &clock);
            let usdc_rebalance_amounts = multi_asset_vault.calc_rebalance_amounts_by_asset<WHUSDCE, SLP>(&clock);
            mock_strategy::rebalance(&mut usdc_strategy, &admin_cap, &mut multi_asset_vault, &usdc_rebalance_amounts);
            // >> USDT
            usdt_strategy.skim_base_profits(&admin_cap);
            let profit = balance::zero();
            mock_strategy::deposit_external_profits(&admin_cap, &mut usdt_strategy, &mut multi_asset_vault, profit, &clock);
            let usdt_rebalance_amounts = multi_asset_vault.calc_rebalance_amounts_by_asset<WHUSDTE, SLP>(&clock);
            mock_strategy::rebalance(&mut usdt_strategy, &admin_cap, &mut multi_asset_vault, &usdt_rebalance_amounts);

            // validation
            let now = timestamp_sec(&clock);
            let scoin_val = 0;
            let collected_performance_fee = 100;
            let locked_balance = 0;
            // >> USDC
            multi_asset_vault.assert_vault_info<WHUSDCE, SLP>(0, locked_balance, 0, 0, collected_performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            let borrowed_val = math::pow(10, 9) + 900;
            multi_asset_vault.assert_vault_strategy_state<WHUSDCE, SLP>(usdc_strategy_id, borrowed_val, 10000, option::none());
            multi_asset_vault.time_locked_profit<WHUSDCE, SLP>().assert_time_locked_balance_info<WHUSDCE>(0, now, 0, 0, 0, now);
            // >> USDT
            multi_asset_vault.assert_vault_info<WHUSDTE, SLP>(0, locked_balance, 0, 0, collected_performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDTE, SLP>(usdt_strategy_id, borrowed_val, 10000, option::none());
            multi_asset_vault.time_locked_profit<WHUSDTE, SLP>().assert_time_locked_balance_info<WHUSDTE>(0, now, 0, 0, 0, now);

            test::return_shared(multi_asset_vault);
            test::return_shared(usdc_strategy);
            test::return_shared(usdt_strategy);
            test::return_to_sender(s, admin_cap);
        };

        (scenario, clock)
    }

    #[test]
    public fun start_with_positive_staking_rewards_identical_borrowed_assets_strategies():(Scenario, Clock){
        let (mut scenario, mut clock) = test_rebalance_with_identical_borrowed_assets_strategies();
        let s = &mut scenario;
        let (a, _, _) = people();

        let added_rewards = 1000;
        // increase rewards for mock_strategoes
        next_tx(s,a);{
            let mut usdc_strategy = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let mut usdc_strategy_1 = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let mut usdt_strategy = test::take_shared<MockStrategy<WHUSDTE>>(s);

            usdc_strategy.acc_rewards(create<WHUSDCE>(added_rewards));
            usdc_strategy_1.acc_rewards(create<WHUSDCE>(added_rewards));
            usdt_strategy.acc_rewards(create<WHUSDTE>(added_rewards));

            test::return_shared(usdc_strategy_1);
            test::return_shared(usdc_strategy);
            test::return_shared(usdt_strategy);
        };

        next_tx(s,a);{
            // move the balance out
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let admin_cap = test::take_from_sender<AdminCap<SLP>>(s);
            let mut usdc_strategy = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let mut usdc_strategy_1 = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let mut usdt_strategy = test::take_shared<MockStrategy<WHUSDTE>>(s);
            let usdc_strategy_id = usdc_strategy.vault_access_id();
            let usdc_strategy_1_id = usdc_strategy_1.vault_access_id();
            let usdt_strategy_id = usdt_strategy.vault_access_id();

            // >> USDC
            // >>>> usdc_strategy
            usdc_strategy.skim_base_profits(&admin_cap);
            let profit = balance::zero();
            mock_strategy::deposit_external_profits(&admin_cap, &mut usdc_strategy, &mut multi_asset_vault, profit, &clock);
            // >>>> usdc_strategy_1
            usdc_strategy_1.skim_base_profits(&admin_cap);
            let profit = balance::zero();
            mock_strategy::deposit_external_profits(&admin_cap, &mut usdc_strategy_1, &mut multi_asset_vault, profit, &clock);

            let usdc_rebalance_amounts = multi_asset_vault.calc_rebalance_amounts_by_asset<WHUSDCE, SLP>(&clock);
            mock_strategy::rebalance(&mut usdc_strategy, &admin_cap, &mut multi_asset_vault, &usdc_rebalance_amounts);
            mock_strategy::rebalance(&mut usdc_strategy_1, &admin_cap, &mut multi_asset_vault, &usdc_rebalance_amounts);
            // >> USDT
            usdt_strategy.skim_base_profits(&admin_cap);
            let profit = balance::zero();
            mock_strategy::deposit_external_profits(&admin_cap, &mut usdt_strategy, &mut multi_asset_vault, profit, &clock);
            let usdt_rebalance_amounts = multi_asset_vault.calc_rebalance_amounts_by_asset<WHUSDTE, SLP>(&clock);
            mock_strategy::rebalance(&mut usdt_strategy, &admin_cap, &mut multi_asset_vault, &usdt_rebalance_amounts);


            // validation ( Move all the collected rewards to locked_balance )
            let now = timestamp_sec(&clock);
            let usdc_collected_performance_fee = 200;
            let usdt_collected_performance_fee = 100;
            // strategies
            let usdc_strategy_borrowed = 0_750000000; 
            let usdc_strategy_1_borrowed = 0_250000000; 
            let usdt_borrowed = math::pow(10, 9);
            // TLB
            let usdc_locked_balance = 1800;
            let usdt_locked_balance = 900;
            let usdc_unlock_per_second = math::divide_and_round_up(usdc_locked_balance, DEFAULT_PROFIT_UNLOCK_DURATION_SEC);
            let usdt_unlock_per_second = math::divide_and_round_up(usdt_locked_balance, DEFAULT_PROFIT_UNLOCK_DURATION_SEC);
            let unlock_start_ts_sec = now;
            let unlocked_balance = 0;
            let usdc_final_unlock_ts_sec = unlock_start_ts_sec + usdc_locked_balance/usdc_unlock_per_second;
            let usdt_final_unlock_ts_sec = unlock_start_ts_sec + usdt_locked_balance/usdt_unlock_per_second;
            // >> USDC
            multi_asset_vault.assert_vault_info<WHUSDCE, SLP>(0, usdc_locked_balance, 0, usdc_unlock_per_second, usdc_collected_performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDCE, SLP>(usdc_strategy_id, usdc_strategy_borrowed, 7500, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDCE, SLP>(usdc_strategy_1_id, usdc_strategy_1_borrowed, 2500, option::none());
            multi_asset_vault.time_locked_profit<WHUSDCE, SLP>().assert_time_locked_balance_info<WHUSDCE>(usdc_locked_balance, now, usdc_unlock_per_second, 0, usdc_final_unlock_ts_sec, now);
            // >> USDT
            multi_asset_vault.assert_vault_info<WHUSDTE, SLP>(0, usdt_locked_balance, 0, usdt_unlock_per_second, usdt_collected_performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDTE, SLP>(usdt_strategy_id, usdt_borrowed, 10000, option::none());
            multi_asset_vault.time_locked_profit<WHUSDTE, SLP>().assert_time_locked_balance_info<WHUSDTE>(usdt_locked_balance, now, usdt_unlock_per_second, 0, usdt_final_unlock_ts_sec, now);

            test::return_shared(multi_asset_vault);
            test::return_shared(usdc_strategy_1);
            test::return_shared(usdc_strategy);
            test::return_shared(usdt_strategy);
            test::return_to_sender(s, admin_cap);
        };

        clock.add_time(3600 * 1000);

        next_tx(s,a);{
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let admin_cap = test::take_from_sender<AdminCap<SLP>>(s);
            let mut usdc_strategy = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let mut usdc_strategy_1 = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let mut usdt_strategy = test::take_shared<MockStrategy<WHUSDTE>>(s);
            let usdc_strategy_id = usdc_strategy.vault_access_id();
            let usdc_strategy_1_id = usdc_strategy_1.vault_access_id();
            let usdt_strategy_id = usdt_strategy.vault_access_id();

            // >> USDC
            // >>>> usdc_strategy
            usdc_strategy.skim_base_profits(&admin_cap);
            let profit = balance::zero();
            mock_strategy::deposit_external_profits(&admin_cap, &mut usdc_strategy, &mut multi_asset_vault, profit, &clock);
            // >>>> usdc_strategy_1
            usdc_strategy_1.skim_base_profits(&admin_cap);
            let profit = balance::zero();
            mock_strategy::deposit_external_profits(&admin_cap, &mut usdc_strategy_1, &mut multi_asset_vault, profit, &clock);

            let usdc_rebalance_amounts = multi_asset_vault.calc_rebalance_amounts_by_asset<WHUSDCE, SLP>(&clock);
            mock_strategy::rebalance(&mut usdc_strategy, &admin_cap, &mut multi_asset_vault, &usdc_rebalance_amounts);
            mock_strategy::rebalance(&mut usdc_strategy_1, &admin_cap, &mut multi_asset_vault, &usdc_rebalance_amounts);
            // >> USDT
            usdt_strategy.skim_base_profits(&admin_cap);
            let profit = balance::zero();
            mock_strategy::deposit_external_profits(&admin_cap, &mut usdt_strategy, &mut multi_asset_vault, profit, &clock);
            let usdt_rebalance_amounts = multi_asset_vault.calc_rebalance_amounts_by_asset<WHUSDTE, SLP>(&clock);
            mock_strategy::rebalance(&mut usdt_strategy, &admin_cap, &mut multi_asset_vault, &usdt_rebalance_amounts);

            // validation
            let now = timestamp_sec(&clock);
            let scoin_val = 0;
            let usdc_collected_performance_fee = 200;
            let usdt_collected_performance_fee = 100;
            let locked_balance = 0;
            // >> USDC
            multi_asset_vault.assert_vault_info<WHUSDCE, SLP>(0, locked_balance, 0, 0, usdc_collected_performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            let usdc_strategy_borrowed = 0_750000000 + 1350; // 1800 profit * 0.75
            let usdc_strategy_1_borrowed = 0_250000000 + 450; // 1800 profit * 0.25
            multi_asset_vault.assert_vault_strategy_state<WHUSDCE, SLP>(usdc_strategy_id, usdc_strategy_borrowed, 7500, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDCE, SLP>(usdc_strategy_1_id, usdc_strategy_1_borrowed, 2500, option::none());
            multi_asset_vault.time_locked_profit<WHUSDCE, SLP>().assert_time_locked_balance_info<WHUSDCE>(0, now, 0, 0, 0, now);
            // >> USDT
            let usdt_borrowed = math::pow(10, 9) + 900;
            multi_asset_vault.assert_vault_info<WHUSDTE, SLP>(0, locked_balance, 0, 0, usdt_collected_performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDTE, SLP>(usdt_strategy_id, usdt_borrowed, 10000, option::none());
            multi_asset_vault.time_locked_profit<WHUSDTE, SLP>().assert_time_locked_balance_info<WHUSDTE>(0, now, 0, 0, 0, now);

            test::return_shared(multi_asset_vault);
            test::return_shared(usdc_strategy_1);
            test::return_shared(usdc_strategy);
            test::return_shared(usdt_strategy);
            test::return_to_sender(s, admin_cap);
        };

        (scenario, clock)
    }

    #[test]
    public fun start_with_borrowed_bad_debt():(Scenario, Clock){
        let (mut scenario, mut clock) = test_rebalance();
        let s = &mut scenario;
        let (a, _, _) = people();

        let taked_rewards = 1000;
        // increase rewards for mock_strategoes
        next_tx(s,a);{
            let mut usdc_strategy = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let mut usdt_strategy = test::take_shared<MockStrategy<WHUSDTE>>(s);

            usdc_strategy.take_rewards(taked_rewards);
            usdt_strategy.take_rewards(taked_rewards);

            test::return_shared(usdc_strategy);
            test::return_shared(usdt_strategy);
        };

        next_tx(s,a);{
            // move the balance out
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let admin_cap = test::take_from_sender<AdminCap<SLP>>(s);
            let mut usdc_strategy = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let mut usdt_strategy = test::take_shared<MockStrategy<WHUSDTE>>(s);
            let usdc_strategy_id = usdc_strategy.vault_access_id();
            let usdt_strategy_id = usdt_strategy.vault_access_id();

            // >> USDC
            usdc_strategy.skim_base_profits(&admin_cap);
            let profit = balance::zero();
            mock_strategy::deposit_external_profits(&admin_cap, &mut usdc_strategy, &mut multi_asset_vault, profit, &clock);
            let usdc_rebalance_amounts = multi_asset_vault.calc_rebalance_amounts_by_asset<WHUSDCE, SLP>(&clock);
            mock_strategy::rebalance(&mut usdc_strategy, &admin_cap, &mut multi_asset_vault, &usdc_rebalance_amounts);
            // >> USDT
            usdt_strategy.skim_base_profits(&admin_cap);
            let profit = balance::zero();
            mock_strategy::deposit_external_profits(&admin_cap, &mut usdt_strategy, &mut multi_asset_vault, profit, &clock);
            let usdt_rebalance_amounts = multi_asset_vault.calc_rebalance_amounts_by_asset<WHUSDTE, SLP>(&clock);
            mock_strategy::rebalance(&mut usdt_strategy, &admin_cap, &mut multi_asset_vault, &usdt_rebalance_amounts);

            // validation ( Move all the collected rewards to locked_balance )
            let now = timestamp_sec(&clock);
            let collected_performance_fee = 0;
            // strategies
            let borrowed_val = math::pow(10, 9);
            // TLB
            let locked_balance = 0;
            let unlock_per_second = math::divide_and_round_up(locked_balance, DEFAULT_PROFIT_UNLOCK_DURATION_SEC);
            let unlock_start_ts_sec = now;
            let unlocked_balance = 0;
            let final_unlock_ts_sec = if(unlock_per_second == 0) 0 else unlock_start_ts_sec + locked_balance/unlock_per_second;
            // >> USDC
            multi_asset_vault.assert_vault_info<WHUSDCE, SLP>(0, locked_balance, 0, unlock_per_second, collected_performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDCE, SLP>(usdc_strategy_id, borrowed_val, 10000, option::none());
            multi_asset_vault.time_locked_profit<WHUSDCE, SLP>().assert_time_locked_balance_info<WHUSDCE>(locked_balance, now, unlock_per_second, 0, final_unlock_ts_sec, now);
            // >> USDT
            multi_asset_vault.assert_vault_info<WHUSDTE, SLP>(0, locked_balance, 0, unlock_per_second, collected_performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDTE, SLP>(usdt_strategy_id, borrowed_val, 10000, option::none());
            multi_asset_vault.time_locked_profit<WHUSDTE, SLP>().assert_time_locked_balance_info<WHUSDTE>(locked_balance, now, unlock_per_second, 0, final_unlock_ts_sec, now);

            test::return_shared(multi_asset_vault);
            test::return_shared(usdc_strategy);
            test::return_shared(usdt_strategy);
            test::return_to_sender(s, admin_cap);
        };

        clock.add_time(3600 * 1000);

        next_tx(s,a);{
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let admin_cap = test::take_from_sender<AdminCap<SLP>>(s);
            let mut usdc_strategy = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let mut usdt_strategy = test::take_shared<MockStrategy<WHUSDTE>>(s);
            let usdc_strategy_id = usdc_strategy.vault_access_id();
            let usdt_strategy_id = usdt_strategy.vault_access_id();

            // >> USDC
            usdc_strategy.skim_base_profits(&admin_cap);
            let profit = balance::zero();
            mock_strategy::deposit_external_profits(&admin_cap, &mut usdc_strategy, &mut multi_asset_vault, profit, &clock);
            let usdc_rebalance_amounts = multi_asset_vault.calc_rebalance_amounts_by_asset<WHUSDCE, SLP>(&clock);
            mock_strategy::rebalance(&mut usdc_strategy, &admin_cap, &mut multi_asset_vault, &usdc_rebalance_amounts);
            // >> USDT
            usdt_strategy.skim_base_profits(&admin_cap);
            let profit = balance::zero();
            mock_strategy::deposit_external_profits(&admin_cap, &mut usdt_strategy, &mut multi_asset_vault, profit, &clock);
            let usdt_rebalance_amounts = multi_asset_vault.calc_rebalance_amounts_by_asset<WHUSDTE, SLP>(&clock);
            mock_strategy::rebalance(&mut usdt_strategy, &admin_cap, &mut multi_asset_vault, &usdt_rebalance_amounts);

            // validation
            let now = timestamp_sec(&clock);
            let scoin_val = 0;
            let collected_performance_fee = 0;
            let locked_balance = 0;
            // >> USDC
            multi_asset_vault.assert_vault_info<WHUSDCE, SLP>(0, locked_balance, 0, 0, collected_performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            // borrowed_val didn't update
            let borrowed_val = math::pow(10, 9);
            multi_asset_vault.assert_vault_strategy_state<WHUSDCE, SLP>(usdc_strategy_id, borrowed_val, 10000, option::none());
            multi_asset_vault.time_locked_profit<WHUSDCE, SLP>().assert_time_locked_balance_info<WHUSDCE>(0, now, 0, 0, 0, now);
            // >> USDT
            multi_asset_vault.assert_vault_info<WHUSDTE, SLP>(0, locked_balance, 0, 0, collected_performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDTE, SLP>(usdt_strategy_id, borrowed_val, 10000, option::none());
            multi_asset_vault.time_locked_profit<WHUSDTE, SLP>().assert_time_locked_balance_info<WHUSDTE>(0, now, 0, 0, 0, now);

            test::return_shared(multi_asset_vault);
            test::return_shared(usdc_strategy);
            test::return_shared(usdt_strategy);
            test::return_to_sender(s, admin_cap);
        };

        next_tx(s,a);{
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let admin_cap = test::take_from_sender<AdminCap<SLP>>(s);

            let mut usdc_strategy = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let usdc_strategy_id = usdc_strategy.vault_access_id();
            let mut usdt_strategy = test::take_shared<MockStrategy<WHUSDTE>>(s);
            let usdt_strategy_id = usdt_strategy.vault_access_id();

            // initialize withdrawal ticket
            let redeem_lp_token_amt = math::pow(10, 9) / 2;
            let redeem_lp_token = create<SLP>(redeem_lp_token_amt);
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
                assert!(destroy(usdc) == 499_999_500, 404);
                // >> USDT
                let usdt = multi_asset_vault.redeem_withdraw_ticket<WHUSDTE, SLP>(&mut ticket);
                assert!(destroy(usdt) == 499_999_500, 404);
            };
            
            multi_asset_vault.settle_withdraw_ticket(ticket);


            let now = timestamp_sec(&clock);
            let borrowed = 5 * math::pow(10, 8);
            // validation
            // >> USDC
            multi_asset_vault.assert_vault_info<WHUSDCE, SLP>(0, 0, 0, 0, 0, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDCE, SLP>(usdc_strategy_id, borrowed, 10000, option::none());
            multi_asset_vault.time_locked_profit<WHUSDCE, SLP>().assert_time_locked_balance_info<WHUSDCE>(0, now, 0, 0, 0, now);

            let scoin_val = 499_999_500;
            let underlying_value = 5 * math::pow(10, 8);
            usdc_strategy.assert_strategy_info(scoin_val, underlying_value, 0);
            // >> USDT
            multi_asset_vault.assert_vault_info<WHUSDTE, SLP>(0, 0, 0, 0, 0, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDTE, SLP>(usdt_strategy_id, borrowed, 10000, option::none());
            multi_asset_vault.time_locked_profit<WHUSDTE, SLP>().assert_time_locked_balance_info<WHUSDTE>(0, now, 0, 0, 0, now);
            usdt_strategy.assert_strategy_info(scoin_val, underlying_value, 0);


            test::return_shared(multi_asset_vault);
            test::return_shared(usdc_strategy);
            test::return_shared(usdt_strategy);
            test::return_to_sender(s, admin_cap);
        };

        // withdraw all the remaining
        next_tx(s,a);{
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let admin_cap = test::take_from_sender<AdminCap<SLP>>(s);

            let mut usdc_strategy = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let usdc_strategy_id = usdc_strategy.vault_access_id();
            let mut usdt_strategy = test::take_shared<MockStrategy<WHUSDTE>>(s);
            let usdt_strategy_id = usdt_strategy.vault_access_id();

            // initialize withdrawal ticket
            let redeem_lp_token_amt = math::pow(10, 9) / 2;
            let redeem_lp_token = create<SLP>(redeem_lp_token_amt);
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
                assert!(destroy(usdc) == 499_999_500, 404);
                // >> USDT
                let usdt = multi_asset_vault.redeem_withdraw_ticket<WHUSDTE, SLP>(&mut ticket);
                assert!(destroy(usdt) == 499_999_500, 404);
            };
            
            multi_asset_vault.settle_withdraw_ticket(ticket);


            let now = timestamp_sec(&clock);
            let borrowed = 0;
            // validation
            // >> USDC
            multi_asset_vault.assert_vault_info<WHUSDCE, SLP>(0, 0, 0, 0, 0, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDCE, SLP>(usdc_strategy_id, borrowed, 10000, option::none());
            multi_asset_vault.time_locked_profit<WHUSDCE, SLP>().assert_time_locked_balance_info<WHUSDCE>(0, now, 0, 0, 0, now);

            let scoin_val = 0;
            let underlying_value = 0;
            usdc_strategy.assert_strategy_info(scoin_val, underlying_value, 0);
            // >> USDT
            multi_asset_vault.assert_vault_info<WHUSDTE, SLP>(0, 0, 0, 0, 0, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDTE, SLP>(usdt_strategy_id, borrowed, 10000, option::none());
            multi_asset_vault.time_locked_profit<WHUSDTE, SLP>().assert_time_locked_balance_info<WHUSDTE>(0, now, 0, 0, 0, now);
            usdt_strategy.assert_strategy_info(scoin_val, underlying_value, 0);


            test::return_shared(multi_asset_vault);
            test::return_shared(usdc_strategy);
            test::return_shared(usdt_strategy);
            test::return_to_sender(s, admin_cap);
        };

        (scenario, clock)
    }

    #[test]
    public fun start_with_strategy_with_max_borrow_constraint():(Scenario, Clock){
        let (mut scenario, mut clock) = test_rebalance();
        let s = &mut scenario;
        let (a, _, _) = people();

        next_tx(s,a);{ // set the max_borrow
            let admin_cap = test::take_from_sender<AdminCap<SLP>>(s);
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let usdc_strategy = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let usdt_strategy = test::take_shared<MockStrategy<WHUSDTE>>(s);
            let usdc_strategy_id = usdc_strategy.vault_access_id();
            let usdt_strategy_id = usdt_strategy.vault_access_id();

            let max_borrow = math::pow(10, 9) /2; // take the half of borrowed amt back
            mav::set_strategy_max_borrow_by_asset<WHUSDCE, SLP>(&admin_cap, &mut multi_asset_vault, usdc_strategy_id, option::some(max_borrow));
            mav::set_strategy_max_borrow_by_asset<WHUSDTE, SLP>(&admin_cap, &mut multi_asset_vault, usdt_strategy_id, option::some(max_borrow));

            test::return_shared(multi_asset_vault);
            test::return_shared(usdc_strategy);
            test::return_shared(usdt_strategy);
            test::return_to_sender(s, admin_cap);
        };

        next_tx(s,a);{
            // repaid the borrowed balance back to free_balance
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let admin_cap = test::take_from_sender<AdminCap<SLP>>(s);
            let mut usdc_strategy = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let mut usdt_strategy = test::take_shared<MockStrategy<WHUSDTE>>(s);
            let usdc_strategy_id = usdc_strategy.vault_access_id();
            let usdt_strategy_id = usdt_strategy.vault_access_id();

            // >> USDC
            usdc_strategy.skim_base_profits(&admin_cap);
            let profit = balance::zero();
            mock_strategy::deposit_external_profits(&admin_cap, &mut usdc_strategy, &mut multi_asset_vault, profit, &clock);
            let usdc_rebalance_amounts = multi_asset_vault.calc_rebalance_amounts_by_asset<WHUSDCE, SLP>(&clock);
            mock_strategy::rebalance(&mut usdc_strategy, &admin_cap, &mut multi_asset_vault, &usdc_rebalance_amounts);
            // >> USDT
            usdt_strategy.skim_base_profits(&admin_cap);
            let profit = balance::zero();
            mock_strategy::deposit_external_profits(&admin_cap, &mut usdt_strategy, &mut multi_asset_vault, profit, &clock);
            let usdt_rebalance_amounts = multi_asset_vault.calc_rebalance_amounts_by_asset<WHUSDTE, SLP>(&clock);
            mock_strategy::rebalance(&mut usdt_strategy, &admin_cap, &mut multi_asset_vault, &usdt_rebalance_amounts);

            // validation ( Move all the collected rewards to locked_balance )
            let now = timestamp_sec(&clock);
            let collected_performance_fee = 0;
            // strategies
            let returned_val = math::pow(10, 9) / 2;
            let borrowed_val = math::pow(10, 9) - returned_val;
            // TLB
            let locked_balance = 0;
            let unlock_per_second = math::divide_and_round_up(locked_balance, DEFAULT_PROFIT_UNLOCK_DURATION_SEC);
            let unlock_start_ts_sec = now;
            let unlocked_balance = 0;
            let final_unlock_ts_sec = if(unlock_per_second == 0) 0 else unlock_start_ts_sec + locked_balance/unlock_per_second;
            // >> USDC
            multi_asset_vault.assert_vault_info<WHUSDCE, SLP>(returned_val, locked_balance, 0, unlock_per_second, collected_performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDCE, SLP>(usdc_strategy_id, borrowed_val, 10000, option::some(borrowed_val));
            multi_asset_vault.time_locked_profit<WHUSDCE, SLP>().assert_time_locked_balance_info<WHUSDCE>(locked_balance, now, unlock_per_second, 0, final_unlock_ts_sec, now);
            // >> USDT
            multi_asset_vault.assert_vault_info<WHUSDTE, SLP>(returned_val, locked_balance, 0, unlock_per_second, collected_performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDTE, SLP>(usdt_strategy_id, borrowed_val, 10000, option::some(borrowed_val));
            multi_asset_vault.time_locked_profit<WHUSDTE, SLP>().assert_time_locked_balance_info<WHUSDTE>(locked_balance, now, unlock_per_second, 0, final_unlock_ts_sec, now);

            test::return_shared(multi_asset_vault);
            test::return_shared(usdc_strategy);
            test::return_shared(usdt_strategy);
            test::return_to_sender(s, admin_cap);
        };

        clock.add_time(3600 * 1000);

        next_tx(s,a);{
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let admin_cap = test::take_from_sender<AdminCap<SLP>>(s);
            let mut usdc_strategy = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let mut usdt_strategy = test::take_shared<MockStrategy<WHUSDTE>>(s);
            let usdc_strategy_id = usdc_strategy.vault_access_id();
            let usdt_strategy_id = usdt_strategy.vault_access_id();

            // rebalance again shouldn't affect borrowed_amt

            // >> USDC
            usdc_strategy.skim_base_profits(&admin_cap);
            let profit = balance::zero();
            mock_strategy::deposit_external_profits(&admin_cap, &mut usdc_strategy, &mut multi_asset_vault, profit, &clock);
            let usdc_rebalance_amounts = multi_asset_vault.calc_rebalance_amounts_by_asset<WHUSDCE, SLP>(&clock);
            mock_strategy::rebalance(&mut usdc_strategy, &admin_cap, &mut multi_asset_vault, &usdc_rebalance_amounts);
            // >> USDT
            usdt_strategy.skim_base_profits(&admin_cap);
            let profit = balance::zero();
            mock_strategy::deposit_external_profits(&admin_cap, &mut usdt_strategy, &mut multi_asset_vault, profit, &clock);
            let usdt_rebalance_amounts = multi_asset_vault.calc_rebalance_amounts_by_asset<WHUSDTE, SLP>(&clock);
            mock_strategy::rebalance(&mut usdt_strategy, &admin_cap, &mut multi_asset_vault, &usdt_rebalance_amounts);

            // validation
            let now = timestamp_sec(&clock);
            let collected_performance_fee = 0;
            // strategies
            let returned_val = math::pow(10, 9) / 2;
            let borrowed_val = math::pow(10, 9) - returned_val;
            // TLB
            let locked_balance = 0;
            let unlock_per_second = math::divide_and_round_up(locked_balance, DEFAULT_PROFIT_UNLOCK_DURATION_SEC);
            let unlock_start_ts_sec = now;
            let unlocked_balance = 0;
            let final_unlock_ts_sec = if(unlock_per_second == 0) 0 else unlock_start_ts_sec + locked_balance/unlock_per_second;
            // >> USDC
            multi_asset_vault.assert_vault_info<WHUSDCE, SLP>(returned_val, locked_balance, 0, 0, collected_performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDCE, SLP>(usdc_strategy_id, borrowed_val, 10000, option::some(borrowed_val));
            multi_asset_vault.time_locked_profit<WHUSDCE, SLP>().assert_time_locked_balance_info<WHUSDCE>(0, now, 0, 0, 0, now);
            // >> USDT
            multi_asset_vault.assert_vault_info<WHUSDTE, SLP>(returned_val, locked_balance, 0, 0, collected_performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDTE, SLP>(usdt_strategy_id, borrowed_val, 10000, option::some(borrowed_val));
            multi_asset_vault.time_locked_profit<WHUSDTE, SLP>().assert_time_locked_balance_info<WHUSDTE>(0, now, 0, 0, 0, now);

            test::return_shared(multi_asset_vault);
            test::return_shared(usdc_strategy);
            test::return_shared(usdt_strategy);
            test::return_to_sender(s, admin_cap);
        };

        (scenario, clock)
    }

    #[test] 
    fun test_rebalance_advanced():(Scenario, Clock){
        let (mut scenario, mut clock) = start_with_positive_staking_rewards();
        let s = &mut scenario;
        let (a, _, _) = people();

        // add second rewards
        let added_rewards = 1000;

        // add second time rewards
        next_tx(s,a);{
            let mut usdc_strategy = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let mut usdt_strategy = test::take_shared<MockStrategy<WHUSDTE>>(s);

            usdc_strategy.acc_rewards(create<WHUSDCE>(added_rewards));
            usdt_strategy.acc_rewards(create<WHUSDTE>(added_rewards));

            test::return_shared(usdc_strategy);
            test::return_shared(usdt_strategy);
        };

        clock.add_time(3600 * 1000);

        next_tx(s,a);{
            // move the balance out
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let admin_cap = test::take_from_sender<AdminCap<SLP>>(s);
            let mut usdc_strategy = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let usdc_strategy_id = usdc_strategy.vault_access_id();
            let mut usdt_strategy = test::take_shared<MockStrategy<WHUSDTE>>(s);
            let usdt_strategy_id = usdt_strategy.vault_access_id();

            // >> USDC
            usdc_strategy.skim_base_profits(&admin_cap);
            let profit = balance::zero();
            mock_strategy::deposit_external_profits(&admin_cap, &mut usdc_strategy, &mut multi_asset_vault, profit, &clock);
            let usdc_rebalance_amounts = multi_asset_vault.calc_rebalance_amounts_by_asset<WHUSDCE, SLP>(&clock);
            mock_strategy::rebalance(&mut usdc_strategy, &admin_cap, &mut multi_asset_vault, &usdc_rebalance_amounts);
            // >> USDT
            usdt_strategy.skim_base_profits(&admin_cap);
            let profit = balance::zero();
            mock_strategy::deposit_external_profits(&admin_cap, &mut usdt_strategy, &mut multi_asset_vault, profit, &clock);
            let usdt_rebalance_amounts = multi_asset_vault.calc_rebalance_amounts_by_asset<WHUSDTE, SLP>(&clock);
            mock_strategy::rebalance(&mut usdt_strategy, &admin_cap, &mut multi_asset_vault, &usdt_rebalance_amounts);

            // validation ( Move all the collected rewards to locked_balance )
            let now = timestamp_sec(&clock);
            let collected_performance_fee = 100 * 2;
            // strategies
            let borrowed_val = math::pow(10, 9) + 900; // distributed rewards from locked_balance in previous cycle
            // TLB
            let locked_balance = 900;
            let unlock_per_second = math::divide_and_round_up(locked_balance, DEFAULT_PROFIT_UNLOCK_DURATION_SEC);
            let unlock_start_ts_sec = now;
            let unlocked_balance = 0;
            let final_unlock_ts_sec = unlock_start_ts_sec + locked_balance/unlock_per_second;
            // >> USDC
            multi_asset_vault.assert_vault_info<WHUSDCE, SLP>(0, locked_balance, 0, unlock_per_second, collected_performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDCE, SLP>(usdc_strategy_id, borrowed_val, 10000, option::none());
            multi_asset_vault.time_locked_profit<WHUSDCE, SLP>().assert_time_locked_balance_info<WHUSDCE>(locked_balance, now, unlock_per_second, 0, final_unlock_ts_sec, now);
            // >> USDT
            multi_asset_vault.assert_vault_info<WHUSDTE, SLP>(0, locked_balance, 0, unlock_per_second, collected_performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDTE, SLP>(usdt_strategy_id, borrowed_val, 10000, option::none());
            multi_asset_vault.time_locked_profit<WHUSDTE, SLP>().assert_time_locked_balance_info<WHUSDTE>(locked_balance, now, unlock_per_second, 0, final_unlock_ts_sec, now);

            test::return_shared(multi_asset_vault);
            test::return_shared(usdc_strategy);
            test::return_shared(usdt_strategy);
            test::return_to_sender(s, admin_cap);
        };


        (scenario, clock)
    }

    #[test] 
    fun test_rebalance_with_identical_borrowed_assets_strategies():(Scenario, Clock){
        let (mut scenario, mut clock) = test_deposit_with_identical_borrowed_assets_strategies();
        let s = &mut scenario;
        let (a, _, _) = people();

        // past 1 HOUR
        clock.add_time(3600 * 1000);
 
        next_tx(s,a);{
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let admin_cap = test::take_from_sender<AdminCap<SLP>>(s);

            let mut usdc_strategy = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let usdc_strategy_1 = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let mut usdt_strategy = test::take_shared<MockStrategy<WHUSDTE>>(s);

            // set target alloc points
            admin_cap.set_strategy_target_alloc_weights_bps<WHUSDCE, SLP>(&mut multi_asset_vault, vector[usdc_strategy.vault_access_id(), usdc_strategy_1.vault_access_id()], vector[ 7500, 2500]);
            admin_cap.set_strategy_target_alloc_weights_bps<WHUSDTE, SLP>(&mut multi_asset_vault, vector[usdt_strategy.vault_access_id()], vector[ 10000 ]);

            // >> USDC ( only rebalance first USDC strategy & USDT strategy )
            let profit = balance::zero();
            mock_strategy::deposit_external_profits(&admin_cap, &mut usdc_strategy, &mut multi_asset_vault, profit, &clock);
            let usdc_rebalance_amounts = multi_asset_vault.calc_rebalance_amounts_by_asset<WHUSDCE, SLP>(&clock);
            mock_strategy::rebalance(&mut usdc_strategy, &admin_cap, &mut multi_asset_vault, &usdc_rebalance_amounts);
            // >> USDT
            let profit = balance::zero();
            mock_strategy::deposit_external_profits(&admin_cap, &mut usdt_strategy, &mut multi_asset_vault, profit, &clock);
            let usdt_rebalance_amounts = multi_asset_vault.calc_rebalance_amounts_by_asset<WHUSDTE, SLP>(&clock);
            mock_strategy::rebalance(&mut usdt_strategy, &admin_cap, &mut multi_asset_vault, &usdt_rebalance_amounts);

            // validation
            let free_balance = 0_250000000; // to be borrowed to usdc_strategy_1
            let deposited_val = 0;
            let borrowed_val = 0_750000000;
            let usdc_strategy_id = usdc_strategy.vault_access_id();
            let usdc_strategy_1_id = usdc_strategy_1.vault_access_id();
            let usdt_strategy_id = usdt_strategy.vault_access_id();
            let now = timestamp_sec(&clock);
            // USDC
            multi_asset_vault.assert_vault_info<WHUSDCE, SLP>(free_balance, 0, 0, 0, 0, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.time_locked_profit<WHUSDCE, SLP>().assert_time_locked_balance_info<WHUSDCE>(0, now, 0, 0, 0, now);
                // usdc_strategy
            multi_asset_vault.assert_vault_strategy_state<WHUSDCE, SLP>(usdc_strategy_id, borrowed_val, 7500, option::none());
            let scoin_val = 0_750000000;
            let underlying_value = borrowed_val;
            usdc_strategy.assert_strategy_info(scoin_val, underlying_value, 0);
                // usdc_strategy_1
            let borrowed_val = 0;
            multi_asset_vault.assert_vault_strategy_state<WHUSDCE, SLP>(usdc_strategy_1_id, borrowed_val, 2500, option::none());
            let scoin_val = 0;
            let underlying_value = borrowed_val;
            usdc_strategy_1.assert_strategy_info(scoin_val, underlying_value, 0);
            // USDT
            let borrowed_val = math::pow(10,9);
            let scoin_val = math::pow(10, 9);
            multi_asset_vault.assert_vault_info<WHUSDTE, SLP>(0, 0, 0, 0, 0, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDTE, SLP>(usdt_strategy_id, borrowed_val, 10000, option::none());
            multi_asset_vault.time_locked_profit<WHUSDTE, SLP>().assert_time_locked_balance_info<WHUSDTE>(0, now, 0, 0, 0, now);
            usdt_strategy.assert_strategy_info(scoin_val, scoin_val, 0);

            test::return_shared(multi_asset_vault);
            test::return_shared(usdc_strategy_1);
            test::return_shared(usdc_strategy);
            test::return_shared(usdt_strategy);
            test::return_to_sender(s, admin_cap);
        };

        next_tx(s,a);{
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let admin_cap = test::take_from_sender<AdminCap<SLP>>(s);

            let mut usdc_strategy = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let mut usdc_strategy_1 = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let mut usdt_strategy = test::take_shared<MockStrategy<WHUSDTE>>(s);

            // >> USDC ( rebalance usdc_strategy_1 )
            let profit = balance::zero();
            mock_strategy::deposit_external_profits(&admin_cap, &mut usdc_strategy_1, &mut multi_asset_vault, profit, &clock);
            let usdc_rebalance_amounts = multi_asset_vault.calc_rebalance_amounts_by_asset<WHUSDCE, SLP>(&clock);
            mock_strategy::rebalance(&mut usdc_strategy_1, &admin_cap, &mut multi_asset_vault, &usdc_rebalance_amounts);

            // validation
            let free_balance = 0;
            let deposited_val = 0;
            let borrowed_val = 0_750000000;
            let usdc_strategy_id = usdc_strategy.vault_access_id();
            let usdc_strategy_1_id = usdc_strategy_1.vault_access_id();
            let usdt_strategy_id = usdt_strategy.vault_access_id();
            let now = timestamp_sec(&clock);
            // USDC
            multi_asset_vault.assert_vault_info<WHUSDCE, SLP>(free_balance, 0, 0, 0, 0, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.time_locked_profit<WHUSDCE, SLP>().assert_time_locked_balance_info<WHUSDCE>(0, now, 0, 0, 0, now);
                // usdc_strategy
            multi_asset_vault.assert_vault_strategy_state<WHUSDCE, SLP>(usdc_strategy_id, borrowed_val, 7500, option::none());
            let scoin_val = 0_750000000;
            let underlying_value = borrowed_val;
            usdc_strategy.assert_strategy_info(scoin_val, underlying_value, 0);
                // usdc_strategy_1
            let borrowed_val = 0_250000000;
            multi_asset_vault.assert_vault_strategy_state<WHUSDCE, SLP>(usdc_strategy_1_id, borrowed_val, 2500, option::none());
            let scoin_val = 0_250000000;
            let underlying_value = borrowed_val;
            usdc_strategy_1.assert_strategy_info(scoin_val, underlying_value, 0);
            // USDT
            let borrowed_val = math::pow(10,9);
            let scoin_val = math::pow(10, 9);
            multi_asset_vault.assert_vault_info<WHUSDTE, SLP>(0, 0, 0, 0, 0, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDTE, SLP>(usdt_strategy_id, borrowed_val, 10000, option::none());
            multi_asset_vault.time_locked_profit<WHUSDTE, SLP>().assert_time_locked_balance_info<WHUSDTE>(0, now, 0, 0, 0, now);
            usdt_strategy.assert_strategy_info(scoin_val, scoin_val, 0);

            test::return_shared(multi_asset_vault);
            test::return_shared(usdc_strategy_1);
            test::return_shared(usdc_strategy);
            test::return_shared(usdt_strategy);
            test::return_to_sender(s, admin_cap);
        };

        (scenario, clock)
    }

    #[test] 
    public fun test_can_deposit_after_max_borrow_constraint():(Scenario, Clock){
        let (mut scenario, clock) = start_with_strategy_with_max_borrow_constraint();
        let s = &mut scenario;
        let (a, _, _) = people();

        // deposit asset to strategies
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
                // assert!(required_deposit == deposit_usdc_value, 404);
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
            
            let free_balance = math::pow(10, 9)/2 + deposit_usdc_value;
            // >> USDC
            multi_asset_vault.assert_vault_info<WHUSDCE, SLP>(free_balance, 0, 0, 0, 0, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            // >> USDT
            multi_asset_vault.assert_vault_info<WHUSDTE, SLP>(free_balance, 0, 0, 0, 0, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());

            test::return_shared(multi_asset_vault);
        };


        // rebalance doesnt occurs external borrowed_amt
        next_tx(s,a);{
            // repaid the borrowed balance back to free_balance
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let admin_cap = test::take_from_sender<AdminCap<SLP>>(s);
            let mut usdc_strategy = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let mut usdt_strategy = test::take_shared<MockStrategy<WHUSDTE>>(s);
            let usdc_strategy_id = usdc_strategy.vault_access_id();
            let usdt_strategy_id = usdt_strategy.vault_access_id();

            // >> USDC
            usdc_strategy.skim_base_profits(&admin_cap);
            let profit = balance::zero();
            mock_strategy::deposit_external_profits(&admin_cap, &mut usdc_strategy, &mut multi_asset_vault, profit, &clock);
            let usdc_rebalance_amounts = multi_asset_vault.calc_rebalance_amounts_by_asset<WHUSDCE, SLP>(&clock);
            mock_strategy::rebalance(&mut usdc_strategy, &admin_cap, &mut multi_asset_vault, &usdc_rebalance_amounts);
            // >> USDT
            usdt_strategy.skim_base_profits(&admin_cap);
            let profit = balance::zero();
            mock_strategy::deposit_external_profits(&admin_cap, &mut usdt_strategy, &mut multi_asset_vault, profit, &clock);
            let usdt_rebalance_amounts = multi_asset_vault.calc_rebalance_amounts_by_asset<WHUSDTE, SLP>(&clock);
            mock_strategy::rebalance(&mut usdt_strategy, &admin_cap, &mut multi_asset_vault, &usdt_rebalance_amounts);

            // validation ( Move all the collected rewards to locked_balance )
            let now = timestamp_sec(&clock);
            let collected_performance_fee = 0;
            // strategies
            let free_balance = math::pow(10, 9)/2 + math::pow(10, 9);
            let returned_val = math::pow(10, 9) / 2;
            let borrowed_val = math::pow(10, 9) - returned_val;
            // TLB
            let locked_balance = 0;
            let unlock_per_second = math::divide_and_round_up(locked_balance, DEFAULT_PROFIT_UNLOCK_DURATION_SEC);
            let unlock_start_ts_sec = now;
            let unlocked_balance = 0;
            let final_unlock_ts_sec = if(unlock_per_second == 0) 0 else unlock_start_ts_sec + locked_balance/unlock_per_second;
            // >> USDC
            multi_asset_vault.assert_vault_info<WHUSDCE, SLP>(free_balance, locked_balance, 0, unlock_per_second, collected_performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDCE, SLP>(usdc_strategy_id, borrowed_val, 10000, option::some(borrowed_val));
            multi_asset_vault.time_locked_profit<WHUSDCE, SLP>().assert_time_locked_balance_info<WHUSDCE>(locked_balance, now, unlock_per_second, 0, final_unlock_ts_sec, now);
            // >> USDT
            multi_asset_vault.assert_vault_info<WHUSDTE, SLP>(free_balance, locked_balance, 0, unlock_per_second, collected_performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDTE, SLP>(usdt_strategy_id, borrowed_val, 10000, option::some(borrowed_val));
            multi_asset_vault.time_locked_profit<WHUSDTE, SLP>().assert_time_locked_balance_info<WHUSDTE>(locked_balance, now, unlock_per_second, 0, final_unlock_ts_sec, now);

            test::return_shared(multi_asset_vault);
            test::return_shared(usdc_strategy);
            test::return_shared(usdt_strategy);
            test::return_to_sender(s, admin_cap);
        };

        // remove max_borrow
        next_tx(s,a);{ // set the max_borrow
            let admin_cap = test::take_from_sender<AdminCap<SLP>>(s);
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let usdc_strategy = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let usdt_strategy = test::take_shared<MockStrategy<WHUSDTE>>(s);
            let usdc_strategy_id = usdc_strategy.vault_access_id();
            let usdt_strategy_id = usdt_strategy.vault_access_id();

            let max_borrow = math::pow(10, 9) /2; // take the half of borrowed amt back
            mav::set_strategy_max_borrow_by_asset<WHUSDCE, SLP>(&admin_cap, &mut multi_asset_vault, usdc_strategy_id, option::none());
            mav::set_strategy_max_borrow_by_asset<WHUSDTE, SLP>(&admin_cap, &mut multi_asset_vault, usdt_strategy_id, option::none());

            test::return_shared(multi_asset_vault);
            test::return_shared(usdc_strategy);
            test::return_shared(usdt_strategy);
            test::return_to_sender(s, admin_cap);
        };


        // successfully borrow after update max_borrow
        // rebalance doesnt occurs external borrowed_amt
        next_tx(s,a);{
            // repaid the borrowed balance back to free_balance
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let admin_cap = test::take_from_sender<AdminCap<SLP>>(s);
            let mut usdc_strategy = test::take_shared<MockStrategy<WHUSDCE>>(s);
            let mut usdt_strategy = test::take_shared<MockStrategy<WHUSDTE>>(s);
            let usdc_strategy_id = usdc_strategy.vault_access_id();
            let usdt_strategy_id = usdt_strategy.vault_access_id();

            // >> USDC
            usdc_strategy.skim_base_profits(&admin_cap);
            let profit = balance::zero();
            mock_strategy::deposit_external_profits(&admin_cap, &mut usdc_strategy, &mut multi_asset_vault, profit, &clock);
            let usdc_rebalance_amounts = multi_asset_vault.calc_rebalance_amounts_by_asset<WHUSDCE, SLP>(&clock);
            mock_strategy::rebalance(&mut usdc_strategy, &admin_cap, &mut multi_asset_vault, &usdc_rebalance_amounts);
            // >> USDT
            usdt_strategy.skim_base_profits(&admin_cap);
            let profit = balance::zero();
            mock_strategy::deposit_external_profits(&admin_cap, &mut usdt_strategy, &mut multi_asset_vault, profit, &clock);
            let usdt_rebalance_amounts = multi_asset_vault.calc_rebalance_amounts_by_asset<WHUSDTE, SLP>(&clock);
            mock_strategy::rebalance(&mut usdt_strategy, &admin_cap, &mut multi_asset_vault, &usdt_rebalance_amounts);

            // validation ( Move all the collected rewards to locked_balance )
            let now = timestamp_sec(&clock);
            let collected_performance_fee = 0;
            // strategies
            let free_balance = 0;
            let returned_val = math::pow(10, 9) / 2;
            let borrowed_val = 2 * math::pow(10, 9);
            // TLB
            let locked_balance = 0;
            let unlock_per_second = math::divide_and_round_up(locked_balance, DEFAULT_PROFIT_UNLOCK_DURATION_SEC);
            let unlock_start_ts_sec = now;
            let unlocked_balance = 0;
            let final_unlock_ts_sec = if(unlock_per_second == 0) 0 else unlock_start_ts_sec + locked_balance/unlock_per_second;
            // >> USDC
            multi_asset_vault.assert_vault_info<WHUSDCE, SLP>(free_balance, locked_balance, 0, unlock_per_second, collected_performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDCE, SLP>(usdc_strategy_id, borrowed_val, 10000, option::none());
            multi_asset_vault.time_locked_profit<WHUSDCE, SLP>().assert_time_locked_balance_info<WHUSDCE>(locked_balance, now, unlock_per_second, 0, final_unlock_ts_sec, now);
            // >> USDT
            multi_asset_vault.assert_vault_info<WHUSDTE, SLP>(free_balance, locked_balance, 0, unlock_per_second, collected_performance_fee, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            multi_asset_vault.assert_vault_strategy_state<WHUSDTE, SLP>(usdt_strategy_id, borrowed_val, 10000, option::none());
            multi_asset_vault.time_locked_profit<WHUSDTE, SLP>().assert_time_locked_balance_info<WHUSDTE>(locked_balance, now, unlock_per_second, 0, final_unlock_ts_sec, now);

            test::return_shared(multi_asset_vault);
            test::return_shared(usdc_strategy);
            test::return_shared(usdt_strategy);
            test::return_to_sender(s, admin_cap);
        };

        (scenario, clock)
    }

}
