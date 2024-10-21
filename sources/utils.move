module vault::utils{
    use std::u256;

    use sui::clock::{Self, Clock};

    const U64_MAX: u64 = 18446744073709551615;

    const U256_MAX: u256 = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

    const ERR_OVERFLOW: u64 = 001;
    const ERR_DIVIDE_BY_ZERO: u64 = 002;
    const DIVIDE_BY_ZERO: u64 = 003;
    const CALCULATION_OVERFLOW: u64 = 004;

    public fun timestamp_sec(clock: &Clock): u64 {
        clock::timestamp_ms(clock) / 1000
    }

    public fun mul_div(a: u64, b: u64, c: u64): u64 { 
        let a = (a as u128);
        let b = (b as u128);
        let c = (c as u128);
        let res = u128_mul_div(a, b, c);
        assert!(res <= ( U64_MAX as u128), ERR_OVERFLOW); 
        (res as u64)
    }
    
    public fun u128_mul_div(a: u128, b: u128, c: u128): u128 { 
        let (a,b) = if( a >= b ){
            (a, b)
        }else{
            (b, a)
        };
        assert!(c > 0, ERR_DIVIDE_BY_ZERO);

        ((a / c) * b) + (((a % c) * b) / c) 
    }

    public fun mul_div_round_up(a: u64, b: u64, c: u64): u64 {
        let ab = (a as u128) * (b as u128);
        let c = (c as u128);
        if (ab % c == 0) {
            ((ab / c) as u64)
        } else {
            ((ab / c + 1) as u64)
        }
    }


    /// Return the value of a * b / c
    public fun u256_mul_div(a: u256, b: u256, c: u256): u256 {
      let (a , b) = if (a >= b) {
        (a, b)
      } else {
        (b, a)
      };

      assert!(c > 0, DIVIDE_BY_ZERO);

      if (!is_safe_mul(a, b)) {
        // formula: ((a / c) * b) + (((a % c) * b) / c)
        checked_mul((a / c), b) + (checked_mul((a % c), b) / c)
      } else {
        a * b / c
      }
    }

  /// Return value of x * y with checking the overflow
  public fun checked_mul(x: u256, y: u256): u256 {
    assert!(is_safe_mul(x, y), CALCULATION_OVERFLOW);
    x * y
  }

  /// Check whether x * y doesn't lead to overflow
  public fun is_safe_mul(x: u256, y: u256): bool {
    (U256_MAX / x >= y)
  }

  public fun u256_mul_div_rounding(a: u256, b: u256, c: u256, rounding_up: bool): u256 {
    let r = u256_mul_div(a, b, c);
    if(rounding_up){
      r + if ((a * b) % c > 0) 1 else 0
    }else{
      r
    }
  }

}
