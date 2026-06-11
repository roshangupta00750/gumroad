# frozen_string_literal: true

require "spec_helper"

describe AudienceMember::Searchable, :freeze_time do
  describe "#as_indexed_json" do
    let(:member) do
      create(
        :audience_member,
        details: {
          "purchases" => [{ "id" => 1, "product_id" => 2, "variant_ids" => [3, 4], "price_cents" => 100, "created_at" => 2.days.ago.iso8601, "country" => "United States" }],
          "follower" => { "id" => 5, "created_at" => 7.days.ago.iso8601 },
          "affiliates" => [{ "id" => 6, "product_id" => 7, "created_at" => 1.day.ago.iso8601 }],
        }
      ).reload
    end

    it "includes all mapped fields" do
      expect(member.as_indexed_json).to eq(
        "seller_id" => member.seller_id,
        "customer" => true,
        "follower" => true,
        "affiliate" => true,
        "min_paid_cents" => 100,
        "max_paid_cents" => 100,
        "min_created_at" => member.min_created_at.as_json,
        "max_created_at" => member.max_created_at.as_json,
        "min_purchase_created_at" => member.min_purchase_created_at.as_json,
        "max_purchase_created_at" => member.max_purchase_created_at.as_json,
        "follower_created_at" => member.follower_created_at.as_json,
        "min_affiliate_created_at" => member.min_affiliate_created_at.as_json,
        "max_affiliate_created_at" => member.max_affiliate_created_at.as_json,
        "follower_id" => 5,
        "purchases" => [{ "id" => 1, "product_id" => 2, "variant_ids" => [3, 4], "price_cents" => 100, "created_at" => 2.days.ago.iso8601, "country" => "United States" }],
        "affiliates" => [{ "id" => 6, "product_id" => 7, "created_at" => 1.day.ago.iso8601 }],
      )
    end

    it "allows only a selection of fields to be used" do
      expect(member.as_indexed_json(only: %w[seller_id customer follower_id])).to eq(
        "seller_id" => member.seller_id,
        "customer" => true,
        "follower_id" => 5,
      )
    end
  end

  describe ".elasticsearch_filter_count", :sidekiq_inline, :elasticsearch_wait_for_refresh do
    let(:seller) { create(:user) }
    let(:seller_id) { seller.id }

    it "counts all members with no params" do
      create_member(follower: {})
      create_member(purchases: [{}])

      expect_filter_count(2, {})
    end

    it "counts by type" do
      create_member(purchases: [{}])
      create_member(follower: {})
      create_member(affiliates: [{}])
      create_member(purchases: [{}], follower: {}, affiliates: [{}])

      expect_filter_count(2, type: "customer")
      expect_filter_count(2, type: "follower")
      expect_filter_count(2, type: "affiliate")
    end

    it "raises error for invalid type" do
      expect { es_count({ type: "invalid_type" }) }.to raise_error(ArgumentError, /Invalid type: invalid_type/)
      expect { es_count({ type: "'; DROP TABLE audience_members; --" }) }.to raise_error(ArgumentError, /Invalid type/)
    end

    it "counts by purchased and not-purchased products and variants" do
      create_member(purchases: [{ "product_id" => 1 }])
      create_member(purchases: [{ "product_id" => 2 }])
      create_member(purchases: [{ "product_id" => 2, "variant_ids" => [1] }])
      create_member(purchases: [{ "product_id" => 2, "variant_ids" => [2] }])
      create_member(purchases: [{ "product_id" => 1 }, { "product_id" => 2, "variant_ids" => [1] }])
      create_member(purchases: [{ "product_id" => 1 }, { "product_id" => 2, "variant_ids" => [1, 2] }])

      expect_filter_count(3, bought_product_ids: [1])
      expect_filter_count(5, bought_product_ids: [2])
      expect_filter_count(6, bought_product_ids: [1, 2])
      expect_filter_count(3, bought_variant_ids: [1])
      expect_filter_count(2, bought_variant_ids: [2])
      expect_filter_count(4, bought_product_ids: [1], bought_variant_ids: [1])
      expect_filter_count(5, bought_product_ids: [2], bought_variant_ids: [2])

      expect_filter_count(3, not_bought_product_ids: [1])
      expect_filter_count(0, not_bought_product_ids: [1, 2])
      expect_filter_count(3, not_bought_variant_ids: [1])
      expect_filter_count(2, not_bought_variant_ids: [1, 2])
      expect_filter_count(2, not_bought_product_ids: [1], not_bought_variant_ids: [1])

      expect_filter_count(2, bought_product_ids: [2], not_bought_variant_ids: [1])
    end

    it "counts by prices" do
      create_member(purchases: [{ "price_cents" => 0 }])
      create_member(purchases: [{ "price_cents" => 100 }])
      create_member(purchases: [{ "price_cents" => 200 }])
      create_member(purchases: [
                      { "product_id" => 7, "variant_ids" => [1], "price_cents" => 0 },
                      { "product_id" => 8, "variant_ids" => [2], "price_cents" => 200 },
                      { "product_id" => 9, "variant_ids" => [3], "price_cents" => 200 },
                    ])

      expect_filter_count(3, paid_more_than_cents: 0)
      expect_filter_count(3, paid_more_than_cents: 50)
      expect_filter_count(2, paid_more_than_cents: 100)
      expect_filter_count(0, paid_more_than_cents: 250)

      expect_filter_count(4, paid_less_than_cents: 250)
      expect_filter_count(3, paid_less_than_cents: 200)
      expect_filter_count(2, paid_less_than_cents: 100)
      expect_filter_count(0, paid_less_than_cents: 0)

      expect_filter_count(1, paid_more_than_cents: 50, paid_less_than_cents: 150)

      expect_filter_count(0, paid_more_than_cents: 0, bought_product_ids: [7])
      expect_filter_count(0, paid_more_than_cents: 0, bought_variant_ids: [1])
      expect_filter_count(1, paid_more_than_cents: 0, bought_product_ids: [7, 8])
      expect_filter_count(1, paid_more_than_cents: 0, bought_variant_ids: [1, 2])
    end

    it "counts members with multiple matching purchases once" do
      create_member(purchases: [
                      { "price_cents" => 100 },
                      { "price_cents" => 200 },
                    ])

      expect_filter_count(1, paid_more_than_cents: 0, paid_less_than_cents: 300)
    end

    it "counts by creation dates" do
      create_member(follower: { "created_at" => 5.days.ago.iso8601 })
      create_member(follower: { "created_at" => 4.days.ago.iso8601 })
      create_member(
        follower: { "created_at" => 3.days.ago.iso8601 },
        purchases: [{ "product_id" => 6, "created_at" => 2.days.ago.iso8601 }]
      )
      create_member(purchases: [
                      { "product_id" => 7, "variant_ids" => [1], "created_at" => 5.days.ago.iso8601 },
                      { "product_id" => 8, "variant_ids" => [2], "created_at" => 1.day.ago.iso8601 }
                    ])

      expect_filter_count(2, created_after: 4.days.ago.iso8601)
      expect_filter_count(4, created_before: 2.days.ago.iso8601)
      expect_filter_count(1, created_after: 4.days.ago.iso8601, created_before: 2.days.ago.iso8601)
      expect_filter_count(0, created_after: 4.days.ago.iso8601, created_before: 2.days.ago.iso8601, bought_product_ids: [6])
      expect_filter_count(1, created_after: 4.days.ago.iso8601, created_before: 1.days.ago.iso8601, bought_product_ids: [6])
    end

    it "counts by country" do
      create_member(purchases: [{ "product_id" => 1, "country" => "United States" }])
      create_member(purchases: [{ "product_id" => 1, "country" => "Canada" }])
      create_member(purchases: [
                      { "product_id" => 1, "country" => "United States" },
                      { "product_id" => 2, "country" => "Canada" }
                    ])

      expect_filter_count(2, bought_from: "United States")
      expect_filter_count(2, bought_from: "Canada")
      expect_filter_count(1, bought_from: "Canada", bought_product_ids: [1, 3])
      expect_filter_count(0, bought_from: "Mexico")
    end

    it "counts by affiliate products" do
      create_member(affiliates: [{ "product_id" => 1 }])
      create_member(affiliates: [{ "product_id" => 2 }])
      create_member(affiliates: [
                      { "product_id" => 1, "created_at" => 3.days.ago.iso8601 },
                      { "product_id" => 2, "created_at" => 2.days.ago.iso8601 },
                      { "product_id" => 3, "created_at" => 1.day.ago.iso8601 },
                    ])

      expect_filter_count(2, affiliate_product_ids: [1])
      expect_filter_count(2, affiliate_product_ids: [2])
      expect_filter_count(3, affiliate_product_ids: [1, 2])
      expect_filter_count(0, affiliate_product_ids: [1, 2], created_after: 2.days.ago.iso8601)
      expect_filter_count(1, affiliate_product_ids: [1, 2], created_after: 3.days.ago.iso8601)
    end

    it "caps the count at the limit" do
      3.times { create_member(follower: {}) }

      expect(es_count({}, limit: 2)).to eq(2)
      expect(es_count({}, limit: 5)).to eq(3)
      expect(es_count({})).to eq(3)
    end

    def es_count(params = {}, limit: nil)
      AudienceMember.elasticsearch_filter_count(seller_id:, params:, limit:)
    end

    def expect_filter_count(expected, params)
      expect(es_count(params)).to eq(expected)
      expect(AudienceMember.filter(seller_id:, params:).count).to eq(expected)
    end

    def create_member(details = {})
      create(:audience_member, seller:, **details.with_indifferent_access.slice(:purchases, :follower, :affiliates))
    end
  end

  describe ".filter_count", :sidekiq_inline, :elasticsearch_wait_for_refresh do
    let(:seller) { create(:user) }

    before do
      create(:audience_member, seller:, purchases: [{ product_id: 1 }])
      create(:audience_member, seller:, follower: {})
    end

    it "counts via the SQL filter when the feature is inactive" do
      expect(EsClient).not_to receive(:search)

      expect(AudienceMember.filter_count(seller:, params: { type: "customer" })).to eq(1)
      expect(AudienceMember.filter_count(seller:, params: {})).to eq(2)
      expect(AudienceMember.filter_count(seller:, params: {}, limit: 1)).to eq(1)
    end

    context "when the feature is active for the seller" do
      before do
        Feature.activate_user(:audience_member_elasticsearch_counts, seller)
      end

      it "counts via Elasticsearch" do
        expect(AudienceMember.filter_count(seller:, params: { type: "customer" })).to eq(1)
        expect(AudienceMember.filter_count(seller:, params: { bought_product_ids: [1] })).to eq(1)
        expect(AudienceMember.filter_count(seller:, params: {})).to eq(2)
        expect(AudienceMember.filter_count(seller:, params: {}, limit: 1)).to eq(1)
      end

      it "falls back to the SQL filter when Elasticsearch is unavailable" do
        expect(EsClient).to receive(:search).and_raise(Faraday::ConnectionFailed.new("connection failed"))

        expect(AudienceMember.filter_count(seller:, params: { type: "customer" })).to eq(1)
      end
    end
  end
end
