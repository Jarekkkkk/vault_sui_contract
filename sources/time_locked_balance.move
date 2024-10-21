module vault::time_locked_balance {
    // === Imports ===
    use sui::balance::{Self, Balance};
    use sui::math;
    use sui::clock::Clock;

    use vault::utils::timestamp_sec;

    // === Structs ===
    /// Wraps a `Balance<T>` and allows only `unlock_per_second` of it to be withdrawn
    /// per second starting from `unlock_start_ts_sec`. All timestamp fields are unix timestamp.
    public struct TimeLockedBalance<phantom T> has store {
        locked_balance: Balance<T>,
        unlock_start_ts_sec: u64,
        unlock_per_second: u64,

        /// Balance that gets unlocked and is withdrawable is stored here.
        unlocked_balance: Balance<T>,
        /// Time at which all of the balance will become unlocked. Unix timestamp.
        final_unlock_ts_sec: u64,

        previous_unlock_at: u64
    }

    // === Method Aliases ===
    #[test_only]
    public use fun vault::vault_test_utils::assert_time_locked_balance_info as TimeLockedBalance.assert_time_locked_balance_info;

    // === Public-Mutative Functions ===

    // === Public-View Functions ===

    public fun locked_balance<T>(self: &TimeLockedBalance<T>): &Balance<T> {
        &self.locked_balance
    }

    public fun unlock_start_ts_sec<T>(self: &TimeLockedBalance<T>): u64 {
        self.unlock_start_ts_sec
    }

    public fun unlock_per_second<T>(self: &TimeLockedBalance<T>): u64 {
        self.unlock_per_second
    }

    public fun unlocked_balance<T>(self: &TimeLockedBalance<T>): &Balance<T> {
        &self.unlocked_balance
    }

    public fun final_unlock_ts_sec<T>(self: &TimeLockedBalance<T>): u64 {
        self.final_unlock_ts_sec
    }

    public fun previous_unlock_at<T>(self: &TimeLockedBalance<T>): u64 {
        self.previous_unlock_at
    }

    public fun get_values<T>(self: &TimeLockedBalance<T>): (u64, u64, u64) {
        (self.unlock_start_ts_sec, self.unlock_per_second, self.final_unlock_ts_sec)
    }

    // === Public-Package Functions ===

    /// Creates a new `TimeLockedBalance<T>` that will start unlocking at `unlock_start_ts_sec` and
    /// unlock `unlock_per_second` of balance per second.
    public fun create<T>(
        locked_balance: Balance<T>, 
        unlock_start_ts_sec: u64, 
        unlock_per_second: u64
    ): TimeLockedBalance<T> {
        let final_unlock_ts_sec = calc_final_unlock_ts_sec(
            unlock_start_ts_sec, locked_balance.value(), unlock_per_second
        );
        TimeLockedBalance {
            locked_balance,
            unlock_start_ts_sec,
            unlock_per_second,

            unlocked_balance: balance::zero<T>(),
            final_unlock_ts_sec,

            previous_unlock_at: 0
        }
    }

    /// Returns the value of extraneous balance.
    /// Since `locked_balance` amount might not be evenly divisible by `unlock_per_second`, there will be some
    /// extraneous balance. E.g. if `locked_balance` is 21 and `unlock_per_second` is 10, this function will
    /// return 1. Extraneous balance can be withdrawn by calling `skim_extraneous_balance` at any time.
    /// When `unlock_per_second` is 0, all balance in `locked_balance` is considered extraneous. This makes
    /// it possible to empty the `locked_balance` by setting `unlock_per_second` to 0 and then skimming.
    public fun extraneous_locked_amount<T>(self: &TimeLockedBalance<T>): u64 {
        if (self.unlock_per_second == 0) {
            self.locked_balance.value()
        } else {
            self.locked_balance.value() % self.unlock_per_second
        }
    }

    /// Returns the max. available amount that can be withdrawn at this time.
    public fun max_withdrawable<T>(self: &TimeLockedBalance<T>, clock: &Clock): u64 {
        self.unlocked_balance.value() + self.unlockable_amount(clock)
    }

    /// Returns the total amount of balance that is yet to be unlocked.
    public fun remaining_unlock<T>(self: &TimeLockedBalance<T>, clock: &Clock): u64 {
        let start = math::max(self.unlock_start_ts_sec, timestamp_sec(clock));
        if (start >= self.final_unlock_ts_sec) {
            return 0
        };

        (self.final_unlock_ts_sec - start) * self.unlock_per_second
    }

    /// Withdraws the specified (unlocked) amount. Errors if amount exceeds max. withdrawable.
    public fun withdraw<T>(
        self: &mut TimeLockedBalance<T>, 
        amount: u64, 
        clock: &Clock
    ): Balance<T> {
        unlock(self, clock);
        self.unlocked_balance.split(amount)
    }

    /// Withdraws all available (unlocked) balance.
    public fun withdraw_all<T>(self: &mut TimeLockedBalance<T>, clock: &Clock): Balance<T> {
        unlock(self, clock);
        self.unlocked_balance.withdraw_all()
    }

    /// Adds additional balance to be distributed (i.e. prolongs the duration of distribution).
    public fun top_up<T>(
        self: &mut TimeLockedBalance<T>, 
        balance: Balance<T>, 
        clock: &Clock
    ) {
        unlock(self, clock);
        self.locked_balance.join(balance);
        self.final_unlock_ts_sec = calc_final_unlock_ts_sec(
            math::max(self.unlock_start_ts_sec, timestamp_sec(clock)),
            self.locked_balance.value(),
            self.unlock_per_second
        );
    }

    /// Changes `unlock_per_second` to a new value. New value is effective starting from the
    /// current timestamp (unlocks up to and including the current timestamp are based on the previous value).
    public fun change_unlock_per_second<T>(
        self: &mut TimeLockedBalance<T>, 
        new_unlock_per_second: u64, 
        clock: &Clock
    ) {
        unlock(self, clock);

        self.unlock_per_second = new_unlock_per_second;
        self.final_unlock_ts_sec = calc_final_unlock_ts_sec(
            math::max(self.unlock_start_ts_sec, timestamp_sec(clock)),
            self.locked_balance.value(),
            new_unlock_per_second
        );
    }

    /// Changes `unlock_start_ts_sec` to a new value. If the new value is in the past, it will be set to the current time.
    public fun change_unlock_start_ts_sec<T>(
        self: &mut TimeLockedBalance<T>, 
        new_unlock_start_ts_sec: u64, 
        clock: &Clock
    ) {
        unlock(self, clock);

        let new_unlock_start_ts_sec = math::max(new_unlock_start_ts_sec, timestamp_sec(clock));
        self.unlock_start_ts_sec = new_unlock_start_ts_sec;
        self.final_unlock_ts_sec = calc_final_unlock_ts_sec(
            new_unlock_start_ts_sec,
            self.locked_balance.value(),
            self.unlock_per_second
        );
    }

    /// Skims extraneous balance. Since `locked_balance` might not be evenly divisible by, and balance
    /// is unlocked only in the multiples of `unlock_per_second`, there might be some extra balance that will
    /// not be distributed (e.g. if `locked_balance` is 21 `unlock_per_second` is 10, the extraneous
    /// balance will be 1). This balance can be retrieved using this function.
    /// When `unlock_per_second` is set to 0, all of the balance in `locked_balance` is considered extraneous.
    public fun skim_extraneous_balance<T>(self: &mut TimeLockedBalance<T>): Balance<T> {
        let amount = extraneous_locked_amount(self);
        self.locked_balance.split(amount)
    }

    /// Destroys the `TimeLockedBalance<T>` when its balances are empty.
    public fun destroy_empty<T>(self: TimeLockedBalance<T>) {
        let TimeLockedBalance {
            locked_balance,
            unlock_start_ts_sec: _,
            unlock_per_second: _,
            unlocked_balance,
            final_unlock_ts_sec: _,
            previous_unlock_at: _
        } = self;
        locked_balance.destroy_zero();
        unlocked_balance.destroy_zero();
    }

    // === Private Functions ===

    /// Helper function to calculate the `final_unlock_ts_sec`. Returns 0 when `unlock_per_second` is 0.
    fun calc_final_unlock_ts_sec(
        start_ts: u64,
        amount_to_issue: u64,
        unlock_per_second: u64,
    ): u64 {
        if (unlock_per_second == 0) {
            0
        } else {
            start_ts + (amount_to_issue / unlock_per_second)
        }
    }

    #[test]
    fun test_calc_final_unlock_ts_sec() {
        assert!(calc_final_unlock_ts_sec(100, 30, 20) == 101, 0);
        assert!(calc_final_unlock_ts_sec(100, 60, 30) == 102, 0);
        assert!(calc_final_unlock_ts_sec(100, 29, 30) == 100, 0);
        assert!(calc_final_unlock_ts_sec(100, 60, 0) == 0, 0);
        assert!(calc_final_unlock_ts_sec(100, 0, 20) == 100, 0);
        assert!(calc_final_unlock_ts_sec(100, 0, 0) == 0, 0);
    }

    /// Returns the amount of `locked_balance` that can be unlocked at this time.
    fun unlockable_amount<T>(self: &TimeLockedBalance<T>, clock: &Clock): u64 {
        if (self.unlock_per_second == 0) {
            return 0
        };
        let now = timestamp_sec(clock);
        if (now <= self.unlock_start_ts_sec) return 0; // yet unlocked

        let to_remain_locked = (self.final_unlock_ts_sec - math::min(self.final_unlock_ts_sec, now)) * self.unlock_per_second;

        let locked_amount_round = self.locked_balance.value() / self.unlock_per_second * self.unlock_per_second;

        locked_amount_round - to_remain_locked
    }

    /// Unlocks the balance that is unlockable based on the time passed since previous unlock.
    /// Moves the amount from `locked_balance` to `unlocked_balance`.
    fun unlock<T>(self: &mut TimeLockedBalance<T>, clock: &Clock) {
        let now = timestamp_sec(clock);
        if (self.previous_unlock_at == now) return;

        let amount = unlockable_amount(self, clock);
        self.unlocked_balance.join(self.locked_balance.split(amount));

        self.previous_unlock_at = now;
    }

    // === Test Functions ===
    #[test_only]
    public fun destroy_for_testing<T>(self: TimeLockedBalance<T>) {
        let TimeLockedBalance {
            locked_balance,
            unlock_start_ts_sec: _,
            unlock_per_second: _,
            unlocked_balance,
            final_unlock_ts_sec: _,
            previous_unlock_at: _
        } = self;
        locked_balance.destroy_for_testing();
        unlocked_balance.destroy_for_testing();
    }

    #[test_only]
    public fun get_all_values<T>(self: &TimeLockedBalance<T>): (u64, u64, u64, u64, u64) {
        (
            self.locked_balance.value(),
            self.unlock_start_ts_sec,
            self.unlock_per_second,
            self.unlocked_balance.value(),
            self.final_unlock_ts_sec
        )
    }
}
