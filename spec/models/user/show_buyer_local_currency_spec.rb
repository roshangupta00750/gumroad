# frozen_string_literal: true

require "spec_helper"

describe User do
  describe "#show_buyer_local_currency" do
    it "reads and writes the creator opt-in attribute" do
      seller = create(:user, show_buyer_local_currency: true)

      expect(seller.show_buyer_local_currency).to eq(true)

      seller.update!(show_buyer_local_currency: false)

      expect(seller.reload.show_buyer_local_currency).to eq(false)
    end

    it "defaults to false when the creator has not opted in" do
      expect(create(:user).show_buyer_local_currency).to eq(false)
    end
  end
end
