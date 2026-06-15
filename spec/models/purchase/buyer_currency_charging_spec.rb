# frozen_string_literal: true

require "spec_helper"

# #5419 Wiring of buyer-currency charging into the purchase charge path. The pricing,
# resolver, FX-quote and seam logic are covered by their own specs; here we verify the
# purchase-level glue: building the override from purchase context, and persisting it.
describe Purchase, "buyer-currency charging (#5419)" do
  let(:product) { create(:product) }
  let(:chargeable) { double("chargeable", country: "GB") }

  describe "#buyer_currency_presentment" do
    let(:purchase) { build(:purchase, link: product) }

    it "returns nil for a non-Stripe processor (FX quotes are Stripe-only)" do
      allow(purchase).to receive(:merchant_account).and_return(
        instance_double(MerchantAccount, charge_processor_id: PaypalChargeProcessor.charge_processor_id)
      )
      expect(purchase.send(:buyer_currency_presentment, chargeable, 9_99, 1_50)).to be_nil
    end

    it "builds the override from the purchase context for a Stripe destination charge" do
      allow(purchase).to receive(:merchant_account).and_return(
        instance_double(MerchantAccount,
                        charge_processor_id: StripeChargeProcessor.charge_processor_id,
                        charge_processor_merchant_id: "acct_1",
                        is_a_stripe_connect_account?: false)
      )
      expect(PresentmentCharge).to receive(:build).with(
        product:,
        buyer_country_code: "GB",
        usd_amount_cents: 9_99,
        usd_application_fee_cents: 1_50,
        connected_account_id: "acct_1",
        direct_charge: false,
      ).and_return(:override)

      expect(purchase.send(:buyer_currency_presentment, chargeable, 9_99, 1_50)).to eq(:override)
    end

    it "marks the charge as direct when the merchant is a Stripe Connect account" do
      allow(purchase).to receive(:merchant_account).and_return(
        instance_double(MerchantAccount,
                        charge_processor_id: StripeChargeProcessor.charge_processor_id,
                        charge_processor_merchant_id: "acct_2",
                        is_a_stripe_connect_account?: true)
      )
      expect(PresentmentCharge).to receive(:build).with(hash_including(direct_charge: true)).and_return(:override)
      purchase.send(:buyer_currency_presentment, chargeable, 9_99, 1_50)
    end
  end

  describe "#store_presentment_amount!" do
    let(:purchase) { create(:free_purchase) }
    let(:override) do
      PresentmentCharge::Override.new(
        currency: "gbp", amount_cents: 799, application_fee_cents: 119,
        transfer_amount_cents: 680, fx_quote_id: "fxq_1", rate: BigDecimal("0.79"), usd_amount_cents: 9_99,
      )
    end

    it "persists the presentment amount from the override, reachable from the purchase" do
      purchase.send(:store_presentment_amount!, override)
      ppa = purchase.reload.purchase_presentment_amount
      expect(ppa.presentment_currency).to eq("gbp")
      expect(ppa.presentment_amount_cents).to eq(799)
      expect(ppa.usd_amount_cents).to eq(9_99)
      expect(ppa.stripe_fx_quote_id).to eq("fxq_1")
      expect(ppa.fx_rate).to eq(BigDecimal("0.79"))
    end

    it "does not create a second record if one already exists" do
      purchase.send(:store_presentment_amount!, override)
      expect { purchase.send(:store_presentment_amount!, override) }
        .not_to change { PurchasePresentmentAmount.count }
    end
  end
end
