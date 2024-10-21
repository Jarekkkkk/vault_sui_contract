#[test_only]
#[allow(unused)]
module vault::main_test {
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

    const START_TIME: u64 = 1_000_000_000;
    const DEFAULT_PROFIT_UNLOCK_DURATION_SEC: u64 = 60 * 60; // 1 hour

    // utils func
    fun people():(address, address, address){
        (@0xA, @0xB, @0xC)
    }
    public fun dummy_address():address{
        @0x00000000000000000000000000000000
    }
    public fun mock_swap<X, Y>(
        coin: Coin<X>,
        output_amt: u64,
        ctx: &mut TxContext
    ):Coin<Y>{
        burn(coin);
        mint(output_amt, ctx)
    }

    public fun sui_1(): u64 { math::pow(10, 9) }
    public fun sui_1K(): u64 { math::pow(10, 12) }
    public fun sui_100K(): u64 { math::pow(10, 14) }
    public fun sui_1M(): u64 { math::pow(10, 15) }
    public fun sui_100M(): u64 { math::pow(10, 17) }
    public fun sui_1B(): u64 { math::pow(10, 18) }
    public fun sui_10B(): u64 { math::pow(10, 19) }


    fun setup():(Scenario, Clock){
        let (a, _, _) = people();

        let mut scenario = test::begin(@0xA);
        let s = &mut scenario;
        let mut clock = clock::create_for_testing(ctx(s));

        clock::set_for_testing(&mut clock, START_TIME); 
        tx_context::increment_epoch_timestamp(ctx(s), START_TIME);

        // publishd SLP contract and intialize the mutli-asset vault instance
        next_tx(s, a);{
            // publish the coin pkg and claim treasury_cap
            let treasury_cap = slp::mock_create_treasury(ctx(s));
            // consume the treasury_cap and acquire admin_cap & vault
            let (cap, vault) = mav::new(treasury_cap, ctx(s));
            
            transfer::public_transfer(cap, a);
            transfer::public_share_object(vault);
        };

        (scenario, clock)
    }

    // ===== Utils ======

    public fun add_asset<T>(
        s: &mut Scenario
    ){
        let (a, _, _) = people();
        next_tx(s,a);{
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let admin_cap = test::take_from_sender<AdminCap<SLP>>(s);

            // --> register USDC type
            multi_asset_vault.add_vault_supported_aaset<T, SLP>(&admin_cap);
            // validation
            multi_asset_vault.assert_vault_registered_asset<T, SLP>();
            multi_asset_vault.assert_vault_info<T, SLP>(0, 0, 0, 0, 0, false, DEFAULT_PROFIT_UNLOCK_DURATION_SEC, option::none());


            test::return_shared(multi_asset_vault);
            test::return_to_sender(s, admin_cap);
        };

    }

    public fun add_strategy<T>(
        s: &mut Scenario
    ):ID{
        let (a, _, _) = people();
        next_tx(s,a);
        let id = {
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);
            let admin_cap = test::take_from_sender<AdminCap<SLP>>(s);

            let mut str = mock_strategy::new<T>(&admin_cap, ctx(s));
            mock_strategy::join_vault<T>(&admin_cap, &mut multi_asset_vault, &mut str, ctx(s));
            let vault_access_id = str.vault_access_id();

            transfer::public_share_object(str);

            // validation
            multi_asset_vault.assert_vault_strategy_exist(vault_access_id);
            multi_asset_vault.assert_vault_strategy_state<T, SLP>(vault_access_id, 0, 0, option::none());

            test::return_shared(multi_asset_vault);
            test::return_to_sender(s, admin_cap);

            vault_access_id
        };

        id
    }
    
    public fun deposit_to_strategy(
        s: &mut Scenario,
        deposit_usdc_value: u64,
        clock: &Clock
    ){
        let (a, _, _) = people();

        next_tx(s,a);{
            let mut multi_asset_vault = test::take_shared<MultiAssetVault<SLP>>(s);

            let expected_yt = multi_asset_vault.get_expected_yt_by_given_deposit<WHUSDCE,SLP>(deposit_usdc_value, clock);
            let mut ticket = multi_asset_vault.prepare_deposit_ticket(expected_yt);

            { // USDC
                let surplus = multi_asset_vault.deposit_by_asset<WHUSDCE, SLP>(create<WHUSDCE>(deposit_usdc_value), &mut ticket, clock);
                assert!(destroy(surplus) == 0, 404);
            };
            { // USDT
                let required_deposit = multi_asset_vault.get_required_deposit_by_given_yt<WHUSDTE, SLP>(expected_yt, clock);
                assert!(required_deposit == deposit_usdc_value, 404);
                let surplus = multi_asset_vault.deposit_by_asset<WHUSDTE, SLP>(create<WHUSDTE>(required_deposit), &mut ticket, clock);
                assert!(destroy(surplus) == 0, 404);
            };

            let yt_bal = multi_asset_vault.settle_deposit_ticket(ticket);
            assert!(destroy(yt_bal) == deposit_usdc_value, 404);

            test::return_shared(multi_asset_vault);
        };
    }

    // ===== Pre-setup Transaction Flow ======
    public fun start():(Scenario, Clock){
        let (mut scenario, clock) = setup();

        let mut strategies = vector[];

        // asset registeration
        add_asset<WHUSDCE>(&mut scenario);
        add_asset<WHUSDTE>(&mut scenario);


        // strategies registeration
        // >> USDC
        let usdc_strategy_id = add_strategy<WHUSDCE>(&mut scenario);
        strategies.push_back(usdc_strategy_id);
        // >> USDT
        let usdt_strategy_id = add_strategy<WHUSDTE>(&mut scenario);
        strategies.push_back(usdt_strategy_id);

        
        (scenario, clock)
    }

    public fun start_with_3_strategies():(Scenario, Clock){
        let (mut scenario, clock) = setup();

        let mut strategies = vector[];

        // asset registeration
        add_asset<WHUSDCE>(&mut scenario);
        add_asset<WHUSDTE>(&mut scenario);


        // strategies registeration
        // >> USDC
        let usdc_strategy_id = add_strategy<WHUSDCE>(&mut scenario);
        strategies.push_back(usdc_strategy_id);
        let usdc_strategy_id = add_strategy<WHUSDCE>(&mut scenario);
        strategies.push_back(usdc_strategy_id);
        // >> USDT
        let usdt_strategy_id = add_strategy<WHUSDTE>(&mut scenario);
        strategies.push_back(usdt_strategy_id);

        
        (scenario, clock)
    }

}
