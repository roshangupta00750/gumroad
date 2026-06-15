# frozen_string_literal: true

require "spec_helper"

describe BuyerPresentmentPrice do
  def amount(usd_cents, currency, rate)
    described_class.new(usd_cents:, buyer_currency: currency, fx_rate: rate).amount_cents
  end

  it "converts, smart-rounds, and returns a clean presentment price for decimal currencies" do
    expect(amount(999, "eur", 0.92)).to eq(899)    # $9.99 -> €8.99
    expect(amount(4999, "eur", 0.92)).to eq(4499)  # $49.99 -> €44.99
    expect(amount(19900, "eur", 0.92)).to eq(17999) # $199 -> €179.99
    expect(amount(999, "gbp", 0.79)).to eq(799)    # $9.99 -> £7.99
    expect(amount(999, "cad", 1.37)).to eq(1399)   # $9.99 -> CA$13.99
  end

  it "charges whole units for zero-decimal currencies (Stripe's list, not Gumroad config)" do
    expect(described_class.new(usd_cents: 999, buyer_currency: "jpy", fx_rate: 140.0).zero_decimal?).to be(true)
    expect(amount(999, "jpy", 140.0)).to eq(1400)  # $9.99 -> ¥1400
    # KRW is zero-decimal per Stripe even though Gumroad's single_unit config omits it.
    expect(described_class.new(usd_cents: 999, buyer_currency: "krw", fx_rate: 1350.0).zero_decimal?).to be(true)
  end

  it "floors at the currency minimum for tiny conversions" do
    # $0.50 -> ~€0.46, below EUR min (79) -> floored.
    expect(amount(50, "eur", 0.92)).to eq(79)
  end

  it "exposes a serializable summary" do
    expect(described_class.new(usd_cents: 999, buyer_currency: "eur", fx_rate: 0.92).to_h)
      .to eq(currency: "eur", amount_cents: 899, fx_rate: 0.92)
  end
end
