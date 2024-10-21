#[test_only]
#[allow(unused)]
module vault::multi_vault_deposit_test{
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
        start,
        start_with_3_strategies
    };

    const START_TIME: u64 = 1_000_000_000;
    const DEFAULT_PROFIT_UNLOCK_DURATION_SEC: u64 = 60 * 60; // 1 hour

    fun people():(address, address, address){
        (@0xA, @0xB, @0xC)
    }

    #[test] 
    public fun test_deposit():(Scenario, Clock){
        let (mut scenario, clock) = start();
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
            
            // >> USDC
            multi_asset_vault.assert_vault_info<WHUSDCE, SLP>(deposit_usdc_value, 0, 0, 0, 0, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            // >> USDT
            multi_asset_vault.assert_vault_info<WHUSDTE, SLP>(deposit_usdc_value, 0, 0, 0, 0, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());

            test::return_shared(multi_asset_vault);
        };

        (scenario, clock)
    }

    #[test, expected_failure(abort_code = vault::multi_asset_vault::ERR_UNFULLFILLED_ASSET)]
    fun test_deposit_missing_deposit_type(){
        let (mut scenario, clock) = start();
        let s = &mut scenario;
        let (a, _, _) = people();

        // deposit asset to strategies
        let deposit_usdc_value = math::pow(10, 9);
        next_tx(s,a);{
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);

            let expected_yt = multi_asset_vault.get_expected_yt_by_given_deposit<WHUSDCE,SLP>(deposit_usdc_value, &clock);
            let mut ticket = multi_asset_vault.prepare_deposit_ticket(expected_yt);

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

        clock.destroy_for_testing();
        scenario.end();
    }

    #[test, expected_failure(abort_code = vault::multi_asset_vault::ERR_INSUFFICIENT_DEPOSIT)]
    fun test_deposit_insufficient_deposit(){
        let (mut scenario, clock) = start();
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
                assert!(required_deposit == deposit_usdc_value, 404);
                let surplus = multi_asset_vault.deposit_by_asset<WHUSDTE, SLP>(create<WHUSDTE>(required_deposit / 2), &mut ticket, &clock);
                assert!(destroy(surplus) == 0, 404);
            };

            let yt_bal = multi_asset_vault.settle_deposit_ticket(ticket);
            assert!(destroy(yt_bal) == deposit_usdc_value, 404);

            test::return_shared(multi_asset_vault);
        };

        clock.destroy_for_testing();
        scenario.end();
    }

    #[test]
    fun test_deposit_with_tvl_cap():(Scenario, Clock){
        let (mut scenario, clock) = start();
        let s = &mut scenario;
        let (a, _, _) = people();


        let tvl = math::pow(10, 10);
        // set TVL cap
        next_tx(s,a);{
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let admin_cap = test::take_from_sender<AdminCap<SLP>>(s);

            // >> USDC
            mav::set_tvl_cap_by_asset<WHUSDCE, SLP>(&admin_cap, &mut multi_asset_vault, option::some(tvl));
            // >> USDT
            mav::set_tvl_cap_by_asset<WHUSDTE, SLP>(&admin_cap, &mut multi_asset_vault, option::some(tvl));
            
            test::return_shared(multi_asset_vault);
            test::return_to_sender(s, admin_cap);
        };

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
            
            // >> USDC
            multi_asset_vault.assert_vault_info<WHUSDCE, SLP>(deposit_usdc_value, 0, 0, 0, 0, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::some(tvl));

            // >> USDT
            multi_asset_vault.assert_vault_info<WHUSDTE, SLP>(deposit_usdc_value, 0, 0, 0, 0, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::some(tvl));

            test::return_shared(multi_asset_vault);
        };

        (scenario, clock)
    }

    #[test, expected_failure(abort_code = vault::multi_asset_vault::ERR_EXCEED_TVL_CAP)]
    fun test_deposit_over_tvl_cap():(Scenario, Clock){
        let (mut scenario, clock) = start();
        let s = &mut scenario;
        let (a, _, _) = people();


        // set TVL cap
        next_tx(s,a);{
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let admin_cap = test::take_from_sender<AdminCap<SLP>>(s);

            // >> USDC
            mav::set_tvl_cap_by_asset<WHUSDCE, SLP>(&admin_cap, &mut multi_asset_vault, option::some(1000));
            // >> USDT
            mav::set_tvl_cap_by_asset<WHUSDTE, SLP>(&admin_cap, &mut multi_asset_vault, option::some(1000));
            
            test::return_shared(multi_asset_vault);
            test::return_to_sender(s, admin_cap);
        };

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
            
            // >> USDC
            multi_asset_vault.assert_vault_info<WHUSDCE, SLP>(deposit_usdc_value, 0, 0, 0, 0, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());

            // >> USDT
            multi_asset_vault.assert_vault_info<WHUSDTE, SLP>(deposit_usdc_value, 0, 0, 0, 0, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());

            test::return_shared(multi_asset_vault);
        };

        (scenario, clock)
    }

    #[test] 
    public fun test_deposit_with_identical_borrowed_assets_strategies():(Scenario, Clock){
        let (mut scenario, clock) = start_with_3_strategies();
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
            
            // >> USDC
            multi_asset_vault.assert_vault_info<WHUSDCE, SLP>(deposit_usdc_value, 0, 0, 0, 0, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());
            // >> USDT
            multi_asset_vault.assert_vault_info<WHUSDTE, SLP>(deposit_usdc_value, 0, 0, 0, 0, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());

            test::return_shared(multi_asset_vault);
        };

        (scenario, clock)
    }

}
