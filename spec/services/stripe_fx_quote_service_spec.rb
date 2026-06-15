# frozen_string_literal: true

require "spec_helper"

describe StripeFxQuoteService do
  def stripe_quote(id:, from:, rate:)
    Stripe::StripeObject.construct_from(
      id:,
      rates: { from => { exchange_rate: rate } },
    )
  end

  it "returns a locked quote with the id and rate from Stripe" do
    allow(Stripe::FxQuote).to receive(:create).and_return(
      stripe_quote(id: "fxq_123", from: "usd", rate: 0.79)
    )

    quote = described_class.lock(from_currency: "usd", to_currency: "gbp")

    expect(quote.id).to eq("fxq_123")
    expect(quote.rate).to eq(BigDecimal("0.79"))
    expect(quote.from_currency).to eq("usd")
    expect(quote.to_currency).to eq("gbp")
  end

  it "requests the quote from Stripe with the beta header and an hour lock" do
    expect(Stripe::FxQuote).to receive(:create).with(
      { from_currencies: ["usd"], to_currency: "gbp", lock_duration: "hour" },
      hash_including("Stripe-Version" => a_string_including("fx_quotes_beta=v1")),
    ).and_return(stripe_quote(id: "fxq_123", from: "usd", rate: 0.79))

    described_class.lock(from_currency: "usd", to_currency: "gbp")
  end

  it "names the destination account in usage for a destination charge" do
    expect(Stripe::FxQuote).to receive(:create).with(
      hash_including(usage: { type: "payment", payment: { destination: "acct_dest" } }),
      hash_not_including(:stripe_account),
    ).and_return(stripe_quote(id: "fxq_123", from: "usd", rate: 0.79))

    described_class.lock(from_currency: "usd", to_currency: "gbp", connected_account_id: "acct_dest")
  end

  it "quotes on the connected account via the Stripe-Account header for a direct charge" do
    expect(Stripe::FxQuote).to receive(:create).with(
      hash_including(usage: { type: "payment" }),
      hash_including(stripe_account: "acct_direct"),
    ).and_return(stripe_quote(id: "fxq_123", from: "usd", rate: 0.79))

    described_class.lock(from_currency: "usd", to_currency: "gbp", connected_account_id: "acct_direct", direct_charge: true)
  end

  it "sends no usage for a plain platform charge" do
    expect(Stripe::FxQuote).to receive(:create).with(
      hash_excluding(:usage),
      anything,
    ).and_return(stripe_quote(id: "fxq_123", from: "usd", rate: 0.79))

    described_class.lock(from_currency: "usd", to_currency: "gbp")
  end

  it "short-circuits to a rate of 1 with no Stripe call when currencies match" do
    expect(Stripe::FxQuote).not_to receive(:create)

    quote = described_class.lock(from_currency: "usd", to_currency: "usd")

    expect(quote.rate).to eq(BigDecimal("1"))
    expect(quote.id).to be_nil
  end

  it "returns nil when Stripe raises rather than charging at an unlocked rate" do
    allow(Stripe::FxQuote).to receive(:create).and_raise(Stripe::APIError.new("boom"))

    expect(described_class.lock(from_currency: "usd", to_currency: "gbp")).to be_nil
  end

  it "returns nil when Stripe returns a non-positive rate" do
    allow(Stripe::FxQuote).to receive(:create).and_return(
      stripe_quote(id: "fxq_123", from: "usd", rate: 0)
    )

    expect(described_class.lock(from_currency: "usd", to_currency: "gbp")).to be_nil
  end
end
