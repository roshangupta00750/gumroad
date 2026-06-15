# frozen_string_literal: true

require "spec_helper"

describe PresentmentCharge do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }

  def build_for(country:, usd: 9_99, fee: 1_50)
    described_class.build(
      product:,
      buyer_country_code: country,
      usd_amount_cents: usd,
      usd_application_fee_cents: fee,
    )
  end

  context "when the buyer should be charged in their local currency" do
    before do
      allow(PresentmentCurrency).to receive(:for).and_return("gbp")
      allow(StripeFxQuoteService).to receive(:lock).and_return(
        StripeFxQuoteService::Quote.new(id: "fxq_1", rate: BigDecimal("0.79"), from_currency: "usd", to_currency: "gbp")
      )
    end

    it "charges the rounded local total in the buyer's currency" do
      override = build_for(country: "GB")
      expect(override.currency).to eq("gbp")
      expect(override.amount_cents).to eq(799) # $9.99 * 0.79 -> clean £7.99
      expect(override.fx_quote_id).to eq("fxq_1")
      expect(override.usd_amount_cents).to eq(9_99)
    end

    it "converts Gumroad's fee at the locked rate and gives the seller the exact remainder" do
      override = build_for(country: "GB", fee: 1_50)
      expect(override.application_fee_cents).to eq((1_50 / 100.0 * 0.79 * 100).round) # 119
      expect(override.transfer_amount_cents).to eq(799 - 119) # seller gets total - fee
    end

    it "reconciles: fee + transfer always equals the amount charged to the buyer" do
      [1_50, 0, 9_99, 5_00].each do |fee|
        override = build_for(country: "GB", fee:)
        expect(override.application_fee_cents + override.transfer_amount_cents).to eq(override.amount_cents)
        expect(override.application_fee_cents).to be <= override.amount_cents
        expect(override.transfer_amount_cents).to be >= 0
      end
    end

    it "locks the rate against the resolved currency before converting" do
      build_for(country: "GB")
      expect(StripeFxQuoteService).to have_received(:lock).with(hash_including(from_currency: "usd", to_currency: "gbp"))
    end

    it "forwards the Connect context so the quote matches how the charge will settle" do
      described_class.build(
        product:, buyer_country_code: "GB", usd_amount_cents: 9_99, usd_application_fee_cents: 1_50,
        connected_account_id: "acct_9", direct_charge: true
      )
      expect(StripeFxQuoteService).to have_received(:lock).with(
        hash_including(connected_account_id: "acct_9", direct_charge: true)
      )
    end
  end

  it "returns nil (charge stays in USD) when the resolver picks USD" do
    allow(PresentmentCurrency).to receive(:for).and_return("usd")
    expect(build_for(country: "US")).to be_nil
  end

  it "returns nil (charge stays in USD) when no FX rate can be locked" do
    allow(PresentmentCurrency).to receive(:for).and_return("gbp")
    allow(StripeFxQuoteService).to receive(:lock).and_return(nil)
    expect(build_for(country: "GB")).to be_nil
  end

  it "handles zero-decimal currencies without inflating the fee by 100x" do
    allow(PresentmentCurrency).to receive(:for).and_return("jpy")
    allow(StripeFxQuoteService).to receive(:lock).and_return(
      StripeFxQuoteService::Quote.new(id: "fxq_2", rate: BigDecimal("140"), from_currency: "usd", to_currency: "jpy")
    )
    override = build_for(country: "JP", fee: 1_50)
    expect(override.application_fee_cents).to eq((1_50 / 100.0 * 140).round) # 210 yen, not 21000
  end
end
