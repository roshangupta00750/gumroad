# frozen_string_literal: true

class CreatePurchasePresentmentAmounts < ActiveRecord::Migration[7.1]
  def change
    create_table :purchase_presentment_amounts do |t|
      t.bigint :purchase_id, null: false
      t.string :presentment_currency, null: false
      t.integer :presentment_amount_cents, null: false
      t.integer :usd_amount_cents, null: false
      t.string :stripe_fx_quote_id
      t.decimal :fx_rate, precision: 20, scale: 10
      t.timestamps

      t.index :purchase_id, unique: true, name: "index_purchase_presentment_amounts_on_purchase_id"
    end
  end
end
