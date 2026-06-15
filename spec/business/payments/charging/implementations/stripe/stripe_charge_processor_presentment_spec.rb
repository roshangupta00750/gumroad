# frozen_string_literal: true

require "spec_helper"

# #5419 Buyer-currency charging: verifies the params the charge processor sends to
# Stripe. Stripe is fully stubbed so these assert pure param construction — that a
# nil presentment is byte-for-byte today's USD charge, and a present one swaps in the
# locked-rate amounts and attaches the FX quote.
describe StripeChargeProcessor, "#create_payment_intent_or_charge! presentment params" do
  subject(:processor) { described_class.new }

  let(:chargeable) do
    instance_double(
      StripeChargeablePaymentMethod,
      stripe_charge_params: { payment_method: "pm_123" },
      requires_mandate?: false,
    )
  end

  let(:captured) { [] }
  let(:fake_intent) { double("Stripe::PaymentIntent", status: "succeeded") }

  before do
    allow(Stripe::PaymentIntent).to receive(:create) { |params, *| captured << params; fake_intent }
    allow(StripeChargeIntent).to receive(:new).and_return(double("StripeChargeIntent"))
  end

  def charge(merchant_account, presentment: nil)
    processor.create_payment_intent_or_charge!(
      merchant_account, chargeable, 9_99, 1_50, "reference", "desc", presentment:
    )
  end

  let(:presentment) do
    PresentmentCharge::Override.new(
      currency: "gbp", amount_cents: 799, application_fee_cents: 119,
      transfer_amount_cents: 671, fx_quote_id: "fxq_1", rate: BigDecimal("0.79"), usd_amount_cents: 9_99,
    )
  end

  context "with no merchant account (direct charge)" do
    let(:merchant_account) { instance_double(MerchantAccount, user: nil) }
    before { allow(processor).to receive(:merchant_migrated?).and_return(false) }

    it "charges in USD with the raw amount when presentment is nil" do
      charge(merchant_account)
      expect(captured.last).to include(amount: 9_99, currency: "usd")
      expect(captured.last).not_to have_key(:fx_quote)
    end

    it "charges the local amount and attaches the FX quote when presentment is present" do
      charge(merchant_account, presentment:)
      expect(captured.last).to include(amount: 799, currency: "gbp", fx_quote: "fxq_1")
    end
  end

  context "with a migrated merchant account (application fee)" do
    let(:merchant_account) { instance_double(MerchantAccount, user: build(:user), charge_processor_merchant_id: "acct_1") }
    before { allow(processor).to receive(:merchant_migrated?).and_return(true) }

    it "sends Gumroad's fee in USD when presentment is nil" do
      charge(merchant_account)
      expect(captured.last[:application_fee_amount]).to eq(1_50)
      expect(captured.last[:currency]).to eq("usd")
    end

    it "sends the locked-rate converted fee when presentment is present" do
      charge(merchant_account, presentment:)
      expect(captured.last[:application_fee_amount]).to eq(119)
      expect(captured.last).to include(currency: "gbp", fx_quote: "fxq_1")
    end
  end

  context "with a connected merchant account (transfer)" do
    let(:merchant_account) { instance_double(MerchantAccount, user: build(:user), charge_processor_merchant_id: "acct_2") }
    before { allow(processor).to receive(:merchant_migrated?).and_return(false) }

    it "transfers the USD remainder when presentment is nil" do
      charge(merchant_account)
      expect(captured.last[:transfer_data]).to eq(destination: "acct_2", amount: 9_99 - 1_50)
    end

    it "transfers the locked-rate converted amount when presentment is present" do
      charge(merchant_account, presentment:)
      expect(captured.last[:transfer_data]).to eq(destination: "acct_2", amount: 671)
      expect(captured.last).to include(currency: "gbp", fx_quote: "fxq_1")
    end
  end
end
