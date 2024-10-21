module vault::event{
    use sui::event::emit;

    // /* ================= Vault ================= */
    public struct DepositEvent<phantom YT> has copy, drop {
        amount: u64,
        lp_minted: u64,
    }
    public(package) fun deposit_event<YT>(
        amount: u64,
        lp_minted: u64,
    ){
        emit(
            DepositEvent<YT>{
                amount,
                lp_minted
            }
        )
    }

    public struct WithdrawEvent<phantom YT> has copy, drop {
        amount: u64,
        lp_burned: u64,
    }
    public(package) fun withdraw_event<YT>(
        amount: u64,
        lp_burned: u64,
    ){
        emit(
            WithdrawEvent<YT>{
                amount,
                lp_burned
            }
        )
    }

    public struct StrategyProfitEvent<phantom T> has copy, drop {
        strategy_id: ID,
        profit: u64,
        fee_amt_t: u64,
    }
    public(package) fun strategy_profit_event<YT>(
        strategy_id: ID,
        profit: u64,
        fee_amt_t: u64
    ){
        emit(
            StrategyProfitEvent<YT>{
                strategy_id,
                profit,
                fee_amt_t
            }
        )
    }

    public struct StrategyLossEvent<phantom YT> has copy, drop {
        strategy_id: ID,
        to_withdraw: u64,
        withdrawn: u64
    }
    public(package) fun strategy_loss_event<YT>(
        strategy_id: ID,
        to_withdraw: u64,
        withdrawn: u64
    ){
        emit(
            StrategyLossEvent<YT>{
                strategy_id,
                to_withdraw,
                withdrawn
            }
        )
    }

    // borrow
    public struct BorrowEvent<phantom T, phantom YT> has copy, drop {
        strategy_id: ID,
        borrow: u64,
    }
    public fun borrow<T, YT>(
        strategy_id: ID,
        borrow: u64,
    ){
        emit(
            BorrowEvent<T, YT>{
                strategy_id,
                borrow
            }
        );
    }

    // /* ================= MultiAssetVault ================= */
    public struct DepositByAssetEvent<phantom T, phantom YT> has copy, drop {
        amount: u64,
        lp_minted: u64,
    }
    public(package) fun deposit_by_asset_event<T, YT>(
        amount: u64,
        lp_minted: u64,
    ){
        emit(
            DepositByAssetEvent<T, YT>{
                amount,
                lp_minted
            }
        )
    }
}
