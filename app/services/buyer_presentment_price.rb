# frozen_string_literal: true

# #5419 Multi-currency: computes the price a buyer is charged in THEIR currency.
#
# Given a product's USD price and an FX rate (buyer major units per 1 USD, from
# Stripe's FX Quotes API), it converts to the buyer's currency, applies Apple-style
# smart rounding (MultiCurrencyRounding), and floors at the currency's minimum.
#
# Zero-decimal-ness is sourced from Stripe's canonical list (the authority for what
# Stripe charges), not Gumroad's per-currency `single_unit` config, which does not
# cover every zero-decimal currency (e.g. KRW).
class BuyerPresentmentPrice
  include CurrencyHelper

  # Stripe zero-decimal currencies: the charge amount is in whole units (no minor unit).
  ZERO_DECIMAL_CURRENCIES = %w[
    bif clp djf gnf jpy kmf krw mga pyg rwf ugx vnd vuv xaf xof xpf
  ].freeze

  def initialize(usd_cents:, buyer_currency:, fx_rate:)
    @usd_cents = usd_cents
    @buyer_currency = buyer_currency.to_s.downcase
    @fx_rate = fx_rate
  end

  # Amount to charge the buyer, in the currency's smallest chargeable unit
  # (whole units for zero-decimal currencies, cents otherwise).
  def amount_cents
    buyer_major = (usd_cents / 100.0) * fx_rate
    converted = zero_decimal? ? buyer_major.round : (buyer_major * 100).round
    rounded = MultiCurrencyRounding.round(
      base_usd_cents: usd_cents,
      converted_cents: converted,
      currency: buyer_currency,
      zero_decimal: zero_decimal?
    )
    [rounded, min_price_for(buyer_currency)].max
  end

  def zero_decimal?
    ZERO_DECIMAL_CURRENCIES.include?(buyer_currency)
  end

  def to_h
    { currency: buyer_currency, amount_cents:, fx_rate: }
  end

  private
    attr_reader :usd_cents, :buyer_currency, :fx_rate
end
