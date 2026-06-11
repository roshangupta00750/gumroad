# frozen_string_literal: true

module AudienceMember::Searchable
  extend ActiveSupport::Concern

  included do
    include Elasticsearch::Model
    include SearchIndexModelCommon
    include ElasticsearchModelAsyncCallbacks

    index_name "audience_members"

    settings number_of_shards: 1, number_of_replicas: 0

    mapping dynamic: :strict do
      indexes :seller_id, type: :long
      indexes :customer, type: :boolean
      indexes :follower, type: :boolean
      indexes :affiliate, type: :boolean
      indexes :min_paid_cents, type: :long
      indexes :max_paid_cents, type: :long
      indexes :min_created_at, type: :date
      indexes :max_created_at, type: :date
      indexes :min_purchase_created_at, type: :date
      indexes :max_purchase_created_at, type: :date
      indexes :follower_created_at, type: :date
      indexes :min_affiliate_created_at, type: :date
      indexes :max_affiliate_created_at, type: :date
      indexes :follower_id, type: :long
      indexes :purchases, type: :nested do
        indexes :id, type: :long
        indexes :product_id, type: :long
        indexes :variant_ids, type: :long
        indexes :price_cents, type: :long
        indexes :created_at, type: :date
        indexes :country, type: :keyword
      end
      indexes :affiliates, type: :nested do
        indexes :id, type: :long
        indexes :product_id, type: :long
        indexes :created_at, type: :date
      end
    end

    ATTRIBUTE_TO_SEARCH_FIELDS = {
      "seller_id" => "seller_id",
      "customer" => "customer",
      "follower" => "follower",
      "affiliate" => "affiliate",
      "min_paid_cents" => "min_paid_cents",
      "max_paid_cents" => "max_paid_cents",
      "min_created_at" => "min_created_at",
      "max_created_at" => "max_created_at",
      "min_purchase_created_at" => "min_purchase_created_at",
      "max_purchase_created_at" => "max_purchase_created_at",
      "follower_created_at" => "follower_created_at",
      "min_affiliate_created_at" => "min_affiliate_created_at",
      "max_affiliate_created_at" => "max_affiliate_created_at",
      "details" => %w[follower_id purchases affiliates],
    }

    def search_field_value(field_name)
      case field_name
      when "purchases"
        Array.wrap(details.as_json["purchases"]).map { _1.slice("id", "product_id", "variant_ids", "price_cents", "created_at", "country") }
      when "affiliates"
        Array.wrap(details.as_json["affiliates"]).map { _1.slice("id", "product_id", "created_at") }
      when "follower_id"
        details.as_json.dig("follower", "id")
      else
        attributes[field_name]
      end.as_json
    end
  end

  class_methods do
    def elasticsearch_filter_count(seller_id:, params: {}, limit: nil)
      body = {
        query: elasticsearch_filter_query(seller_id:, params:),
        size: 0,
        track_total_hits: limit || true,
      }
      response = EsClient.search(index: index_name, body:)
      total = response.dig("hits", "total", "value")
      limit ? [total, limit].min : total
    end

    def elasticsearch_filter_query(seller_id:, params: {})
      params = params.slice(*AudienceMember::FILTER_PARAMS).compact_blank

      if params[:type]
        raise ArgumentError, "Invalid type: #{params[:type]}. Must be one of: #{AudienceMember::VALID_FILTER_TYPES.join(', ')}" unless params[:type].in?(AudienceMember::VALID_FILTER_TYPES)
      end

      created_after = elasticsearch_time_value(params[:created_after])
      created_before = elasticsearch_time_value(params[:created_before])

      filter = [{ term: { seller_id: } }]
      must_not = []

      filter << { term: { params[:type] => true } } if params[:type]

      if params[:bought_product_ids] || params[:bought_variant_ids]
        filter << { nested: { path: "purchases", query: elasticsearch_bought_records_query(params) } }
      end

      if params[:not_bought_product_ids]
        must_not << { nested: { path: "purchases", query: { terms: { "purchases.product_id" => params[:not_bought_product_ids] } } } }
      end

      if params[:not_bought_variant_ids]
        must_not << { nested: { path: "purchases", query: { terms: { "purchases.variant_ids" => params[:not_bought_variant_ids] } } } }
      end

      filter << { range: { max_paid_cents: { gt: params[:paid_more_than_cents] } } } if params[:paid_more_than_cents]
      filter << { range: { min_paid_cents: { lt: params[:paid_less_than_cents] } } } if params[:paid_less_than_cents]

      if created_after || created_before
        min_created_at_field, max_created_at_field = \
          case params[:type]
          when "customer" then [:min_purchase_created_at, :max_purchase_created_at]
          when "follower" then [:follower_created_at, :follower_created_at]
          when "affiliate" then [:min_affiliate_created_at, :max_affiliate_created_at]
          else [:min_created_at, :max_created_at]
          end
        filter << { range: { max_created_at_field => { gt: created_after } } } if created_after
        filter << { range: { min_created_at_field => { lt: created_before } } } if created_before
      end

      if params[:bought_from]
        filter << { nested: { path: "purchases", query: { term: { "purchases.country" => params[:bought_from] } } } }
      end

      if params[:affiliate_product_ids]
        filter << { nested: { path: "affiliates", query: { terms: { "affiliates.product_id" => params[:affiliate_product_ids] } } } }
      end

      same_record_query = elasticsearch_same_record_query(params, created_after:, created_before:)
      filter << same_record_query if same_record_query

      query = { bool: { filter: } }
      query[:bool][:must_not] = must_not if must_not.any?
      query
    end

    private
      def elasticsearch_time_value(value)
        return if value.blank?
        value.respond_to?(:iso8601) ? value.iso8601 : value.to_s
      end

      def elasticsearch_bought_records_query(params)
        queries = []
        queries << { terms: { "purchases.product_id" => params[:bought_product_ids] } } if params[:bought_product_ids]
        queries << { terms: { "purchases.variant_ids" => params[:bought_variant_ids] } } if params[:bought_variant_ids]
        queries.one? ? queries.first : { bool: { should: queries, minimum_should_match: 1 } }
      end

      def elasticsearch_same_record_query(params, created_after:, created_before:)
        filters_records = params[:bought_product_ids] || params[:bought_variant_ids] || params[:affiliate_product_ids]
        filters_record_attributes = params[:paid_more_than_cents] || params[:paid_less_than_cents] || created_after || created_before || params[:bought_from]
        required = (filters_records && filters_record_attributes) ||
          (params[:paid_more_than_cents] && params[:paid_less_than_cents]) ||
          (created_after && created_before)
        return unless required

        date_record_types = \
          case params[:type]
          when "customer" then %w[purchase]
          when "follower"
            params[:bought_product_ids] || params[:bought_variant_ids] ? %w[follower purchase] : %w[follower]
          when "affiliate" then %w[affiliate]
          else %w[purchase follower affiliate]
          end

        has_purchase_conditions = params[:paid_more_than_cents] || params[:paid_less_than_cents] ||
          params[:bought_product_ids] || params[:bought_variant_ids] || params[:bought_from]
        has_affiliate_conditions = params[:affiliate_product_ids].present?
        has_date_conditions = created_after.present? || created_before.present?

        date_range = {}
        date_range[:gt] = created_after if created_after
        date_range[:lt] = created_before if created_before

        price_range = {}
        price_range[:gt] = params[:paid_more_than_cents] if params[:paid_more_than_cents]
        price_range[:lt] = params[:paid_less_than_cents] if params[:paid_less_than_cents]

        candidate_queries = []

        purchase_eligible = !has_affiliate_conditions && (!has_date_conditions || date_record_types.include?("purchase"))
        if purchase_eligible && (has_purchase_conditions || has_date_conditions)
          conditions = []
          conditions << elasticsearch_bought_records_query(params) if params[:bought_product_ids] || params[:bought_variant_ids]
          conditions << { range: { "purchases.price_cents" => price_range } } if price_range.any?
          conditions << { term: { "purchases.country" => params[:bought_from] } } if params[:bought_from]
          conditions << { range: { "purchases.created_at" => date_range } } if has_date_conditions
          candidate_queries << { nested: { path: "purchases", query: { bool: { filter: conditions } } } }
        end

        follower_eligible = !has_purchase_conditions && !has_affiliate_conditions && (!has_date_conditions || date_record_types.include?("follower"))
        if follower_eligible && has_date_conditions
          candidate_queries << { range: { follower_created_at: date_range } }
        end

        affiliate_eligible = !has_purchase_conditions && (!has_date_conditions || date_record_types.include?("affiliate"))
        if affiliate_eligible && (has_affiliate_conditions || has_date_conditions)
          conditions = []
          conditions << { terms: { "affiliates.product_id" => params[:affiliate_product_ids] } } if has_affiliate_conditions
          conditions << { range: { "affiliates.created_at" => date_range } } if has_date_conditions
          candidate_queries << { nested: { path: "affiliates", query: { bool: { filter: conditions } } } }
        end

        return { match_none: {} } if candidate_queries.empty?
        candidate_queries.one? ? candidate_queries.first : { bool: { should: candidate_queries, minimum_should_match: 1 } }
      end
  end
end
