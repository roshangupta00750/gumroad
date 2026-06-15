# frozen_string_literal: true

# Smart "Apple-style" rounding of buyer-currency prices for issue #5419
# (Multi-currency: buyer-currency charging).
#
# Given a product's base USD price and the FX-converted amount in the buyer's
# currency, this snaps the converted amount to a psychologically clean price
# point. The rounding granularity is chosen by the USD price tier (cheaper
# products round to finer increments, expensive ones to coarser ones), and
# zero-decimal currencies (JPY, KRW, ...) round to whole-unit increments with
# no fractional ending.
#
# NOTE: the tier table and example targets in #5419 are illustrative. The
# concrete rule implemented here is "round the converted amount to the nearest
# tier step, then drop one minor unit to land on a .99/.49-style ending"
# (and for zero-decimal currencies, just round to the nearest step). The exact
# target choices are the kind of thing the owning team would finalize.
module MultiCurrencyRounding
  module_function

  # [min_usd_cents (inclusive), max_usd_cents (exclusive), step in major units]
  USD_TIER_STEPS = [
    [0,      500,             0.50],  # < $5       -> .49 / .99
    [500,    2_500,           1.00],  # $5 - $25   -> .99
    [2_500,  10_000,          5.00],  # $25 - $100 -> x4.99 / x9.99
    [10_000, 50_000,          10.00], # $100 - $500-> x9.99
    [50_000, Float::INFINITY, 10.00], # $500+      -> x9.99
  ].freeze

  # Whole-unit rounding increments for zero-decimal currencies.
  ZERO_DECIMAL_STEPS = { "jpy" => 100, "krw" => 1000 }.freeze
  DEFAULT_ZERO_DECIMAL_STEP = 100

  # base_usd_cents:  product's USD price in cents (selects the rounding tier)
  # converted_cents: FX-converted amount in the buyer currency's smallest unit
  # currency:        ISO 4217 code, e.g. "eur", "jpy"
  # zero_decimal:    true for currencies with no minor unit (JPY, KRW, ...)
  #
  # Returns the rounded amount in the buyer currency's smallest unit.
  def round(base_usd_cents:, converted_cents:, currency:, zero_decimal: false)
    code = currency.to_s.downcase

    if zero_decimal
      step = ZERO_DECIMAL_STEPS.fetch(code, DEFAULT_ZERO_DECIMAL_STEP)
      return [round_to_nearest(converted_cents, step), step].max
    end

    step_minor = (tier_step(base_usd_cents) * 100).round
    rounded = round_to_nearest(converted_cents, step_minor)
    # Land on a psychological .99 / .49 ending, never below the smallest such
    # ending for the tier (so a tiny conversion floors to e.g. 0.49, not 0.01).
    [rounded - 1, step_minor - 1].max
  end

  def tier_step(usd_cents)
    USD_TIER_STEPS.find { |low, high, _step| usd_cents >= low && usd_cents < high }&.last ||
      USD_TIER_STEPS.last.last
  end

  def round_to_nearest(value, step)
    return value.round if step <= 0
    (value.to_f / step).round * step
  end
end
