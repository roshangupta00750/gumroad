# frozen_string_literal: true

require "spec_helper"

describe PresentmentCurrency do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }
  let(:currency_namespace) { Redis::Namespace.new(:currencies, redis: $redis) }

  before do
    Feature.activate(:buyer_local_currency)
    seller.update!(disable_buyer_local_currency: false)
    # Warm a GBP cross-rate so chargeable currencies have a usable rate.
    currency_namespace.set("GBP", "0.79")
  end

  def resolve(country)
    described_class.for(product:, buyer_country_code: country)
  end

  it "charges in the buyer's local currency when the seller opted in and the currency is supported" do
    expect(resolve("GB")).to eq("gbp")
  end

  it "falls back to USD when the seller has not opted in" do
    seller.update!(disable_buyer_local_currency: true)
    expect(resolve("GB")).to eq("usd")
  end

  it "falls back to USD when the feature flag is off" do
    Feature.deactivate(:buyer_local_currency)
    expect(resolve("GB")).to eq("usd")
  end

  it "falls back to USD for a country whose currency Gumroad does not support" do
    expect(resolve("VN")).to eq("usd")
  end

  it "falls back to USD when no warm FX rate is available" do
    currency_namespace.del("GBP")
    expect(resolve("GB")).to eq("usd")
  end

  it "falls back to USD when the buyer country is unknown" do
    expect(resolve(nil)).to eq("usd")
  end

  it "charges US buyers in USD without needing a rate" do
    expect(resolve("US")).to eq("usd")
  end

  # Sourcing the chargeable set from CURRENCY_CHOICES (rather than a hand-maintained
  # allow-list) means every currency Gumroad prices in is chargeable. These were
  # supported for pricing but previously fell back to USD at charge time.
  {
    "PH" => "php",
    "TW" => "twd",
  }.each do |country, currency|
    it "charges #{country} buyers in #{currency} now that the chargeable set tracks CURRENCY_CHOICES" do
      currency_namespace.set(currency.upcase, "1200")
      expect(resolve(country)).to eq(currency)
    end
  end

  # KRW is zero-decimal at Stripe but Gumroad's config models it with cents (no
  # single_unit flag, min_price 111000). Charging it would floor a $9.99 product to
  # ₩111,000 (~$82), so it must fall back to USD even with a warm rate.
  it "falls back to USD for KRW because Stripe and Gumroad disagree on its minor unit" do
    currency_namespace.set("KRW", "1350")
    expect(resolve("KR")).to eq("usd")
  end

  it "still charges JPY locally (Stripe and Gumroad agree it is zero-decimal)" do
    currency_namespace.set("JPY", "150")
    expect(resolve("JP")).to eq("jpy")
  end

  it "only charges locally in currencies Gumroad supports for pricing" do
    CURRENCY_CHOICES.each_key do |currency|
      next if currency == "usd"
      currency_namespace.set(currency.upcase, "2")
    end
    # A currency Gumroad does not price in (Vietnamese dong) still falls back to USD.
    expect(resolve("VN")).to eq("usd")
  end
end
