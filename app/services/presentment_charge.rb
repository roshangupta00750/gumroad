# frozen_string_literal: true

# #5419 Multi-currency: buyer-currency charging.
#
# Single composition point for charging a buyer in their local currency. Given the
# USD amounts Gumroad computes internally (the charge total and Gumroad's cut), it:
#
#   1. resolves whether this buyer should be charged locally at all (PresentmentCurrency),
#   2. locks an FX rate with Stripe so the rate cannot move mid-charge (StripeFxQuoteService),
#   3. converts every USD amount the charge needs — the total, Gumroad's application
#      fee, and the seller's transfer — through that one locked rate, and
#   4. rounds the buyer-facing total to a clean local price (BuyerPresentmentPrice).
#
# Returns nil whenever the charge should stay in USD (seller not opted in, unsupported
# currency, no lockable rate). nil means "charge exactly as today", so wiring this in
# can never change an existing USD charge.
#
# The buyer pays the rounded local total. Gumroad's cut is that total converted at the
# locked rate, and the seller's transfer is the exact remainder (total - fee). Anchoring
# the split on the rounded total — rather than converting fee and transfer independently
# — guarantees fee + transfer == amount to the cent, which is what both Stripe branches
# require (application_fee_amount <= amount; transfer_data.amount <= amount). There is
# only ever one split number in Gumroad's model (the fee); the transfer is its complement.
class PresentmentCharge
  include CurrencyHelper

  Override = Struct.new(
    :currency, :amount_cents, :application_fee_cents, :transfer_amount_cents,
    :fx_quote_id, :rate, :usd_amount_cents,
    keyword_init: true,
  )

  def initialize(product:, buyer_country_code:, usd_amount_cents:, usd_application_fee_cents:,
                 connected_account_id: nil, direct_charge: false)
    @product = product
    @buyer_country_code = buyer_country_code
    @usd_amount_cents = usd_amount_cents
    @usd_application_fee_cents = usd_application_fee_cents
    @connected_account_id = connected_account_id
    @direct_charge = direct_charge
  end

  def self.build(**kwargs)
    new(**kwargs).build
  end

  def build
    currency = PresentmentCurrency.for(product: @product, buyer_country_code: @buyer_country_code)
    return if currency == Currency::USD

    quote = StripeFxQuoteService.lock(
      from_currency: Currency::USD, to_currency: currency,
      connected_account_id: @connected_account_id, direct_charge: @direct_charge
    )
    return if quote.nil?

    amount_cents = BuyerPresentmentPrice.new(
      usd_cents: @usd_amount_cents, buyer_currency: currency, fx_rate: quote.rate
    ).amount_cents

    # Clamp the converted fee to the amount so the transfer can never go negative
    # (only possible for pathological fee-near-total cases after rounding).
    application_fee_cents = [convert(@usd_application_fee_cents, currency, quote.rate), amount_cents].min

    Override.new(
      currency:,
      amount_cents:,
      application_fee_cents:,
      transfer_amount_cents: amount_cents - application_fee_cents,
      fx_quote_id: quote.id,
      rate: quote.rate,
      usd_amount_cents: @usd_amount_cents,
    )
  end

  private
    # Converts a USD minor-unit amount into the target currency's minor units at the
    # locked rate, honouring zero-decimal currencies (where the minor unit is the unit).
    def convert(usd_cents, currency, rate)
      major = (usd_cents / 100.0) * rate.to_f
      if BuyerPresentmentPrice::ZERO_DECIMAL_CURRENCIES.include?(currency)
        major.round
      else
        (major * 100).round
      end
    end
end
