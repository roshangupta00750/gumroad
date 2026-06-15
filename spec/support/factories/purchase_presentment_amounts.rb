# frozen_string_literal: true

FactoryBot.define do
  factory :purchase_presentment_amount do
    association :purchase, factory: :free_purchase
    presentment_currency { "eur" }
    presentment_amount_cents { 899 }
    usd_amount_cents { 999 }
    fx_rate { 0.92 }
    stripe_fx_quote_id { "fxq_test_123" }
  end
end
