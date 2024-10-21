#[test_only]
#[allow(unused)]
module vault::multi_vault_test_utils {
    use vault::multi_asset_vault::{Self as mav, MultiAssetVault, VaultAccess, RebalanceAmounts, WithdrawTicket};
    use vault::time_locked_balance::{Self as tlb, TimeLockedBalance};
    use vault::mock_strategy::{Self, MockStrategy};

    // ===== MultiAssetVault  =====
    public fun assert_vault_registered_asset<T, YT>(
        self: &MultiAssetVault<YT>
    ){
        let free_balances_contains_ = self.free_balances_contains<T, YT>();
        let time_locked_profits_contains_ = self.time_locked_profits_contains<T, YT>();
        let tvl_cap_contains_ = self.tvl_caps_contains<T, YT>();
        assert!(free_balances_contains_ && time_locked_profits_contains_ && tvl_cap_contains_, 404);
    }

    public fun assert_vault_info<T, YT>(
        self: &MultiAssetVault<YT>,
        free_balance: u64,
        locked_balance: u64,
        unlocked_balance: u64,
        unlock_per_second: u64,
        performance_fee: u64,
        withdraw_ticket_issued: bool,
        profit_unlock_duration_sec: u64,
        tvl: Option<u64>
    ){
        let (
            free_balance_,
            locked_balance_,
            unlocked_balance_,
            unlock_per_second_,
            performance_fee_,
            withdraw_ticket_issued_,
            profit_unlock_duration_sec_
        ) = mav::vault_info_by_asset<T, YT>(self);
        let tvl_ = self.tvl_cap_by_asset<T, YT>();
        assert!(free_balance == free_balance_, 404);
        assert!(locked_balance == locked_balance_, 404);
        assert!(unlocked_balance == unlocked_balance_, 404);
        assert!(unlock_per_second == unlock_per_second_, 404);
        assert!(performance_fee == performance_fee_, 404);
        assert!(withdraw_ticket_issued == withdraw_ticket_issued_, 404);
        assert!(profit_unlock_duration_sec == profit_unlock_duration_sec_, 404);
        assert!(tvl == tvl_, 404);
    }

    public fun assert_vault_strategy_exist<YT>(
        self: &MultiAssetVault<YT>,
        strategy_id: ID
    ){
        let exist_in_strategies = self.strategies().contains(&strategy_id);
        let exist_in_withdraw_priority = self.strategy_withdraw_priority_order().contains(&strategy_id);
        assert!(exist_in_strategies && exist_in_withdraw_priority, 404);
    }

    public fun assert_vault_strategy_state<T, YT>(
        self: &MultiAssetVault<YT>,
        strategy_id: ID,
        borrowed: u64,
        target_alloc_weight_bps: u64,
        max_borrow: Option<u64>,
    ){
        let (borrowed_, max_borrow_, target_alloc_weight_bps_) = self.get_borrowed_info_by_asset<T, YT>(strategy_id);
        assert!(borrowed == borrowed_, 404);
        assert!(target_alloc_weight_bps == target_alloc_weight_bps_, 404);
        assert!(max_borrow == max_borrow_, 404);
    }
    
    // ===== Mocked Strategy =====
    public fun assert_strategy_info<T>(
        strategy: &MockStrategy<T>,
        scoin_bal: u64,
        underlying_value: u64,
        collected_profit: u64
    ){
        let (scoin_bal_, underlying_value_, collected_profit_) = strategy.strategy_info<T>();
        assert!(scoin_bal == scoin_bal_, 404);
        assert!(underlying_value == underlying_value_, 404);
        assert!(collected_profit == collected_profit_, 404);
    }
}
