module vault::multi_asset_vault {
    /* ================= imports ================= */
    use std::type_name::{Self, TypeName};
    use std::vector as vec;

    use sui::bag::{Self, Bag};
    use sui::coin::{Self, TreasuryCap};
    use sui::balance::{Self, Balance};
    use sui::vec_map::{Self, VecMap};
    use sui::vec_set::{Self, VecSet};
    use sui::clock::Clock;
    use sui::math;

    use vault::vault::module_version;
    use vault::utils::{mul_div, timestamp_sec};
    use vault::event;
    use vault::time_locked_balance::{Self as tlb, TimeLockedBalance};


    /* ================= errors ================= */
    const ERR_WRONG_VERSION: u64 = 001;

    const ERR_TREASURY_SUPPLY_POSITIVE: u64 = 101;
    const ERR_INVALID_BPS: u64 = 102;
    const ERR_INVALID_WEIGHTS: u64 = 103;
    const ERR_INVARIANT_VIOLATION: u64 = 106;
    const ERR_NOT_UPGRADE: u64 = 107;
    const ERR_WITHDRAW_TICKET_ISSUED: u64 = 108;
    const ERR_EXCEED_TVL_CAP: u64 = 109;
    const ERR_INSUFFICIENT_DEPOSIT: u64 = 110;
    const ERR_UNFULLFILLED_ASSET: u64 = 112;
    const ERR_STRATEGY_ALREADY_WITHDRAWN: u64 = 113;
    const ERR_ZERO_AMT: u64 = 114;
    const ERR_STRATEGY_NOT_WITHDRAWN: u64 = 115;
    const ERR_UNREDEEMED_ASSET: u64 = 116;
    const ERR_INVALID_VAULT_ACCESS: u64 = 117;
    const ERR_ASSET_ALREADY_WITHDREW: u64 = 118;
    const ERR_WITHDRAW_TICKET_NOT_SETUP: u64 = 119;
    const ERR_UNMATCHED_LENGTH_OF_IDS_AND_WEIGHTS: u64 = 120;
    const ERR_WEIGHT_BPS_NOT_FULLY_ASSIGNED: u64 = 121;

    /* ================= constants ================= */
    const MODULE_VERSION: u64 = 1; 
    const BPS_IN_100_PCT: u64 = 10000;
    const DEFAULT_PROFIT_UNLOCK_DURATION_SEC: u64 = 60 * 60; // 1 hour
    const DEFAULT_PERFORMANCE_FEE: u64 = 1000; // 10%


    /* ================= Structs ================= */

    /* ================= AdminCap ================= */

    /// There can only ever be one `AdminCap` for a `Vault`
    public struct AdminCap<phantom YT> has key, store {
        id: UID,
    }
    /* ================= VaultAccess ================= */

    /// Strategies store this and it gives them access to deposit and withdraw
    /// from the vault
    public struct VaultAccess has store {
        id: UID,
    }

    public fun vault_access_id(access: &VaultAccess): ID {
        object::uid_to_inner(&access.id)
    }

    public struct MultiAssetVault<phantom YT> has key, store{
        id: UID,
        version: u64,
        /// balance that's not allocated to any strategy
        free_balances: Bag,
        /// slowly distribute profits over time to avoid sandwitch attacks on rebalance
        time_locked_profits: Bag,
        /// duration of profit unlock in seconds
        profit_unlock_duration_sec: u64,
        /// treasury of the vault's yield-bearing token
        lp_treasury: TreasuryCap<YT>,
        /// strategies
        strategies: VecMap<ID, MultiAssetStrategyState>,
        /// performance fee in basis points (taken from all profits)
        performance_fee_bps: u64,
        /// performance fee balance by underlying asset
        performance_fee_balances: Bag,
        /// priority order for withdrawing from strategies
        strategy_withdraw_priority_order: vector<ID>,
        /// only one withdraw ticket can be active at a time
        withdraw_ticket_issued: bool,
        /// respetive assets are disabled above this threshold, we use the keys to check all the supported asset types
        tvl_caps: VecMap<TypeName, Option<u64>>
    }

    /* ================= MultiAssetStrategyState ================= */
    public struct MultiAssetStrategyState has store {
        borrowed_infos: VecMap<TypeName, BorrowedInfo>
    }
    public fun borrowed_infos_contains_by_asset<T>(multi_asset_strategy_state: &MultiAssetStrategyState): bool{
        multi_asset_strategy_state.borrowed_infos.contains(&type_name::get<T>())
    }
    public fun borrowed_info<T>(multi_asset_strategy_state: &MultiAssetStrategyState):&BorrowedInfo{
        let idx = multi_asset_strategy_state.borrowed_infos.get_idx(&type_name::get<T>());
        let (_, info) = multi_asset_strategy_state.borrowed_infos.get_entry_by_idx(idx);
        info
    }
    fun borrowed_info_mut<T>(multi_asset_strategy_state: &mut MultiAssetStrategyState):&mut BorrowedInfo{
        multi_asset_strategy_state.borrowed_infos.get_mut(&type_name::get<T>())
    }

    public struct BorrowedInfo has store{
        borrowed: u64,
        max_borrow: Option<u64>,
        target_alloc_weight_bps: u64,
    }
    public fun borrowed(borrowed_info: &BorrowedInfo):u64{
        borrowed_info.borrowed
    }
    public fun max_borrow(borrowed_info: &BorrowedInfo):Option<u64>{
        borrowed_info.max_borrow
    }
    public fun target_alloc_weight_bps(borrowed_info: &BorrowedInfo): u64{
        borrowed_info.target_alloc_weight_bps
    }
    public fun get_borrowed_info_by_asset<T, YT>(
        self: &MultiAssetVault<YT>,
        vault_id: ID
    ):(u64, Option<u64>, u64){
        let borrowed_info = vec_map::get(&self.strategies, &vault_id).borrowed_info<T>();
        (borrowed_info.borrowed, borrowed_info.max_borrow, borrowed_info.target_alloc_weight_bps)
    }

    fun update_target_alloc_weight_bps(borrowed_info: &mut BorrowedInfo, bps: u64){
        borrowed_info.target_alloc_weight_bps = bps;
    }


    /* ================= StrategyRemovalTicket ================= */
    public struct MultiAssetStrategyRemovalTicket<phantom YT> {
        access: VaultAccess,
        balance_types: VecSet<TypeName>,
        returned_balances: Bag,
    }
    public fun new_multi_asset_strategy_removal_ticket<YT>(
        _: &AdminCap<YT>,
        access: VaultAccess,
        ctx: &mut TxContext
    ): MultiAssetStrategyRemovalTicket<YT>{
        MultiAssetStrategyRemovalTicket<YT>{
            access,
            balance_types: vec_set::empty(),
            returned_balances: bag::new(ctx)
        }
    }
    /// Called by integrated Strategy to return underlying Balance<T>
    public fun add_strategy_removal_asset_by_asset<T, YT>(
        removal_ticket: &mut MultiAssetStrategyRemovalTicket<YT>, 
        returned_balance: Balance<T>
    ){
        let type_name = type_name::get<T>();
        // abort if already exists
        removal_ticket.balance_types.insert(type_name);
        removal_ticket.returned_balances.add(type_name, returned_balance);
    }

    fun remove_strategy_removal_asset_by_asset<T, YT>(
        removal_ticket: &mut MultiAssetStrategyRemovalTicket<YT>
    ):Balance<T>{
        let type_name = type_name::get<T>();
        removal_ticket.returned_balances.remove(type_name)
    }

    /* ================= DepositTicket ================= */
    public struct DepositTicket<phantom YT>{
        deposited_types: VecSet<TypeName>,
        minted_yt_amt: u64
    }

    /* ================= WithdrawTicket ================= */
    public struct StrategyWithdrawInfo<phantom T> has store {
        to_withdraw: u64,
        withdrawn_balance: Balance<T>,
        has_withdrawn: bool,
    }

    public struct WithdrawInfo<phantom T> has store{
        to_withdraw_from_free_balance: u64,
        strategy_infos: VecMap<ID, StrategyWithdrawInfo<T>>,
    }

    public struct WithdrawTicket<phantom YT> {
        /// Mapping 'TypeName' to 'WithdrawInfo<T>'
        withdraw_infos: Bag,
        claimed: VecSet<TypeName>,
        lp_to_burn: Balance<YT>,
    }

    public fun withdraw_info<T, YT>(ticket: &WithdrawTicket<YT>):&WithdrawInfo<T>{
        let ticket = ticket.withdraw_infos.borrow(type_name::get<T>());
        ticket
    } 
    public fun withdraw_infos_contains<T, YT>(ticket: &WithdrawTicket<YT>):bool{
        ticket.withdraw_infos.contains(type_name::get<T>())
    } 

    public fun strategy_withdraw_info<T, YT>(
        ticket: &WithdrawTicket<YT>,
        access_id: ID,
    ):&StrategyWithdrawInfo<T>{
        let withdraw_info = ticket.withdraw_info<T, YT>();
        let idx = withdraw_info.strategy_infos.get_idx(&access_id);

        let (_, v) = withdraw_info.strategy_infos.get_entry_by_idx(idx);
        v
    }

    fun withdraw_info_mut<T, YT>(ticket: &mut WithdrawTicket<YT>):&mut WithdrawInfo<T>{
        ticket.withdraw_infos.borrow_mut(type_name::get<T>())
    } 
    fun strategy_withdraw_info_mut<T, YT>(
        ticket: &mut WithdrawTicket<YT>,
        access_id: ID,
    ):&mut StrategyWithdrawInfo<T>{
        let withdraw_info = ticket.withdraw_info_mut<T, YT>();

        &mut withdraw_info.strategy_infos[&access_id]
    }
    fun update_to_withdraw_by_asset<T, YT>(
        ticket: &mut WithdrawTicket<YT>,
        access_id: ID,
        value: u64
    ){
        ticket.strategy_withdraw_info_mut<T, YT>(access_id).to_withdraw = value
    }
    // fun increase_to_withdraw_by_asset<T, YT>(
    //     ticket: &mut WithdrawTicket<YT>,
    //     access_id: ID,
    //     value: u64
    // ){
    //     let info = ticket.strategy_withdraw_info_mut<T, YT>(access_id);
    //     let to_withdraw = info.to_withdraw;
    //     ticket.strategy_withdraw_info_mut<T, YT>(access_id).to_withdraw = to_withdraw + value;
    // }


    public fun withdraw_ticket_to_withdraw<T, YT>(
        ticket: &WithdrawTicket<YT>,
        access_id: ID,
    ): u64{
        if(ticket.withdraw_infos_contains<T, YT>()){
            let info = strategy_withdraw_info<T, YT>(ticket, access_id);
            info.to_withdraw
        }else{
            0
        }
    }

    /* ================= RebalanceInfo ================= */

    public struct RebalanceInfo has store, copy, drop {
        /// The target amount the strategy should repay. The strategy shouldn't
        /// repay more than this amount.
        to_repay: u64,
        /// The target amount the strategy should borrow. There's no guarantee
        /// though that this amount is available in vault's free balance. The
        /// strategy shouldn't borrow more than this amount.
        can_borrow: u64,
    }

    // TODO: do we need to add Yt phantom type
    public struct RebalanceAmounts<phantom T> has copy, drop {
        inner: VecMap<ID, RebalanceInfo>,
    }

    public fun rebalance_amounts_get<T>(
        amounts: &RebalanceAmounts<T>, 
        access: &VaultAccess
    ): (u64, u64) {
        let strategy_id = access.vault_access_id();
        let amts = vec_map::get(&amounts.inner, &strategy_id);
        (amts.can_borrow, amts.to_repay)
    }

    /* ================= Method Aliases ================= */
    #[test_only]
    public use fun vault::multi_vault_test_utils::assert_vault_registered_asset as MultiAssetVault.assert_vault_registered_asset;
    #[test_only]
    public use fun vault::multi_vault_test_utils::assert_vault_info as MultiAssetVault.assert_vault_info;
    #[test_only]
    public use fun vault::multi_vault_test_utils::assert_vault_strategy_exist as MultiAssetVault.assert_vault_strategy_exist;
    #[test_only]
    public use fun vault::multi_vault_test_utils::assert_vault_strategy_state as MultiAssetVault.assert_vault_strategy_state;


    /* ================= public-view functions ================= */
    public fun free_balances_contains<T, YT>(self: &MultiAssetVault<YT>):bool{
        self.free_balances.contains(type_name::get<T>())
    }
    public fun free_balance<T, YT>(self: &MultiAssetVault<YT>):&Balance<T>{
        bag::borrow(&self.free_balances, type_name::get<T>())
    }
    public fun time_locked_profits_contains<T, YT>(self: &MultiAssetVault<YT>):bool{
        bag::contains(&self.time_locked_profits, type_name::get<T>())
    }
    public fun time_locked_profit<T, YT>(self: &MultiAssetVault<YT>):&TimeLockedBalance<T>{
        bag::borrow(&self.time_locked_profits, type_name::get<T>())
    }
    public fun performance_fee_balance<T, YT>(self: &MultiAssetVault<YT>):&Balance<T>{
        bag::borrow(&self.performance_fee_balances, type_name::get<T>())
    }
    // MultiAssetStrategyState
    public fun strategies<YT>(self: &MultiAssetVault<YT>): &VecMap<ID, MultiAssetStrategyState>{
        &self.strategies
    }
    public fun multi_asset_strategy_state<YT>(
        self: &MultiAssetVault<YT>, 
        strategy_id: &ID
    ): &MultiAssetStrategyState{
        // abort if not exist
        vec_map::get(&self.strategies, strategy_id)
    }
    public fun is_strategy_exist<YT>(
        self: &MultiAssetVault<YT>, 
        strategy_id: &ID
    ):bool{
        vec_map::contains(&self.strategies, strategy_id)
    }
    public fun strategy_withdraw_priority_order<YT>(self: &MultiAssetVault<YT>): vector<ID>{
        self.strategy_withdraw_priority_order
    }
    public fun withdraw_ticket_issued<YT>(self: &MultiAssetVault<YT>): bool{
        self.withdraw_ticket_issued
    }

    public fun tvl_caps_contains<T, YT>(self: &MultiAssetVault<YT>): bool{
        self.tvl_caps.contains(&type_name::get<T>())
    }
    public fun tvl_cap_by_asset<T, YT>(self: &MultiAssetVault<YT>): Option<u64>{
        *self.tvl_caps.get(&type_name::get<T>())
    }
    public fun profit_unlock_duration_sec<YT>(self: &MultiAssetVault<YT>): u64{
        self.profit_unlock_duration_sec
    }
    public fun performance_fee_bps<YT>(self: &MultiAssetVault<YT>): u64{
        self.performance_fee_bps
    }
    /// Additional free_balance & time_locked_profit info should be retrieved by input type <T>
    public fun vault_info_by_asset<T, YT>(self: &MultiAssetVault<YT>):(
        u64, u64, u64, u64, u64, bool, u64
    ){
        let free_balance = self.free_balance<T, YT>();
        let time_locked_profit = self.time_locked_profit<T, YT>();
        let performance_fee_balance = self.performance_fee_balance<T, YT>();
        (
            free_balance.value(),
            time_locked_profit.locked_balance().value(),
            time_locked_profit.unlocked_balance().value(),
            time_locked_profit.unlock_per_second(),
            performance_fee_balance.value(),
            self.withdraw_ticket_issued,
            self.profit_unlock_duration_sec
        )
    }
    public fun total_available_balance_by_asset<T, YT>(
        self: &MultiAssetVault<YT>,
        clock: &Clock
    ): u64 {
        let free_balance = self.free_balance<T, YT>();
        let time_locked_profit = self.time_locked_profit<T, YT>();

        let mut total: u64 = 0;
        total = total + free_balance.value();
        total = total + tlb::max_withdrawable(time_locked_profit, clock);
        
        let supported_strategy_ids = self.supported_strategies_by_asset<T, YT>();
        let (mut i, n) = (0, supported_strategy_ids.length());
        while (i < n) {
            let  strategy_id = supported_strategy_ids[i];
            let multi_asset_strategy_state = &self.strategies[&strategy_id];
            let borrowed_info = multi_asset_strategy_state.borrowed_info<T>();
            total = total + borrowed_info.borrowed();
            i = i + 1;
        };
        total
    }
    public fun supported_assets<YT>(self: &MultiAssetVault<YT>):vector<TypeName>{
        self.tvl_caps.keys()
    }
    public fun total_yt_supply<YT>(self: &MultiAssetVault<YT>): u64{
        self.lp_treasury.total_supply()
    }
    public fun get_output_yt_by_given_deposit<T, YT>(
        self: &MultiAssetVault<YT>,
        value: u64,
        clock: &Clock
    ):u64{
        let total_available_balance = self.total_available_balance_by_asset<T, YT>(clock);
        if (total_available_balance == 0) {
            value
        } else {
            mul_div(
                self.lp_treasury.total_supply(),
                value,
                total_available_balance
            )
        }
    }

    /// Calculate required amount of deposited assets by given amount of YT token
    public fun get_required_deposit_by_given_yt<T, YT>(
        self: &MultiAssetVault<YT>,
        yt_amt: u64,
        clock: &Clock
    ):u64{
        let total_available_balance = self.total_available_balance_by_asset<T, YT>(clock);
        if (total_available_balance == 0) {
            yt_amt
        } else {
            mul_div(
                yt_amt,
                total_available_balance,
                self.lp_treasury.total_supply(),
            )
        }
    }

    /// Calculate output YT amount by given deposit value
    public fun get_expected_yt_by_given_deposit<T, YT>(
        self: &MultiAssetVault<YT>,
        val: u64,
        clock: &Clock
    ):u64{
        let total_available_balance = self.total_available_balance_by_asset<T, YT>(clock);
        if (total_available_balance == 0) {
            val
        } else {
            mul_div(
                val,
                self.lp_treasury.total_supply(),
                total_available_balance,
            )
        }
    }

    /* ================= Public-Mutative Functions ================= */
    fun free_balance_mut<T, YT>(self: &mut MultiAssetVault<YT>):&mut Balance<T>{
        bag::borrow_mut(&mut self.free_balances, type_name::get<T>())
    }
    fun time_locked_profit_mut<T, YT>(self: &mut MultiAssetVault<YT>):&mut TimeLockedBalance<T>{
        bag::borrow_mut(&mut self.time_locked_profits, type_name::get<T>())
    }
    fun performance_fee_balance_mut<T, YT>(self: &mut MultiAssetVault<YT>):&mut Balance<T>{
        bag::borrow_mut(&mut self.performance_fee_balances, type_name::get<T>())
    }
    // fun strategies_mut<YT>(self: &mut MultiAssetVault<YT>): &mut VecMap<ID, MultiAssetStrategyState>{
    //     &mut self.strategies
    // }
    // fun multi_asset_strategy_state_mut<YT>(
    //     self: &mut MultiAssetVault<YT>, 
    //     strategy_id: &ID
    // ): &mut MultiAssetStrategyState{
    //     // abort if not exist
    //     vec_map::get_mut(&mut self.strategies, strategy_id)
    // }
    fun decrease_borrowed<T, YT>(
        self: &mut MultiAssetVault<YT>,
        vault_access_id: ID,
        value: u64
    ){
        let strategy = &mut self.strategies[&vault_access_id];
        let borrowed_info_mut = strategy.borrowed_info_mut<T>();
        borrowed_info_mut.borrowed = borrowed_info_mut.borrowed - value;
    }
    fun increase_borrowed<T, YT>(
        self: &mut MultiAssetVault<YT>,
        vault_access_id: ID,
        value: u64
    ){
        let strategy = &mut self.strategies[&vault_access_id];
        let borrowed_info_mut = strategy.borrowed_info_mut<T>();

        borrowed_info_mut.borrowed = borrowed_info_mut.borrowed + value;
    }

    /* ================= Admin Functions ================= */
    /// setup default value in `free_balances`, `time_locked_profits`, `tvl_caps` and `performance_fee_balance`
    public entry fun add_vault_supported_aaset<T, YT>(
        self: &mut MultiAssetVault<YT>,
        _: &AdminCap<YT>
    ){
        assert_version(self);
        // abort if already exists
        let asset_type = type_name::get<T>();
        self.free_balances.add(asset_type, balance::zero<T>());
        self.time_locked_profits.add(asset_type, tlb::create(balance::zero<T>(), 0, 0));
        self.performance_fee_balances.add(asset_type, balance::zero<T>());
        self.tvl_caps.insert(asset_type, option::none());
    }

    public entry fun remove_vault_supported_aaset<T, YT>(
        _: &AdminCap<YT>,
        self: &mut MultiAssetVault<YT>
    ){
        assert_version(self);
        // abort if already exists
        let asset_type = type_name::get<T>();
        let free_balance:Balance<T> = self.free_balances.remove(asset_type);
        free_balance.destroy_zero();

        let time_locked_balance:TimeLockedBalance<T> = self.time_locked_profits.remove(asset_type);
        time_locked_balance.destroy_empty();
    }

    entry fun set_tvl_cap_by_asset<T, YT>(
        _cap: &AdminCap<YT>, 
        self: &mut MultiAssetVault<YT>,
        tvl_cap: Option<u64>
    ) {
        assert_version(self);
        *self.tvl_caps.get_mut(&type_name::get<T>()) = tvl_cap;
    }

    entry fun set_profit_unlock_duration_sec<YT>(
        _cap: &AdminCap<YT>, 
        self: &mut MultiAssetVault<YT>,
        profit_unlock_duration_sec: u64
    ) {
        assert_version(self);
        self.profit_unlock_duration_sec = profit_unlock_duration_sec;
    }

    entry fun set_performance_fee_bps<YT>(
        _cap: &AdminCap<YT>, 
        self: &mut MultiAssetVault<YT>,
        performance_fee_bps: u64
    ) {
        assert_version(self);
        assert!(performance_fee_bps <= BPS_IN_100_PCT, ERR_INVALID_BPS);
        self.performance_fee_bps = performance_fee_bps;
    }       

    public fun withdraw_performance_fee<T, YT>(
        _cap: &AdminCap<YT>, 
        self: &mut MultiAssetVault<YT>,
        amount: u64
    ): Balance<T> {
        assert_version(self);

        self.performance_fee_balance_mut<T, YT>().split(amount)
    }

    public entry fun pull_unlocked_profits_to_free_balance_by_asset<T, YT>(
        _cap: &AdminCap<YT>, 
        self: &mut MultiAssetVault<YT>,
        clock: &Clock
    ) {
        assert_version(self);

        let pulled_profit = {
            tlb::withdraw_all(self.time_locked_profit_mut<T, YT>(), clock)
        };

        balance::join(self.free_balance_mut<T, YT>(),pulled_profit);
    }

    /// Add strategy to the Vault
    public fun add_strategy<YT>(
        _cap: &AdminCap<YT>, 
        self: &mut MultiAssetVault<YT>,
        ctx: &mut TxContext
    ): VaultAccess {
        assert_version(self);

        let access = VaultAccess{
            id: object::new(ctx)
        };
        let strategy_id = access.vault_access_id();

        vec_map::insert(
            &mut self.strategies,
            strategy_id,
            MultiAssetStrategyState{
                borrowed_infos: vec_map::empty(),
            }
        );
        vector::push_back(&mut self.strategy_withdraw_priority_order, strategy_id);
        access
    }

    public fun add_strategy_supported_asset<T, YT>(
        self: &mut MultiAssetVault<YT>,
        _: &AdminCap<YT>,
        access: &VaultAccess
    ){
        assert_version(self);

        let strategy_id = access.vault_access_id();

        let multi_asset_strategy_state = self.strategies.get_mut(&strategy_id);
         multi_asset_strategy_state.borrowed_infos.insert(type_name::get<T>(), BorrowedInfo{
            borrowed: 0,
            max_borrow: option::none(),
            target_alloc_weight_bps: 0
         });
    }

    entry fun set_strategy_max_borrow_by_asset<T, YT>(
        _cap: &AdminCap<YT>, 
        self: &mut MultiAssetVault<YT>,
        strategy_id: ID, 
        max_borrow: Option<u64>
    ) {
        assert_version(self);

        let multi_asset_strategy_state = vec_map::get_mut(&mut self.strategies, &strategy_id);
        let borrowed_info = multi_asset_strategy_state.borrowed_info_mut<T>();
        borrowed_info.max_borrow = max_borrow;
    }

    entry public fun set_strategy_target_alloc_weights_bps<T, YT>(
        _cap: &AdminCap<YT>, 
        self: &mut MultiAssetVault<YT>,
        ids: vector<ID>, 
        weights_bps: vector<u64>
    ) {
        assert_version(self);
        assert!(ids.length() == weights_bps.length(), ERR_UNMATCHED_LENGTH_OF_IDS_AND_WEIGHTS);
        let mut ids_seen = vec_set::empty<ID>();
        let mut total_bps = 0;

        let mut i = 0;
        let n = self.num_of_strategies_by_asset<T, YT>();

        assert!(n == ids.length(), ERR_WEIGHT_BPS_NOT_FULLY_ASSIGNED);
        while (i < n) {
            let id = *vector::borrow(&ids, i);
            let weight = *vector::borrow(&weights_bps, i);
            vec_set::insert(&mut ids_seen, id); // checks for duplicate ids
            total_bps = total_bps + weight;

            // should we update all the allocated points for all the assets
            let multi_asset_strategy_state = vec_map::get_mut(&mut self.strategies, &id);
            let borrowed_info_mut = multi_asset_strategy_state.borrowed_info_mut<T>();
            borrowed_info_mut.update_target_alloc_weight_bps(weight);

            i = i + 1;
        };

        assert!((ids.length() == 0 && total_bps == 0) || total_bps == BPS_IN_100_PCT, ERR_INVALID_WEIGHTS);
    }

    /// Remove the corresponding asset from vault and merged to free_balance
    /// Called by integrated strategy
    public fun remove_strategy_by_asset<T, YT>(
        cap: &AdminCap<YT>, 
        self: &mut MultiAssetVault<YT>,
        ticket: &mut MultiAssetStrategyRemovalTicket<YT>,
        ids_for_weights: vector<ID>, 
        weights_bps: vector<u64>,
        clock: &Clock
    ) {
        assert_version(self);

        // pop out the returned balance
        let mut returned_balance = ticket.remove_strategy_removal_asset_by_asset();

        let returned_value = balance::value(&returned_balance);

        let vault_id = ticket.access.vault_access_id();
        let borrowed_infos_mut = &mut self.strategies.get_mut(&vault_id).borrowed_infos;
        let (_, removed_borrowed_info) = borrowed_infos_mut.remove(&type_name::get<T>());
        let BorrowedInfo{
            borrowed,
            max_borrow: _,
            target_alloc_weight_bps: _
        } = removed_borrowed_info;

        // accrued profit
        if (returned_value > borrowed) {
            let profit = balance::split(
                &mut returned_balance,
                returned_value - borrowed
            );
            let time_locked_profit = self.time_locked_profit_mut<T, YT>();
            tlb::top_up(time_locked_profit, profit, clock);
        };
        balance::join(self.free_balance_mut<T, YT>(), returned_balance);

        // set new weights for corresponding asset type
        set_strategy_target_alloc_weights_bps<T, YT>(cap, self, ids_for_weights, weights_bps);
    }

    /// Consuem the `MultiAssetStrategyRemovalTicket` and drop all the related state of strategy
    /// To remove the strategy, make sure all the undelrying assets have been removed by calling `remove_strategy_supported_asset`
    public fun remove_strategy<YT>(
        self: &mut MultiAssetVault<YT>, 
        _: &AdminCap<YT>, 
        removal_ticket: MultiAssetStrategyRemovalTicket<YT>
    ){
        assert_version(self);

        let MultiAssetStrategyRemovalTicket<YT> { access, balance_types, returned_balances } = removal_ticket;
        check_removal_ticket_fulfilled(self, &access, &balance_types);
        returned_balances.destroy_empty();

        
        let VaultAccess{
            id: uid
        } = access;
        let id = uid.uid_to_inner();
        object::delete(uid);

        // remove from strategies and return balance
        let (_, state) = vec_map::remove(&mut self.strategies, &id);
        let MultiAssetStrategyState { borrowed_infos } = state;
        
        // abort if we didn't remove all the assets
        borrowed_infos.destroy_empty();
        
        // remove from withdraw priority order
        let (has, idx) = vector::index_of(&self.strategy_withdraw_priority_order, &id);
        assert!(has, ERR_INVARIANT_VIOLATION);
        vector::remove(&mut self.strategy_withdraw_priority_order, idx);
    }

    entry fun migrate<YT>(
        _cap: &AdminCap<YT>, 
        self: &mut MultiAssetVault<YT>
    ) {
        assert!(self.version < MODULE_VERSION, ERR_NOT_UPGRADE);
        self.version = MODULE_VERSION;
    }

    // /* ================= public functions ================= */

    // --- Create new vault ----
    /// Create new Vault
    public fun new<YT>(
        lp_treasury: TreasuryCap<YT>, 
        ctx: &mut TxContext
    ):(AdminCap<YT>, MultiAssetVault<YT>){
        assert!(coin::total_supply(&lp_treasury) == 0, ERR_TREASURY_SUPPLY_POSITIVE);
        let admin_cap = AdminCap<YT>{
            id: object::new(ctx)
        };
        // vault
        let vault = MultiAssetVault<YT> {
            id: object::new(ctx),
            version: MODULE_VERSION,
            free_balances: bag::new(ctx),
            time_locked_profits: bag::new(ctx),
            performance_fee_bps: DEFAULT_PERFORMANCE_FEE, // 10%
            lp_treasury, 
            strategies: vec_map::empty(),
            performance_fee_balances: bag::new(ctx),
            strategy_withdraw_priority_order: vector::empty(),
            withdraw_ticket_issued: false,
            profit_unlock_duration_sec: DEFAULT_PROFIT_UNLOCK_DURATION_SEC,
            tvl_caps: vec_map::empty()
        };

        (admin_cap, vault)
    }
    
    // -----> Deposit
    /// calling this method to query all the required amount of deposited assets
    public fun prepare_deposit_ticket<YT>(
        self: &mut MultiAssetVault<YT>,
        expected_lp: u64
    ):DepositTicket<YT>{
        assert_version(self);

        DepositTicket{
            deposited_types: vec_set::empty(),
            minted_yt_amt: expected_lp
        }
    }

    /// Deposit asset to vault and return surplus amount
    public fun deposit_by_asset<T, YT>(
        self: &mut MultiAssetVault<YT>, 
        mut balance: Balance<T>,
        deposit_ticket: &mut DepositTicket<YT>,
        clock: &Clock
    ):Balance<T>{
        assert_version(self);

        assert!(self.withdraw_ticket_issued == false, ERR_WITHDRAW_TICKET_ISSUED);
        if (balance.value() == 0) {
            balance.destroy_zero();
            return balance::zero()
        };

        // when lp_treasury is empty, withdraw all the rewards to the free_balance
        if(self.lp_treasury.total_supply() == 0){
            let time_locked_profit_mut= self.time_locked_profit_mut<T, YT>();
            time_locked_profit_mut.change_unlock_per_second(0, clock);
            let skimmed = time_locked_profit_mut.skim_extraneous_balance();
            let withdrawn = time_locked_profit_mut.withdraw_all(clock);

            let free_balance_mut = self.free_balance_mut<T, YT>();
            free_balance_mut.join(skimmed);
            free_balance_mut.join(withdrawn);

            // collect everything left to fee_balance
            let total_fee = free_balance_mut.withdraw_all();
            self.performance_fee_balance_mut().join(total_fee);
        };
        
        //  TVL validation
        let total_available_balance = self.total_available_balance_by_asset<T, YT>(clock);
        let tvl_cap = self.tvl_cap_by_asset<T, YT>();
        if(tvl_cap.is_some()){
            let tvl_cap = tvl_cap.borrow();
            assert!(
                total_available_balance + balance.value() <= *tvl_cap,
                ERR_EXCEED_TVL_CAP
            );
        };
        
        // calculate required deposited amount by input LP token
        let to_deposit = get_required_deposit_by_given_yt<T, YT>(self, deposit_ticket.minted_yt_amt, clock);
        assert!(balance.value() >= to_deposit, ERR_INSUFFICIENT_DEPOSIT);
        let surplus = if(to_deposit > balance.value()){
            let surplus = to_deposit - balance.value();
            balance.split(surplus)
        }else{
            balance::zero()
        };

        event::deposit_by_asset_event<T, YT>(balance.value(), deposit_ticket.minted_yt_amt);
        self.free_balance_mut<T, YT>().join(balance);
        deposit_ticket.deposited_types.insert(type_name::get<T>());

        surplus
    }

    public fun settle_deposit_ticket<YT>(
        self: &mut MultiAssetVault<YT>, 
        deposit_ticket: DepositTicket<YT>,
    ):Balance<YT>{
        // have to deposit all supported assets
        check_deposit_ticket_fulfilled(self, &deposit_ticket.deposited_types);

        let DepositTicket{
            deposited_types: _,
            minted_yt_amt
        } = deposit_ticket;
            
        self.lp_treasury.mint_balance(minted_yt_amt)
    }
    // Deposit <-----

    // -----> Rebalance
    /// Get the target rebalance amounts the strategies should repay or can borrow.
    /// It takes into account strategy target allocation weights and max borrow limits
    /// and calculates the values so that the vault's balance allocations are kept
    /// at the target weights and all of the vault's balance is allocated.
    /// This function is idempotent in the sense that if you rebalance the pool with
    /// the returned amounts and call it again, the result will require no further
    /// rebalancing.
    /// The strategies are not expected to repay / borrow the exact amounts suggested
    /// as this may be dictated by their internal logic, but they should try to
    /// get as close as possible. Since the strategies are trusted, there are no
    /// explicit checks for this within the vault.
    public fun calc_rebalance_amounts_by_asset<T, YT>(
        self: &MultiAssetVault<YT>,
        clock: &Clock
    ): RebalanceAmounts<T> {
        assert!(self.withdraw_ticket_issued == false, ERR_WITHDRAW_TICKET_ISSUED);

        // calculate total available balance by "free_balance" & "locked balance"
        let mut rebalance_infos: VecMap<ID, RebalanceInfo> = vec_map::empty();
        let mut total_available_balance = 0;
        let mut max_borrow_ids_to_process = vec::empty();
        let mut no_max_borrow_ids = vec::empty();

        total_available_balance = total_available_balance + self.free_balance<T, YT>().value();
        total_available_balance = total_available_balance + self.time_locked_profit<T, YT>().max_withdrawable(clock);

        // Calculate "borrowed amounts"
        let protocol_ids = self.supported_strategies_by_asset<T, YT>();
        let (mut i, n) = (0, protocol_ids.length());
        while (i < n) {
            let strategy_id = protocol_ids[i];
            vec_map::insert(
                &mut rebalance_infos,
                strategy_id,
                RebalanceInfo {
                    to_repay: 0,
                    can_borrow: 0,
                },
            );

            let multi_strategy_state = &self.strategies[&strategy_id];
            let borrowed_info = multi_strategy_state.borrowed_info<T>();
            total_available_balance = total_available_balance + borrowed_info.borrowed;
            if (borrowed_info.max_borrow.is_some()) {
                vector::push_back(&mut max_borrow_ids_to_process, strategy_id);
            } else {
                vector::push_back(&mut no_max_borrow_ids, strategy_id);
            };

            i = i + 1;
        };

        // process strategies with max borrow limits iteratively until all who can reach their cap have reached it
        let mut remaining_to_allocate = total_available_balance;
        let mut remaining_total_alloc_bps = BPS_IN_100_PCT;

        let mut need_to_reprocess = true;
        while (need_to_reprocess) {
            let mut i = 0;
            let n = vector::length(&max_borrow_ids_to_process);
            let mut new_max_borrow_ids_to_process = vector::empty();
            need_to_reprocess = false;
            while (i < n) {
                let strategy_id = *vector::borrow(&max_borrow_ids_to_process, i);

                let multi_strategy_state = &self.strategies[&strategy_id];
                let borrowed_info = multi_strategy_state.borrowed_info<T>();
                let rebalance_info = &mut rebalance_infos[&strategy_id];

                let max_borrow = *borrowed_info.max_borrow.borrow();
                let target_alloc_amt = mul_div(
                    remaining_to_allocate,
                    borrowed_info.target_alloc_weight_bps,
                    remaining_total_alloc_bps,
                );

                if (target_alloc_amt <= borrowed_info.borrowed || max_borrow <= borrowed_info.borrowed) {
                    // needs to repay
                    if (target_alloc_amt < max_borrow) {
                        vector::push_back(&mut new_max_borrow_ids_to_process, strategy_id);
                    } else {
                        let target_alloc_amt = max_borrow;
                        rebalance_info.to_repay = borrowed_info.borrowed - target_alloc_amt;
                        remaining_to_allocate = remaining_to_allocate - target_alloc_amt;
                        remaining_total_alloc_bps = remaining_total_alloc_bps - borrowed_info.target_alloc_weight_bps;

                        // might add extra amounts to allocate so need to reprocess ones which
                        // haven't reached their cap
                        need_to_reprocess = true; 
                    };

                    i = i + 1;
                    continue
                };
                // can borrow
                if (target_alloc_amt >= max_borrow) {
                    let target_alloc_amt = max_borrow;
                    rebalance_info.can_borrow = target_alloc_amt - borrowed_info.borrowed;
                    remaining_to_allocate = remaining_to_allocate - target_alloc_amt;
                    remaining_total_alloc_bps = remaining_total_alloc_bps - borrowed_info.target_alloc_weight_bps;

                    // might add extra amounts to allocate so need to reprocess ones which
                    // haven't reached their cap
                    need_to_reprocess = true;

                    i = i + 1;
                    continue
                } else {
                    vector::push_back(&mut new_max_borrow_ids_to_process, strategy_id);

                    i = i + 1;
                    continue
                }
            };
            max_borrow_ids_to_process = new_max_borrow_ids_to_process;
        };
        //
        // the remaining strategies in `max_borrow_idxs_to_process` and `no_max_borrow_idxs` won't reach
        // their cap so we can easilly calculate the remaining amounts to allocate
        let mut i = 0;
        let n = vector::length(&max_borrow_ids_to_process);
        while (i < n) {
            let strategy_id = *vector::borrow(&max_borrow_ids_to_process, i);

            let multi_strategy_state = &self.strategies[&strategy_id];
            let borrowed_info = multi_strategy_state.borrowed_info<T>();
            let rebalance_info = &mut rebalance_infos[&strategy_id];

            let target_borrow = mul_div(
                remaining_to_allocate,
                borrowed_info.target_alloc_weight_bps,
                remaining_total_alloc_bps,
            );
            if (target_borrow >= borrowed_info.borrowed) {
                rebalance_info.can_borrow = target_borrow - borrowed_info.borrowed;
            } else {
                rebalance_info.to_repay = borrowed_info.borrowed - target_borrow;
            };

            i = i + 1;
        };

        let mut i = 0;
        let n = vector::length(&no_max_borrow_ids);
        while (i < n) {
            let strategy_id = *vector::borrow(&no_max_borrow_ids, i);

            let multi_strategy_state = &self.strategies[&strategy_id];
            let borrowed_info = multi_strategy_state.borrowed_info<T>();
            let rebalance_info = &mut rebalance_infos[&strategy_id];

            let target_borrow = mul_div(
                remaining_to_allocate,
                borrowed_info.target_alloc_weight_bps,
                remaining_total_alloc_bps,
            );
            if (target_borrow >= borrowed_info.borrowed) {
                rebalance_info.can_borrow = target_borrow - borrowed_info.borrowed;
            } else {
                rebalance_info.to_repay = borrowed_info.borrowed - target_borrow;
            };

            i = i + 1;
        };

        RebalanceAmounts { inner: rebalance_infos }
    }

    /// Return the repaid debt Balance
    public fun strategy_repay<T, YT>(
        self: &mut MultiAssetVault<YT>,
        access: &VaultAccess,
        balance: Balance<T>
    ) {
        assert_version(self);
        assert!(self.withdraw_ticket_issued == false, ERR_WITHDRAW_TICKET_ISSUED);

        let strategy_id = access.vault_access_id();

        // update borrowed in borrowed_info
        self.decrease_borrowed<T, YT>(strategy_id, balance.value());
        let free_balance_mut = self.free_balance_mut<T, YT>();
        free_balance_mut.join(balance);
    }
    
    /// Take the available borrowed Balance
    public fun strategy_borrow<T, YT>(
        self: &mut MultiAssetVault<YT>,
        access: &VaultAccess,
        amount: u64
    ): Balance<T> {
        assert_version(self);
        assert!(self.withdraw_ticket_issued == false, ERR_WITHDRAW_TICKET_ISSUED);

        let strategy_id = access.vault_access_id();

        // update borrowed in borrowed_info
        self.increase_borrowed<T, YT>(strategy_id, amount);
        let free_balance_mut = self.free_balance_mut<T, YT>();
        free_balance_mut.split(amount)
    }

    // TODO: does this require package validation constraint
    public fun strategy_hand_over_profit<T, YT>(
        self: &mut MultiAssetVault<YT>,
        access: &VaultAccess,
        mut profit: Balance<T>,
        clock: &Clock
    ) {
        assert_version(self);

        assert!(self.withdraw_ticket_issued == false, ERR_WITHDRAW_TICKET_ISSUED);

        let strategy_id = access.vault_access_id();
        assert!(self.strategies.contains(&strategy_id), ERR_INVALID_VAULT_ACCESS);

        // collect performance fee
        let fee_amt_t = mul_div(
            balance::value(&profit),
            self.performance_fee_bps,
            BPS_IN_100_PCT
        );

        let fee_balance = profit.split(fee_amt_t);
        self.performance_fee_balance_mut<T, YT>().join(fee_balance);

        event::strategy_profit_event<T>(access.vault_access_id(), profit.value(), fee_amt_t);

        // reset profit unlock (withdraw all available balance to free_balance)
        let total_profits = self.time_locked_profit_mut<T, YT>().withdraw_all(clock);
        self.free_balance_mut<T, YT>().join(total_profits);

        let profit_unlock_duration_sec = self.profit_unlock_duration_sec;
        let time_locked_profit_mut = self.time_locked_profit_mut<T, YT>();

        // unlock all locked_balance
        tlb::change_unlock_per_second(time_locked_profit_mut, 0, clock);
        let mut redeposit = time_locked_profit_mut.skim_extraneous_balance();
        balance::join(&mut redeposit, profit);

        time_locked_profit_mut.change_unlock_start_ts_sec(timestamp_sec(clock), clock);
        let unlock_per_second = math::divide_and_round_up(
            redeposit.value(),
            profit_unlock_duration_sec
        );
        time_locked_profit_mut.change_unlock_per_second(unlock_per_second, clock);
        time_locked_profit_mut.top_up(redeposit, clock);
    }
    // Rebalance <-----

    // -----> Withdraw
    public fun prepare_withdraw_ticket<YT>(
        self: &mut MultiAssetVault<YT>,
        lp_token: Balance<YT>,
        ctx: &mut TxContext
    ):WithdrawTicket<YT>{
        assert!(self.withdraw_ticket_issued == false, ERR_WITHDRAW_TICKET_ISSUED);
        assert!(lp_token.value() > 0, ERR_ZERO_AMT);

        self.withdraw_ticket_issued = true;

        WithdrawTicket<YT>{
            withdraw_infos: bag::new(ctx),
            claimed: vec_set::empty(),
            lp_to_burn: lp_token
        }
    }

    /// taked withdrawal priority:
    /// 1. free_balance
    /// 2. over-cap
    /// 3. proportionally repaid from borrowed_amount
    public fun withdraw<T, YT>(
        self: &mut MultiAssetVault<YT>, 
        ticket: &mut WithdrawTicket<YT>,
        clock: &Clock
    ){
        assert_version(self);

        let type_name = type_name::get<T>();
        assert!(!ticket.claimed.contains(&type_name), ERR_ASSET_ALREADY_WITHDREW);
        assert!(ticket.lp_to_burn.value() > 0, ERR_ZERO_AMT);

        ticket.claimed.insert(type_name);
        initialize_withdraw_ticket_by_asset<T, YT>(self, ticket);

        // join unlocked profits to free balance
        let profits = self.time_locked_profit_mut<T, YT>().withdraw_all(clock);
        balance::join(
            self.free_balance_mut<T, YT>(),
            profits
        );

        // calculate withdraw amount by given burned LP token
        let total_available = self.total_available_balance_by_asset<T, YT>(clock);
        let mut remaining_to_withdraw = mul_div(
            ticket.lp_to_burn.value(),
            total_available,
            self.lp_treasury.total_supply()
        );

        // first withdraw everything possible from free balance
        ticket.withdraw_info_mut<T, YT>().to_withdraw_from_free_balance = math::min(
            remaining_to_withdraw,
            self.free_balance<T, YT>().value()
        );
        remaining_to_withdraw = remaining_to_withdraw - ticket.withdraw_info<T, YT>().to_withdraw_from_free_balance;

        if (remaining_to_withdraw == 0) {
            return
        };

        // if this is not enough, start withdrawing from strategies
        // first withdraw from all the strategies that are over their target allocation
        let mut total_borrowed_after_excess_withdrawn = 0;

        let (mut i, n) = (0, self.strategy_withdraw_priority_order.length());
        while (i < n) {
            let strategy_id = vector::borrow(&self.strategy_withdraw_priority_order, i);
            let multi_strategy_state = &self.strategies[strategy_id];

            if(multi_strategy_state.borrowed_infos_contains_by_asset<T>()){
                let borrowed_info = multi_strategy_state.borrowed_info<T>();

                let over_cap = if (option::is_some(&borrowed_info.max_borrow)) {
                    let max_borrow: u64 = *option::borrow(&borrowed_info.max_borrow);
                    if (borrowed_info.borrowed > max_borrow) {
                        borrowed_info.borrowed - max_borrow
                    } else {
                        0
                    }
                } else {
                    0
                };
                let to_withdraw = if (over_cap >= remaining_to_withdraw) {
                    remaining_to_withdraw
                } else {
                    over_cap
                };
                remaining_to_withdraw = remaining_to_withdraw - to_withdraw;
                total_borrowed_after_excess_withdrawn =
                    total_borrowed_after_excess_withdrawn + borrowed_info.borrowed - to_withdraw;

                ticket.update_to_withdraw_by_asset<T, YT>(*strategy_id, to_withdraw);
            };

            i = i + 1;
        };

        // if that is not enough, withdraw from all strategies proportionally so that
        // the strategy borrowed amounts are kept at the same proportions as they were before
        if (remaining_to_withdraw == 0) return;

        let to_withdraw_propotionally_base = remaining_to_withdraw;

        let (mut i, n) = (0, self.strategy_withdraw_priority_order.length());
        while (i < n) {
            let strategy_id = vector::borrow(&self.strategy_withdraw_priority_order, i);
            let multi_strategy_state = &self.strategies[strategy_id];
            if(multi_strategy_state.borrowed_infos_contains_by_asset<T>()){
                let borrowed_info = multi_strategy_state.borrowed_info<T>();
                let strategy_withdraw_info_mut = ticket.strategy_withdraw_info_mut<T, YT>(*strategy_id);

                let strategy_remaining = borrowed_info.borrowed - strategy_withdraw_info_mut.to_withdraw;
                let to_withdraw = mul_div(
                    strategy_remaining,
                    to_withdraw_propotionally_base,
                    total_borrowed_after_excess_withdrawn
                );

                strategy_withdraw_info_mut.to_withdraw = strategy_withdraw_info_mut.to_withdraw + to_withdraw;
                remaining_to_withdraw = remaining_to_withdraw - to_withdraw;
            };

            i = i + 1;
        };

        // if that is not enough, start withdrawing all from strategies in priority order
        if (remaining_to_withdraw == 0) return;

        let (mut i, n) = (0, self.strategy_withdraw_priority_order.length());
        while (i < n) {
            let strategy_id = vector::borrow(&self.strategy_withdraw_priority_order, i);
            let multi_strategy_state = &self.strategies[strategy_id];
            if(multi_strategy_state.borrowed_infos_contains_by_asset<T>()){
                let borrowed_info = multi_strategy_state.borrowed_info<T>();
                let strategy_withdraw_info_mut = ticket.strategy_withdraw_info_mut<T, YT>(*strategy_id);

                let strategy_remaining = borrowed_info.borrowed - strategy_withdraw_info_mut.to_withdraw;
                let to_withdraw = math::min(strategy_remaining, remaining_to_withdraw);

                strategy_withdraw_info_mut.to_withdraw = strategy_withdraw_info_mut.to_withdraw + to_withdraw;
                remaining_to_withdraw = remaining_to_withdraw - to_withdraw;

                if (remaining_to_withdraw == 0) {
                    break
                };
            };

            i = i + 1;
        };
    }

    /// Makes the strategy deposit the withdrawn balance into the `WithdrawTicket`.
    public fun strategy_withdraw_to_ticket<T, YT>(
        ticket: &mut WithdrawTicket<YT>,
        access: &VaultAccess,
        balance: Balance<T>
    ) {
        let strategy_withdraw_info = ticket.strategy_withdraw_info_mut<T, YT>(access.vault_access_id());

        assert!(strategy_withdraw_info.has_withdrawn == false, ERR_STRATEGY_ALREADY_WITHDRAWN);
        strategy_withdraw_info.has_withdrawn = true;

        balance::join(&mut strategy_withdraw_info.withdrawn_balance, balance);
    }

    /// Redeem to retrieve all balances
    public fun redeem_withdraw_ticket<T, YT>(
        self: &mut MultiAssetVault<YT>,
        ticket: &mut WithdrawTicket<YT>
    ): Balance<T> {
        assert_version(self);

        let mut out = balance::zero();

        // drop the "WithdrawInfo" instance from Bag
        let type_name = type_name::get<T>();
        assert!(ticket.withdraw_infos_contains<T, YT>(), ERR_WITHDRAW_TICKET_NOT_SETUP);
        let withdraw_info = ticket.withdraw_infos.remove(type_name);
        let WithdrawInfo<T>{
            to_withdraw_from_free_balance,
            mut strategy_infos,
        } = withdraw_info;
        let lp_to_burn_amt = ticket.lp_to_burn.value();

        while (strategy_infos.size() > 0) {
            // drop StrategyWithdrawInfo<T>
            let (strategy_id, strategy_withdraw_info) = vec_map::pop(&mut strategy_infos);
            let StrategyWithdrawInfo {
                to_withdraw, 
                withdrawn_balance, 
                has_withdrawn
            } = strategy_withdraw_info;
            if (to_withdraw > 0) {
                assert!(has_withdrawn, ERR_STRATEGY_NOT_WITHDRAWN);
            };
            if (withdrawn_balance.value() < to_withdraw) {
                event::strategy_loss_event<YT>(strategy_id, to_withdraw, withdrawn_balance.value());
            };

            // Reduce strategy's borrowed amount. This calculation is intentionally based on
            // `to_withdraw` and not `withdrawn_balance` amount so that any losses generated
            // by the withdrawal are effectively covered by the user and considered paid back
            // to the vault. This also ensures that vault's `total_available_balance` before
            // and after withdrawal matches the amount of lp tokens burned.
            self.decrease_borrowed<T, YT>(strategy_id, to_withdraw);

            balance::join(&mut out, withdrawn_balance);
        };
        strategy_infos.destroy_empty();

        balance::join(
            &mut out,
            balance::split(self.free_balance_mut<T, YT>(), to_withdraw_from_free_balance),
        );

        event::withdraw_event<YT>(out.value(), lp_to_burn_amt);

        out
    }

    public fun settle_withdraw_ticket<YT>(
        self: &mut MultiAssetVault<YT>,
        ticket: WithdrawTicket<YT>
    ){
        // check all the balances have been withdraw
        let supported_assets = self.supported_assets();
        assert!(ticket.withdraw_infos.is_empty() && supported_assets == *ticket.claimed.keys(), ERR_UNREDEEMED_ASSET);

        let WithdrawTicket{
            withdraw_infos,
            claimed: _,
            lp_to_burn,
        } = ticket;
        // abort if didn't remove all supported assets
        withdraw_infos.destroy_empty();

        balance::decrease_supply(
            coin::supply_mut(&mut self.lp_treasury),
            lp_to_burn,
        );

        self.withdraw_ticket_issued = false;
    }
    // Withdraw <-----

    /* ================= Private Functions ================= */
    fun assert_version<YT>(self: &MultiAssetVault<YT>) {
        assert!(self.version == module_version(), ERR_WRONG_VERSION);
    }

    fun check_deposit_ticket_fulfilled<YT>(self: &MultiAssetVault<YT>, settled_assets: &VecSet<TypeName>){
        let keys = self.supported_assets();
        let (mut i, len) = (0, keys.length());

        while( i < len ){
            assert!(settled_assets.contains(&keys[i]), ERR_UNFULLFILLED_ASSET);
            i = i + 1;
        };
    }

    fun check_removal_ticket_fulfilled<YT>(
        self: &MultiAssetVault<YT>,
        vault_access: &VaultAccess,
        settled_assets: &VecSet<TypeName>
    ){
        let strategy_state = &self.strategies[&vault_access.vault_access_id()];
        let keys = strategy_state.borrowed_infos.keys();
        let (mut i, len) = (0, keys.length());

        while( i < len ){
            assert!(settled_assets.contains(&keys[i]), ERR_UNFULLFILLED_ASSET);
            i = i + 1;
        };
    }

    fun initialize_withdraw_ticket_by_asset<T, YT>(
        self: &MultiAssetVault<YT>,
        ticket: &mut WithdrawTicket<YT>
    ){
        // strategy_infos
        let mut strategy_infos: VecMap<ID, StrategyWithdrawInfo<T>> = vec_map::empty();
        let mut i = 0;
        let n = vector::length(&self.strategy_withdraw_priority_order);
        while (i < n) {
            let strategy_id = *vector::borrow(&self.strategy_withdraw_priority_order, i);
            let multi_asset_strategy_state = &self.strategies[&strategy_id];

            if(multi_asset_strategy_state.borrowed_infos_contains_by_asset<T>()){
                let info = StrategyWithdrawInfo {
                    to_withdraw: 0,
                    withdrawn_balance: balance::zero(),
                    has_withdrawn: false,
                };
                vec_map::insert(&mut strategy_infos, strategy_id, info);
            };

            i = i + 1;
        };
        // withdraw_info
        let withdraw_info = WithdrawInfo<T>{
            to_withdraw_from_free_balance: 0,
            strategy_infos
        };
        // insert to ticket
        ticket.withdraw_infos.add(type_name::get<T>(), withdraw_info);
    }

    /// @return; the supported_protocols Ids
    public fun supported_strategies_by_asset<T, YT>(self: &MultiAssetVault<YT>):vector<ID>{
        let mut supported_protocols = vector[];
        
        let (mut i, len) = (0, self.strategies.size());
        while(i < len){
            let (id, strategy_state) = self.strategies.get_entry_by_idx(i);
            if(strategy_state.borrowed_infos.contains(&type_name::get<T>())) supported_protocols.push_back(*id);

            i = i + 1;
        };

        supported_protocols
    }

    /// @return; the num of supported_protocol_IDs
    public fun num_of_strategies_by_asset<T, YT>(self: &MultiAssetVault<YT>):u64{
        let supported_protocols = supported_strategies_by_asset<T, YT>(self);
        supported_protocols.length()
    }
}
