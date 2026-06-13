## What

The per-country bank account models validate account numbers and bank/branch codes with **line-anchored** regexes (`/^...$/`). This switches them to **string anchors** (`/\A...\z/`) so the entire value must match.

In Ruby, `^` and `$` match at line boundaries, not string boundaries. So a value containing a newline slips through:

```ruby
/^\d{11,16}$/.match?("12345678901\n")          # => true  (accepted)
/\A\d{11,16}\z/.match?("12345678901\n")         # => false (rejected)
```

The change touches 62 country bank account models (104 regex constants). No valid single-line value is affected — only inputs with embedded/trailing newlines, which are not legal account or routing identifiers.

## Why

`bank_code` / `branch_code` form params are not stripped before validation (`update_payout_method.rb` strips `account_number` but passes the routing fields through `permit` verbatim). A value that passes a line-anchored regex is then sent to Stripe as the account/routing number via `bank_account_hash`, where it's rejected — leaving the bank account row saved locally but `stripe_bank_account_id` NULL, so payouts silently skip. This is the same silent-payout-failure mode addressed for specific countries in #5455 (Oman) and #5431 (Uzbekistan), but here it's a validation-anchoring issue rather than a per-country format one.

The fix follows the convention already present in the codebase: **26 of the bank account models already use `\A...\z`**, and `KenyaBankAccount`'s own account-number regex uses `\A...\z` while its bank-code regex still used `^...$` — a half-applied fix this completes.

## Demo

Test walkthrough (this is a backend validation change, so the proof is the test, not the UI): the new regression cases pass with the fix, fail when it's reverted to line anchors, and the full 100-country suite stays green.

▶️ **[Test demo video](https://raw.githubusercontent.com/roshangupta00750/gumroad/fix/bank-account-string-anchors/qa-media/bank-account-string-anchors-tests.mp4)** (also committed at `qa-media/bank-account-string-anchors-tests.mp4`)

## Test Results

Added regression coverage to `spec/models/armenia_bank_account_spec.rb` (a non-production-gated model exercising both a bank-code and an account-number regex): a trailing newline, and a value whose only matching line is a later one, are now rejected. These three cases fail when the change is reverted to `^...$` and pass with `\A...\z`.

- Targeted: `armenia_bank_account_spec` — 10 examples, 0 failures (3 fail on revert, confirming the guard).
- Regression sample across styles (SWIFT/BIC, numeric, sort-code, IFSC): armenia, kenya, nigeria, bahamas, uk, canadian, moldova, macao, gibraltar, uruguay — 74 examples, 0 failures.
- `rubocop` — 101 files, no offenses.
