# frozen_string_literal: true

# #5419 Multi-currency: buyer-currency charging.
#
# Decides which currency a given buyer should actually be *charged* in. Charging
# (unlike display) is irreversible and settles money, so the bar is stricter than
# `CurrencyHelper#buyer_currency_for_country`: on top of "is this a currency we
# support at all", we require that the seller opted in and that a usable FX rate is
# warm. Any failed check falls back to USD — the seller's set price is charged as-is,
# which is exactly today's behaviour, so the resolver can never make a charge worse.
#
# The chargeable set is exactly `CURRENCY_CHOICES` (config/currencies.json): the
# currencies Gumroad already lets sellers price in, which Stripe settles and for
# which we keep min-price config and warm rates. Deriving from that single source
# (rather than a parallel hand-maintained allow-list) means a currency can never be
# priceable-but-not-chargeable or vice versa, and new supported currencies are picked
# up automatically.
class PresentmentCurrency
  include CurrencyHelper

  def initialize(product:, buyer_country_code:)
    @product = product
    @buyer_country_code = buyer_country_code
  end

  def self.for(product:, buyer_country_code:)
    new(product:, buyer_country_code:).resolve
  end

  # Returns a downcased ISO currency code we are willing to charge in. Never nil:
  # the worst case is "usd", so callers can charge unconditionally.
  def resolve
    return DEFAULT_CURRENCY unless seller_opted_in?

    candidate = buyer_currency_for_country(@buyer_country_code)
    return DEFAULT_CURRENCY if candidate.blank?
    return DEFAULT_CURRENCY unless chargeable?(candidate)

    candidate
  end

  DEFAULT_CURRENCY = Currency::USD

  private
    def seller_opted_in?
      seller = @product.user
      !seller.disable_buyer_local_currency? &&
        Feature.active?(:buyer_local_currency, seller)
    end

    # A currency is chargeable only if Gumroad supports pricing in it (so Stripe will
    # settle it and we hold its config), Stripe and Gumroad agree on its minor-unit
    # model, AND we have a warm USD cross-rate to size the amount. A cold rate degrades
    # to USD instead of charging at a stale or missing rate.
    def chargeable?(currency)
      return false unless CURRENCY_CHOICES.key?(currency)
      return false unless minor_unit_models_agree?(currency)
      return true if currency == DEFAULT_CURRENCY

      buyer_local_currency_rate(from_currency: DEFAULT_CURRENCY, to_currency: currency).present?
    end

    # Stripe and Gumroad must agree on whether the currency has a minor unit. When they
    # disagree, the amount we compute (in Stripe's unit) and the min-price floor we apply
    # (in Gumroad's unit) sit on different scales and can overcharge by ~100x. KRW is the
    # live example: Stripe charges it zero-decimal, but Gumroad models it with cents and a
    # min_price of 111000, so a $9.99 product would charge ₩111,000. We fall back to USD
    # for any such currency until its config is reconciled.
    def minor_unit_models_agree?(currency)
      BuyerPresentmentPrice::ZERO_DECIMAL_CURRENCIES.include?(currency) == is_currency_type_single_unit?(currency)
    end
end
