# frozen_string_literal: true

require "spec_helper"

describe PurchasePresentmentAmount do
  it "persists and is reachable from its purchase via has_one" do
    ppa = create(:purchase_presentment_amount)
    expect(ppa.purchase.reload.purchase_presentment_amount).to eq(ppa)
  end

  it "is unique per purchase" do
    ppa = create(:purchase_presentment_amount)
    expect(build(:purchase_presentment_amount, purchase: ppa.purchase)).not_to be_valid
  end

  it "requires a currency and positive amounts" do
    expect(build(:purchase_presentment_amount, presentment_currency: nil)).not_to be_valid
    expect(build(:purchase_presentment_amount, presentment_amount_cents: 0)).not_to be_valid
    expect(build(:purchase_presentment_amount, usd_amount_cents: -1)).not_to be_valid
  end

  it "is destroyed with its purchase" do
    ppa = create(:purchase_presentment_amount)
    purchase = ppa.purchase
    expect { purchase.destroy }.to change { described_class.count }.by(-1)
  end
end
