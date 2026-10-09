# frozen_string_literal: true

require "uri"

module IsbfMarketplace
  STORE = "isbf-marketplace"
  PRICE_FIELD = "isbf_marketplace_price"
  IMAGES_FIELD = "isbf_marketplace_images"
  HOME_FIELD = "isbf_marketplace_home"
  EXCERPT_FIELD = "isbf_marketplace_excerpt"
  FIELDS = [PRICE_FIELD, IMAGES_FIELD, HOME_FIELD].freeze
  MAX_PRICE_CENTS = 999_999_999_999
  class StorageError < StandardError; end

  def self.category_id
    id = SiteSetting.isbf_marketplace_category_id.to_i
    id if id.positive? && Category.exists?(id: id)
  end

  def self.product?(topic)
    category_id && topic&.category_id == category_id && !topic.private_message?
  end

  def self.supplied?(options)
    FIELDS.any? { |field| !options[field.to_sym].nil? }
  end

  def self.ensure_can_submit!(user, guardian)
    category = Category.find_by(id: category_id)
    unless SiteSetting.isbf_marketplace_enabled && SiteSetting.isbf_marketplace_publishing_enabled &&
             user && category && guardian.can_create?(Topic, category)
      raise Discourse::InvalidAccess
    end
  end

  def self.price_cents(value)
    text = value.is_a?(String) || value.is_a?(Integer) ? value.to_s.strip : ""
    unless text.match?(/\A(0|[1-9]\d{0,9})(?:\.\d{1,2})?\z/)
      raise Discourse::InvalidParameters.new(I18n.t("isbf_marketplace.invalid_price"))
    end
    whole, fraction = text.split(".", 2)
    cents = whole.to_i * 100 + fraction.to_s.ljust(2, "0").to_i
    raise Discourse::InvalidParameters.new(PRICE_FIELD) if cents > MAX_PRICE_CENTS
    cents
  end

  def self.image_ids(value)
    ids = value.is_a?(String) ? JSON.parse(value) : (value || [])
    unless ids.is_a?(Array) && ids.length <= 20 && ids.uniq == ids && ids.all? { |id| Images.valid_id?(id) }
      raise Discourse::InvalidParameters.new(IMAGES_FIELD)
    end
    ids
  rescue JSON::ParserError
    raise Discourse::InvalidParameters.new(IMAGES_FIELD)
  end

  def self.home_flag(value)
    return false if value.nil? || value == false || value == "false"
    return true if value == true || value == "true"
    raise Discourse::InvalidParameters.new(HOME_FIELD)
  end

  def self.validate_payload!(user, options, topic: nil, guardian: Guardian.new(user), reviewed: false)
    if topic
      raise Discourse::InvalidAccess unless guardian.can_edit_post?(topic.first_post)
    elsif !reviewed
      ensure_can_submit!(user, guardian)
    end
    unless user && SiteSetting.isbf_marketplace_enabled &&
             options[:category].to_i == category_id && options[:archetype] != Archetype.private_message &&
             ![true, "true"].include?(options[:isbf_anonymous]) && options[:raw].to_s.strip.present? &&
             options[:title].to_s.strip.present? && !options[:title].to_s.include?("[isbf-untitled:")
      raise Discourse::InvalidParameters.new("isbf_marketplace")
    end
    cents = price_cents(options[PRICE_FIELD.to_sym])
    ids = image_ids(options[IMAGES_FIELD.to_sym])
    home = home_flag(options[HOME_FIELD.to_sym])
    ids.each do |id|
      info = Images.metadata(id)
      same_topic = topic && info && info[:topic_id].to_i == topic.id
      unless info && (same_topic || (!info[:bound] && info[:owner_id] == user.id))
        raise Discourse::InvalidAccess
      end
    end
    validate_image_sources!(options[:raw], ids)
    [cents, ids, home]
  end

  def self.validate_image_sources!(raw, ids)
    # Markdown reference images and raw HTML also need the private-image check.
    document = Nokogiri::HTML.fragment(PrettyText.cook(raw.to_s))
    sources = document.css("img").flat_map { |node| [node["src"], node["data-orig-src"]].compact }
    sources.each do |source|
      path = source.start_with?("/") ? source : URI.parse(source).then do |uri|
        uri.path if uri.host&.casecmp?(Discourse.current_hostname) && !uri.userinfo && %w[http https].include?(uri.scheme)
      end
      id = path&.match(%r{\A/isbf/marketplace/images/([0-9a-f-]{36})\z})&.[](1)
      raise Discourse::InvalidParameters.new(I18n.t("isbf_marketplace.private_images_only")) unless id && ids.include?(id)
    rescue URI::InvalidURIError
      raise Discourse::InvalidParameters.new(IMAGES_FIELD)
    end
    references = raw.to_s.scan(%r{/isbf/marketplace/images/([0-9a-f-]{36})}).flatten.uniq
    if (references - ids).any? || raw.to_s.match?(%r{(?:upload://|/uploads/)}i)
      raise Discourse::InvalidParameters.new(I18n.t("isbf_marketplace.private_images_only"))
    end
  end

  def self.visible_product?(topic, guardian)
    return false unless guardian.user && product?(topic) && topic.visible && !topic.deleted_at && guardian.can_see_topic?(topic)
    post = topic.first_post
    post && !post.deleted_at && !post.user_deleted && !post.hidden? &&
      guardian.can_see_post?(post) && !(defined?(IsbfModeration::Hold) && IsbfModeration::Hold.persisted?(post))
  end

  def self.image_accessible?(id, user, guardian)
    return false unless user && (info = Images.metadata(id))
    if info[:bound]
      topic = Topic.with_deleted.find_by(id: info[:topic_id])
      return topic && image_ids(topic.custom_fields[IMAGES_FIELD]).include?(id) && visible_product?(topic, guardian)
    end
    return true if info[:owner_id] == user.id
    pending = ReviewableQueuedPost.pending.where(category_id: category_id).where("payload ->> ? LIKE ?", IMAGES_FIELD, "%#{id}%")
    return false unless pending.exists?
    Reviewable.viewable_by(user, preload: false).where(id: pending.select(:id)).exists?
  end

  def self.metadata(topic)
    return nil unless product?(topic) && topic.custom_fields[PRICE_FIELD].present?
    {
      price_cents: topic.custom_fields[PRICE_FIELD].to_i,
      show_on_home: topic.custom_fields[HOME_FIELD] == true,
      description: topic.custom_fields[EXCERPT_FIELD].to_s,
      images: image_ids(topic.custom_fields[IMAGES_FIELD]).filter_map do |id|
        Images.metadata(id)&.slice(:id, :url, :thumbnail_url)
      end,
    }
  end

  def self.home_scope(topics)
    id = category_id
    return topics unless id
    topics.where(<<~SQL, id, HOME_FIELD)
      topics.category_id <> ? OR EXISTS (
        SELECT 1 FROM topic_custom_fields AS marketplace_home
        WHERE marketplace_home.topic_id = topics.id AND marketplace_home.name = ?
          AND marketplace_home.value = 't'
      )
    SQL
  end

  def self.filter(topics, values, guardian)
    return topics.none unless SiteSetting.isbf_marketplace_enabled && guardian.user && values == ["all"] && category_id
    topics.where(category_id: category_id).where(<<~SQL, PRICE_FIELD)
      EXISTS (SELECT 1 FROM topic_custom_fields AS marketplace_price
        WHERE marketplace_price.topic_id = topics.id AND marketplace_price.name = ?)
      AND EXISTS (SELECT 1 FROM posts AS marketplace_post
        WHERE marketplace_post.topic_id = topics.id AND marketplace_post.post_number = 1
          AND marketplace_post.deleted_at IS NULL AND NOT marketplace_post.user_deleted
          AND NOT marketplace_post.hidden)
    SQL
  end
end

require_relative "isbf_marketplace/images"
