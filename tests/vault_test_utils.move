#[test_only]
#[allow(unused)]
module vault::vault_test_utils {
    use vault::vault::{Self, Vault, VaultAccess, AdminCap as VaultAdminCap, StrategyRemovalTicket, RebalanceAmounts, WithdrawTicket};
    use vault::time_locked_balance::{Self as tlb, TimeLockedBalance};

    // ===== Vault =====
    public fun assert_vault_info<T, YT>(
        vault: &Vault<T, YT>,
        free_balance: u64,
        locked_balance: u64,
        unlocked_balance: u64,
        unlock_per_second: u64,
        performance_fee_balance: u64,
        withdraw_ticket_issued: bool,
        tvl_cap: Option<u64>,
        profit_unlock_duration_sec: u64
    ){
        let (
            free_balance_,
            locked_balance_,        
            unlocked_balance_,
            unlock_per_second_,
            performance_fee_balance_,
            withdraw_ticket_issued_,
            tvl_cap_,
            profit_unlock_duration_sec_
        ) = vault::vault_info(vault);
        assert!(free_balance == free_balance_, 404);
        assert!(locked_balance == locked_balance_, 404);
        assert!(unlocked_balance == unlocked_balance_, 404);
        assert!(unlock_per_second == unlock_per_second_, 404);
        assert!(performance_fee_balance == performance_fee_balance_, 404);
        assert!(withdraw_ticket_issued == withdraw_ticket_issued_, 404);
        assert!(tvl_cap == tvl_cap_, 404);
        assert!(profit_unlock_duration_sec == profit_unlock_duration_sec_, 404);
    }

    public fun assert_vault_strategy_state<T, YT>(
        vault: &Vault<T, YT>,
        strategy_id: ID,
        borrowed: u64,
        target_alloc_weight_bps: u64,
        max_borrow: Option<u64>,
    ){
        let strategies = vault.strategies();
        let strategy_state = &strategies[&strategy_id];
        let (borrowed_, target_alloc_weight_bps_, max_borrow_) = strategy_state.strategy_state();
        assert!(borrowed == borrowed_, 404);
        assert!(target_alloc_weight_bps == target_alloc_weight_bps_, 404);
        assert!(max_borrow == max_borrow_, 404);
    }
    
    // ===== timelockedbalance =====
    public fun assert_time_locked_balance_info<T>(
        time_locked_balance: &TimeLockedBalance<T>,
        locked_balance: u64,
        unlock_start_ts_sec: u64,
        unlock_per_second: u64,
        unlocked_balance: u64,
        final_unlock_ts_sec: u64,
        previous_unlock_at: u64
    ){
        assert!(locked_balance == time_locked_balance.locked_balance().value(), 404);
        assert!(unlock_start_ts_sec == time_locked_balance.unlock_start_ts_sec(), 404);
        assert!(unlock_per_second == time_locked_balance.unlock_per_second(), 404);
        assert!(unlocked_balance == time_locked_balance.unlocked_balance().value(), 404);
        assert!(final_unlock_ts_sec == time_locked_balance.final_unlock_ts_sec(), 404);
        assert!(previous_unlock_at == time_locked_balance.previous_unlock_at(), 404);
    }
}
