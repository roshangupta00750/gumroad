# frozen_string_literal: true

# Stripe's FX Quotes endpoint is still in beta and is not shipped as a typed
# resource in stripe-ruby 12.x, so we declare the minimal resource here. This is
# the gem's documented extension point for endpoints it doesn't model yet and
# gives us the usual `Stripe::FxQuote.create(params, opts)` call shape.
unless Stripe.const_defined?(:FxQuote)
  module Stripe
    class FxQuote < APIResource
      extend Stripe::APIOperations::Create

      OBJECT_NAME = "fx_quote"

      def self.resource_url
        "/v1/fx_quotes"
      end
    end
  end
end

# #5419 Multi-currency: buyer-currency charging.
#
# Thin wrapper over Stripe's FX Quotes API. When we charge a buyer in their local
# currency but settle/report in USD, the conversion rate must be *locked* at the
# moment of charge so the buyer-facing amount and the USD amount we record can never
# disagree because of a mid-flight rate move. Stripe issues a short-lived quote (an
# id plus the locked rate); we attach the id to the PaymentIntent so Stripe applies
# the exact same rate it quoted.
#
# Every failure path returns nil. A nil quote means "we could not lock a rate", and
# the caller falls back to charging in USD — i.e. today's behaviour. The conversion
# is never attempted at an unlocked or guessed rate.
class StripeFxQuoteService
  # Stripe's FX Quotes API is gated behind a beta header on the pinned API version.
  STRIPE_BETA_HEADER = { "Stripe-Version" => "#{Stripe.api_version}; fx_quotes_beta=v1" }.freeze

  # How long Stripe should hold the quoted rate. Allowed values are "none", "five_minutes",
  # "hour" and "day"; an hour comfortably covers the seconds between quoting and confirming
  # a charge without paying for a longer lock.
  LOCK_DURATION = "hour"

  Quote = Struct.new(:id, :rate, :from_currency, :to_currency, keyword_init: true)

  # connected_account_id + direct_charge describe the Connect context the quote will be
  # spent in. A Connect charge must be quoted the same way it is charged, or Stripe rejects
  # the fx_quote at charge time:
  #   - destination charge (transfer_data.destination): usage names the destination account
  #   - direct charge (Stripe-Account header):          usage is bare, quoted on that account
  # A nil connected_account_id is a plain platform charge needing no usage context.
  def initialize(from_currency:, to_currency:, connected_account_id: nil, direct_charge: false)
    @from_currency = from_currency.to_s.downcase
    @to_currency = to_currency.to_s.downcase
    @connected_account_id = connected_account_id
    @direct_charge = direct_charge
  end

  def self.lock(from_currency:, to_currency:, connected_account_id: nil, direct_charge: false)
    new(from_currency:, to_currency:, connected_account_id:, direct_charge:).lock
  end

  # Returns a Quote, or nil if a rate could not be locked. A same-currency request
  # needs no Stripe round-trip: the rate is exactly 1 and there is nothing to lock.
  def lock
    return Quote.new(id: nil, rate: BigDecimal("1"), from_currency: @from_currency, to_currency: @to_currency) if @from_currency == @to_currency

    response = Stripe::FxQuote.create(create_params, request_opts)

    rate = extract_rate(response)
    return if rate.nil? || rate <= 0

    Quote.new(id: response.id, rate:, from_currency: @from_currency, to_currency: @to_currency)
  rescue Stripe::StripeError => e
    Rails.logger.warn("StripeFxQuoteService failed for #{@from_currency}->#{@to_currency}: #{e.message}")
    nil
  end

  private
    def create_params
      params = {
        from_currencies: [@from_currency],
        to_currency: @to_currency,
        lock_duration: LOCK_DURATION,
      }
      params[:usage] = usage if usage
      params
    end

    # For a direct charge the quote is created on the connected account itself (via the
    # Stripe-Account header); for a destination charge it is created on the platform with
    # the destination named in usage. The beta header is always present.
    def request_opts
      opts = STRIPE_BETA_HEADER.dup
      opts[:stripe_account] = @connected_account_id if @connected_account_id && @direct_charge
      opts
    end

    def usage
      return if @connected_account_id.nil?
      return { type: "payment" } if @direct_charge

      { type: "payment", payment: { destination: @connected_account_id } }
    end

    # The quote nests the locked rate under rates[from_currency][:exchange_rate].
    # Stripe symbolizes object keys, so look the leg up by symbol. Defensive against
    # a shape change: anything unexpected reads as "no rate".
    def extract_rate(response)
      rates = response&.rates
      leg = rates && rates[@from_currency.to_sym]
      raw = leg&.respond_to?(:exchange_rate) ? leg.exchange_rate : nil
      raw && BigDecimal(raw.to_s)
    rescue ArgumentError, TypeError
      nil
    end
end
