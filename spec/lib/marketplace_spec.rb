# frozen_string_literal: true

require "rails_helper"

RSpec.describe IsbfMarketplace do
  fab!(:category)
  fab!(:member) { Fabricate(:user, trust_level: 1, refresh_auto_groups: true) }

  before do
    SiteSetting.isbf_marketplace_enabled = true
    SiteSetting.isbf_marketplace_publishing_enabled = true
    SiteSetting.isbf_marketplace_category_id = category.id
    category.set_permissions(trust_level_0: :full, staff: :full)
    category.save!
  end

  describe ".price_cents" do
    { "0" => 0, "0.00" => 0, "0.01" => 1, "12.3" => 1230,
      "12.34" => 1234, 12 => 1200, "9999999999.99" => 999_999_999_999 }.each do |input, cents|
      it "stores #{input.inspect} as #{cents} cents without floating point rounding" do
        expect(described_class.price_cents(input)).to eq(cents)
      end
    end

    [nil, "", "-1", "+1", "01", "1e2", "1,000", "1.001", "NaN", "10000000000", 1.5].each do |input|
      it "rejects invalid price #{input.inspect}" do
        expect { described_class.price_cents(input) }.to raise_error(Discourse::InvalidParameters)
      end
    end
  end

  it "accepts JSON image arrays and rejects duplicates, malformed IDs and oversized galleries" do
    ids = Array.new(20) { SecureRandom.uuid }
    expect(described_class.image_ids(ids.to_json)).to eq(ids)
    ["{", "{}", [ids.first, ids.first], ["../private"], ids + [SecureRandom.uuid]].each do |value|
      expect { described_class.image_ids(value) }.to raise_error(Discourse::InvalidParameters)
    end
  end

  it "defaults home visibility to false and accepts only explicit boolean values" do
    [nil, false, "false"].each { |value| expect(described_class.home_flag(value)).to eq(false) }
    [true, "true"].each { |value| expect(described_class.home_flag(value)).to eq(true) }
    [0, 1, "yes", "0", "1"].each do |value|
      expect { described_class.home_flag(value) }.to raise_error(Discourse::InvalidParameters)
    end
  end

  it "retains native category permissions and the publishing switch" do
    described_class.ensure_can_submit!(member, Guardian.new(member))
    category.set_permissions(trust_level_0: :readonly, staff: :full)
    category.save!
    expect { described_class.ensure_can_submit!(member, Guardian.new(member)) }.to raise_error(Discourse::InvalidAccess)
    category.set_permissions(trust_level_0: :full, staff: :full)
    category.save!
    SiteSetting.isbf_marketplace_publishing_enabled = false
    expect { described_class.ensure_can_submit!(member, Guardian.new(member)) }.to raise_error(Discourse::InvalidAccess)
  end

  it "requires metadata in addition to a marketplace category for the gallery" do
    plain = Fabricate(:post, topic: Fabricate(:topic, category: category)).topic
    product = Fabricate(:post, topic: Fabricate(:topic, category: category)).topic
    product.custom_fields[described_class::PRICE_FIELD] = 0
    product.save_custom_fields
    scope = described_class.filter(Topic.all, ["all"], Guardian.new(member))
    expect(scope.pluck(:id)).to include(product.id)
    expect(scope.pluck(:id)).not_to include(plain.id)
    expect(described_class.filter(Topic.all, ["all"], Guardian.new)).to be_empty
    expect(described_class.filter(Topic.all, ["unknown"], Guardian.new(member))).to be_empty
  end

  [{}, { isbf_marketplace_price: "1", raw: "![Public](https://example.org/photo.png)" }].each_with_index do |extra, index|
    it "prevents direct PostCreator validation bypass #{index + 1}" do
      options = {
        category: category.id, title: "A directly created campus product", raw: "An item for campus pickup.",
        skip_validations: true, skip_guardian: true, skip_events: true, reviewed_queued_post: true,
      }.merge(extra)
      expect do
        expect { PostCreator.new(member, options).create }.to raise_error(Discourse::InvalidParameters)
      end.not_to change(Topic, :count)
    end
  end
end
