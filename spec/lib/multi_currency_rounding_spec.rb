# frozen_string_literal: true

require "spec_helper"

describe MultiCurrencyRounding do
  describe ".round" do
    it "rounds to .49/.99 endings for prices under $5" do
      expect(described_class.round(base_usd_cents: 499, converted_cents: 460, currency: "eur")).to eq(449)
      expect(described_class.round(base_usd_cents: 499, converted_cents: 480, currency: "eur")).to eq(499)
    end

    it "rounds to a .99 ending for $5-$25" do
      expect(described_class.round(base_usd_cents: 999, converted_cents: 920, currency: "eur")).to eq(899)
      expect(described_class.round(base_usd_cents: 999, converted_cents: 970, currency: "eur")).to eq(999)
    end

    it "rounds to x4.99/x9.99 for $25-$100" do
      expect(described_class.round(base_usd_cents: 4999, converted_cents: 4600, currency: "eur")).to eq(4499)
      expect(described_class.round(base_usd_cents: 4999, converted_cents: 4800, currency: "eur")).to eq(4999)
    end

    it "rounds to x9.99 for $100-$500 and $500+" do
      expect(described_class.round(base_usd_cents: 19900, converted_cents: 18300, currency: "eur")).to eq(17999)
      expect(described_class.round(base_usd_cents: 99900, converted_cents: 92000, currency: "eur")).to eq(91999)
    end

    it "matches the issue's zero-decimal examples (JPY to 100, KRW to 1000)" do
      expect(described_class.round(base_usd_cents: 999, converted_cents: 1399, currency: "jpy", zero_decimal: true)).to eq(1400)
      expect(described_class.round(base_usd_cents: 999, converted_cents: 13986, currency: "krw", zero_decimal: true)).to eq(14000)
    end

    it "never returns below one unit" do
      expect(described_class.round(base_usd_cents: 100, converted_cents: 10, currency: "eur")).to be >= 1
      expect(described_class.round(base_usd_cents: 999, converted_cents: 10, currency: "jpy", zero_decimal: true)).to be >= 100
    end

    it "picks the rounding step from the USD tier, not the converted amount" do
      # Same converted amount, different USD tier -> different granularity.
      fine = described_class.round(base_usd_cents: 400, converted_cents: 5040, currency: "eur")   # <$5 tier, step .50
      coarse = described_class.round(base_usd_cents: 60000, converted_cents: 5040, currency: "eur") # $500+ tier, step 10
      expect(fine).to eq(5049)
      expect(coarse).to eq(4999)
      expect(described_class.tier_step(400)).to eq(0.50)
      expect(described_class.tier_step(60000)).to eq(10.00)
    end

    it "selects tiers on the documented half-open boundaries" do
      expect(described_class.tier_step(499)).to eq(0.50)   # < $5
      expect(described_class.tier_step(500)).to eq(1.00)   # $5
      expect(described_class.tier_step(2499)).to eq(1.00)
      expect(described_class.tier_step(2500)).to eq(5.00)  # $25
      expect(described_class.tier_step(9999)).to eq(5.00)
      expect(described_class.tier_step(10000)).to eq(10.00) # $100
      expect(described_class.tier_step(49999)).to eq(10.00)
      expect(described_class.tier_step(50000)).to eq(10.00) # $500+
    end

    it "rounds to the NEAREST step, both directions" do
      # step 1.00 (=100 minor) for the $5-25 tier
      expect(described_class.round(base_usd_cents: 999, converted_cents: 949, currency: "eur")).to eq(899) # 949 -> 900 -> 899
      expect(described_class.round(base_usd_cents: 999, converted_cents: 951, currency: "eur")).to eq(999) # 951 -> 1000 -> 999
    end

    describe "invariants across a wide input space" do
      currencies = %w[eur gbp cad aud brl mxn]
      it "decimal results always end in .49 or .99 and are >= 1" do
        currencies.each do |cur|
          [1, 50, 99, 250, 1234, 4999, 25000, 199_00, 999_99, 1_234_567].each do |usd|
            [1, 37, 460, 4_999, 18_300, 92_000, 5_000_00].each do |conv|
              out = described_class.round(base_usd_cents: usd, converted_cents: conv, currency: cur)
              expect(out).to be >= 1
              expect(out % 100).to satisfy { |ending| ending == 49 || ending == 99 }, "#{cur} usd=#{usd} conv=#{conv} -> #{out} (ending #{out % 100})"
            end
          end
        end
      end

      it "zero-decimal results are whole multiples of the currency step and never below it" do
        { "jpy" => 100, "krw" => 1000 }.each do |cur, step|
          [0, 1, 1399, 13_986, 9_999_999].each do |conv|
            out = described_class.round(base_usd_cents: 999, converted_cents: conv, currency: cur, zero_decimal: true)
            expect(out % step).to eq(0)
            expect(out).to be >= step
          end
        end
      end
    end
  end
end
