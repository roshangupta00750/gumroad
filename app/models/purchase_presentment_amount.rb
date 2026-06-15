# frozen_string_literal: true

# #5419 Multi-currency: the buyer-currency (presentment) amount actually charged,
# stored alongside the USD-internal Purchase so fees/tax/payout accounting stays USD.
# Kept in its own table because columns cannot be added to `purchases`.
class PurchasePresentmentAmount < ApplicationRecord
  belongs_to :purchase

  validates :purchase, presence: true, uniqueness: true
  validates :presentment_currency, presence: true
  validates :presentment_amount_cents, presence: true, numericality: { greater_than: 0 }
  validates :usd_amount_cents, presence: true, numericality: { greater_than: 0 }
end
