#[test_only]
module vault::mock_strategy {
    use sui::balance::{Self, Balance, Supply};
    use sui::coin::{Self};
    use sui::clock::Clock;
    use sui::math;

    use vault::utils::mul_div;
    use vault::multi_asset_vault::{ Self as mav, AdminCap, VaultAccess, RebalanceAmounts, MultiAssetVault, MultiAssetStrategyRemovalTicket, WithdrawTicket};

    use slp::slp::SLP;


    /// Fabricated SCOIN
    public struct SCOIN<phantom T> has drop {}


    public struct MockStrategy<phantom T> has key, store{
        id: UID,
        vault_access: Option<VaultAccess>,
        scoin_balance: Balance<SCOIN<T>>,
        underlying_value: u64,
        collected_profit: Balance<T>,
        // mocked staking rewards pool
        cap: Supply<SCOIN<T>>,
        reserve_coin: Balance<T>,
        reserve_scoin: Balance<SCOIN<T>>
    }

    #[test_only]
    public use fun vault::multi_vault_test_utils::assert_strategy_info as MockStrategy.assert_strategy_info;

    /* ================= Public-View Functions ================= */
    public fun vault_access_id<T>(self: &MockStrategy<T>):ID{
        // abort if no vault_access
        mav::vault_access_id(self.vault_access.borrow())
    }

    public fun strategy_info<T>(
        self: &MockStrategy<T>
    ):(u64, u64, u64){
        (self.scoin_balance.value(), self.underlying_value, self.collected_profit.value())
    }

    public fun new<T>(
        _: &AdminCap<SLP>,
        ctx: &mut TxContext
    ):MockStrategy<T>{
        MockStrategy<T>{
            id: object::new(ctx),
            vault_access: option::none(),
            scoin_balance: balance::zero(),
            underlying_value: 0,
            collected_profit: balance::zero(),
            // mocked staking rewards pool
            cap: coin::create_treasury_cap_for_testing<SCOIN<T>>(ctx).treasury_into_supply(),
            reserve_coin: balance::zero(),
            reserve_scoin: balance::zero()
        }
    }

    public fun join_vault<T>(
        cap: &AdminCap<SLP>, 
        m_vault: &mut MultiAssetVault<SLP>,
        self: &mut MockStrategy<T>,
        ctx: &mut TxContext
    ){
        let access = mav::add_strategy(cap, m_vault, ctx);
        m_vault.add_strategy_supported_asset<T, SLP>(cap, &access);
        option::fill(&mut self.vault_access, access); // aborts if`is_some`
    }

    public fun remove_strategy_from_vault<T>(
        cap: &AdminCap<SLP>, 
        self: &mut MockStrategy<T>,
        multi_asset_vault: &mut MultiAssetVault<SLP>,
        ids_for_weights: vector<ID>, 
        weights_bps: vector<u64>,
        clock: &Clock,
        ctx: &mut TxContext
    ):MultiAssetStrategyRemovalTicket<SLP>{
        // return all the borrowed Balance<T>
        let scoin_bal = self.scoin_balance.withdraw_all();
        let coin_bal = if(scoin_bal.value() > 0){
            self.unstake(scoin_bal)
        }else{
            scoin_bal.destroy_for_testing();
            balance::zero()
        };
        // create and remove removal_ticket
        let mut removal_ticket = mav::new_multi_asset_strategy_removal_ticket(cap, self.vault_access.extract(), ctx);
        // return the balance
        removal_ticket.add_strategy_removal_asset_by_asset(coin_bal);
        mav::remove_strategy_by_asset<T, SLP>(cap, multi_asset_vault, &mut removal_ticket, ids_for_weights, weights_bps, clock);

        removal_ticket
    }

    public fun rebalance<T>(
        self: &mut MockStrategy<T>,
        _: &AdminCap<SLP>,
        m_vault: &mut MultiAssetVault<SLP>,
        amounts: &RebalanceAmounts<T>
    ){
        let (can_borrow, to_repay) = mav::rebalance_amounts_get(amounts, self.vault_access.borrow());
        if (to_repay > 0) {
            // get withdraw amt by calculating the propotion to underlying_value
            let unstaked_val = mul_div(to_repay, self.scoin_balance.value(), self.underlying_value);
            // redeem sCoin
            let scoin_bal = self.scoin_balance.split(unstaked_val);
            let mut taked_coin_bal = self.unstake(scoin_bal);

            if (taked_coin_bal.value() > to_repay) {
                let extra_amt = balance::value(&taked_coin_bal) - to_repay;
                balance::join(
                    &mut self.collected_profit,
                    balance::split(&mut taked_coin_bal, extra_amt)
                );
            };

            let repaid = taked_coin_bal.value();
            mav::strategy_repay(m_vault, self.vault_access.borrow(), taked_coin_bal);

            self.underlying_value = self.underlying_value - repaid;
        } else if (can_borrow > 0) {
            let borrow_amt = math::min(can_borrow, mav::free_balance<T, SLP>(m_vault).value());
            let borrowed = mav::strategy_borrow<T, SLP>(m_vault, self.vault_access.borrow(), borrow_amt);
            let scoin_bal = self.stake(borrowed);

            self.scoin_balance.join(scoin_bal);
            self.underlying_value = self.underlying_value + borrow_amt;
        }
    }

    /// Skim the profits earned on base APY.(distributed yields from deposited revenue)
    /// collect the rewards to 'underlying_value'
    public fun skim_base_profits<T>(
        self: &mut MockStrategy<T>,
        _: &AdminCap<SLP>
    ) {
        let scoin_bal = self.scoin_balance.withdraw_all();
        let mut total_coin_bal = self.unstake(scoin_bal);

        if (total_coin_bal.value() > self.underlying_value) {
            let profit_amt = balance::value(&total_coin_bal) - self.underlying_value;
            balance::join(
                &mut self.collected_profit, 
                balance::split(&mut total_coin_bal, profit_amt),
            );
        };

        // put back
        let scoin_bal = self.stake(total_coin_bal);
        self.scoin_balance.join(scoin_bal);
    }

    /// Pull ths from 'input profit' and 'underlying_value' to locked_balance
    /// then pull unlocked_balance to free_balance
    public fun deposit_external_profits<T>(
        _: &AdminCap<SLP>, 
        self: &mut MockStrategy<T>,
        m_vault: &mut MultiAssetVault<SLP>,
        mut profit: Balance<T>,
        clock: &Clock
    ) {
        let vault_access = option::borrow(&self.vault_access);

        balance::join(
            &mut profit,
            balance::withdraw_all(&mut self.collected_profit)
        );
        mav::strategy_hand_over_profit(m_vault, vault_access, profit, clock);
    }

    public fun withdraw<T>(
        self: &mut MockStrategy<T>,
        ticket: &mut WithdrawTicket<SLP>
    ) {
        // it's possible to_withdraw amount exceed our current borrow_amt as the integrated valuts might apply different strategies that affect the principle amounts
        let to_withdraw = mav::withdraw_ticket_to_withdraw<T, SLP>(ticket, self.vault_access.borrow().vault_access_id());
        if (to_withdraw == 0) {
            return
        };

        let deposited_scoin_amt = self.scoin_balance.value();
        let withdrawal_scoin_amt = mul_div(
            deposited_scoin_amt,
            to_withdraw,
            self.underlying_value,
        );

        let withdrawal_scoin = self.scoin_balance.split(withdrawal_scoin_amt);
        let mut redeemed_bal = self.unstake(withdrawal_scoin);

        if (balance::value(&redeemed_bal) > to_withdraw) {
            let profit_amt = balance::value(&redeemed_bal) - to_withdraw;
            balance::join(
                &mut self.collected_profit, 
                balance::split(&mut redeemed_bal, profit_amt),
            );
        };

        mav::strategy_withdraw_to_ticket<T, SLP>(ticket, self.vault_access.borrow(), redeemed_bal);

        self.underlying_value = self.underlying_value - to_withdraw;
    }

    // === rewards test functions ===
    public fun acc_rewards<T>(
        self: &mut MockStrategy<T>,
        bal: Balance<T>
    ){
        self.reserve_coin.join(bal);
    }

    public fun take_rewards<T>(
        self: &mut MockStrategy<T>,
        val: u64
    ){
        self.reserve_coin.split(val).destroy_for_testing();
    }

    public fun stake<T>(
        self: &mut MockStrategy<T>,
        bal: Balance<T>
    ):Balance<SCOIN<T>>{
        let lp_amount = if (self.cap.supply_value() == 0) {
            bal.value()
        } else {
            mul_div(
                self.cap.supply_value(),
                bal.value(),
                self.reserve_coin.value()
            )
        };
        self.reserve_coin.join(bal);
        self.cap.increase_supply(lp_amount)
    }

    public fun unstake<T>(
        self: &mut MockStrategy<T>,
        bal: Balance<SCOIN<T>>
    ):Balance<T>{
        let withdrawl_amt = mul_div(bal.value(), self.reserve_coin.value(),self.cap.supply_value());
        self.cap.decrease_supply(bal);
        self.reserve_coin.split(withdrawl_amt)
    }
}
