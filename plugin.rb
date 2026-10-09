# frozen_string_literal: true

# name: isbf-marketplace
# about: Native marketplace topics with opt-in home display and private images.
# version: 0.1.0
# authors: ISBF Lab
# url: https://github.com/ISBF-Lab/ISBF-Marketplace
# required_version: 3.2.0

enabled_site_setting :isbf_marketplace_enabled

after_initialize do
  require_relative "lib/isbf_marketplace"
  require_relative "lib/isbf_marketplace/controllers"
  register_topic_custom_field_type(IsbfMarketplace::EXCERPT_FIELD, :string, max_length: 4096)
  add_preloaded_topic_list_custom_field(IsbfMarketplace::EXCERPT_FIELD)

  { IsbfMarketplace::PRICE_FIELD => :integer, IsbfMarketplace::IMAGES_FIELD => :json,
    IsbfMarketplace::HOME_FIELD => :boolean }.each do |field, type|
    register_topic_custom_field_type(field, type, max_length: 4096)
    add_preloaded_topic_list_custom_field(field)
    add_permitted_post_create_param(field.to_sym, :string)
    NewPostManager.add_plugin_payload_attribute(field.to_sym)
    add_permitted_post_update_param(field.to_sym)
    PostRevisor.track_topic_field(field.to_sym) do |changes, value|
      next if value.nil?
      raise Discourse::InvalidAccess unless IsbfMarketplace.product?(changes.topic)
      normalized = case field
                   when IsbfMarketplace::PRICE_FIELD then IsbfMarketplace.price_cents(value)
                   when IsbfMarketplace::IMAGES_FIELD then IsbfMarketplace.image_ids(value)
                   else IsbfMarketplace.home_flag(value)
                   end
      changes.record_change(field, changes.topic.custom_fields[field], normalized)
      changes.topic.custom_fields[field] = normalized
    end
  end

  %i[topic_view topic_list_item].each do |serializer|
    add_to_serializer(serializer, :isbf_marketplace, include_condition: -> { scope.user.present? }) do
      topic = object.respond_to?(:topic) ? object.topic : object
      IsbfMarketplace.metadata(topic)
    end
  end
  add_to_serializer(:post, :isbf_marketplace, include_condition: -> { scope.user.present? && object.is_first_post? }) do
    IsbfMarketplace.metadata(object.topic)
  end
  add_to_serializer(:site, :isbf_marketplace, include_condition: -> { SiteSetting.isbf_marketplace_enabled && IsbfMarketplace.category_id }) do
    { category_id: IsbfMarketplace.category_id, private_images: true, version: 1, publishing_enabled: SiteSetting.isbf_marketplace_publishing_enabled }
  end

  NewPostManager.add_handler(-90) do |manager|
    product = manager.args[:category].to_i == IsbfMarketplace.category_id && manager.args[:topic_id].blank?
    next unless product || IsbfMarketplace.supplied?(manager.args)
    begin
      raise Discourse::InvalidParameters.new("isbf_marketplace") unless product
      IsbfMarketplace.validate_payload!(manager.user, manager.args)
      nil # Continue the native rules; marketplace products do not force review.
    rescue Discourse::InvalidParameters, Discourse::InvalidAccess
      result = NewPostResult.new(:create_post, false)
      result.errors.add(:base, I18n.t("isbf_marketplace.invalid"))
      result
    end
  end

  on(:before_create_post) do |post, options|
    next if post.user&.is_system_user?
    product = options[:category].to_i == IsbfMarketplace.category_id && options[:topic_id].blank?
    next unless product || IsbfMarketplace.supplied?(options)
    raise Discourse::InvalidParameters.new("isbf_marketplace") unless product
    IsbfMarketplace.validate_payload!(post.user, options)
  end

  on(:before_create_topic) do |topic, creator|
    next if creator.user.is_system_user?
    next unless IsbfMarketplace.product?(topic) || IsbfMarketplace.supplied?(creator.opts)
    raise Discourse::InvalidParameters.new("isbf_marketplace") unless IsbfMarketplace.product?(topic)
    cents, ids, home = IsbfMarketplace.validate_payload!(creator.user, creator.opts, guardian: creator.guardian, reviewed: !!creator.opts[:reviewed_queued_post])
    topic.custom_fields[IsbfMarketplace::PRICE_FIELD] = cents
    topic.custom_fields[IsbfMarketplace::IMAGES_FIELD] = ids
    topic.custom_fields[IsbfMarketplace::HOME_FIELD] = home
    topic.custom_fields[IsbfMarketplace::EXCERPT_FIELD] = PrettyText.excerpt(PrettyText.cook(creator.opts[:raw].to_s), 280, strip_links: true, strip_images: true)
  end
  Topic.after_create do
    if IsbfMarketplace.product?(self) && custom_fields[IsbfMarketplace::PRICE_FIELD].present?
      IsbfMarketplace.image_ids(custom_fields[IsbfMarketplace::IMAGES_FIELD]).each { |id| IsbfMarketplace::Images.mark_bound!(id, self.id) }
    end
  end

  module ::IsbfMarketplace::ProductRevisor
    def revise!(editor, fields, opts = {}, &block)
      fields = fields.reject { |key, value| IsbfMarketplace::FIELDS.include?(key.to_s) && value.nil? }
      topic = @post.topic
      product = IsbfMarketplace.product?(topic) && @post.is_first_post?
      if product
        cents = topic.custom_fields[IsbfMarketplace::PRICE_FIELD].to_i
        payload = {
          category: fields[:category_id] || topic.category_id,
          title: fields[:title] || topic.title,
          raw: fields[:raw] || @post.raw,
          isbf_marketplace_price: fields.fetch(IsbfMarketplace::PRICE_FIELD.to_sym, "#{cents / 100}.#{(cents % 100).to_s.rjust(2, '0')}"),
          isbf_marketplace_images: fields.fetch(IsbfMarketplace::IMAGES_FIELD.to_sym, topic.custom_fields[IsbfMarketplace::IMAGES_FIELD]),
          isbf_marketplace_home: fields.fetch(IsbfMarketplace::HOME_FIELD.to_sym, topic.custom_fields[IsbfMarketplace::HOME_FIELD]),
        }
        IsbfMarketplace.validate_payload!(editor, payload, topic: topic)
      elsif IsbfMarketplace.supplied?(fields) || (fields[:category_id].to_i == IsbfMarketplace.category_id && @post.is_first_post?)
        raise Discourse::InvalidParameters.new("isbf_marketplace")
      end
      PluginStoreRow.transaction do
        result = super(editor, fields, opts, &block)
        if result && product
          topic.custom_fields[IsbfMarketplace::EXCERPT_FIELD] = PrettyText.excerpt(@post.cooked, 280, strip_links: true, strip_images: true)
          topic.save_custom_fields
          IsbfMarketplace.image_ids(topic.custom_fields[IsbfMarketplace::IMAGES_FIELD]).each { |id| IsbfMarketplace::Images.mark_bound!(id, topic.id) }
        end
        result
      end
    end
  end
  PostRevisor.prepend(IsbfMarketplace::ProductRevisor)

  # Post-processing must never copy a private product image into public uploads.
  on(:before_upload_creation) do |_file, image, upload, _validate|
    next unless image
    basename = File.basename(upload.original_filename.to_s)
    id = basename.match(/\A([0-9a-f-]{36})(?:\.[a-z0-9]+)*\z/)&.[](1)
    if id && IsbfMarketplace::Images.valid_id?(id) && IsbfMarketplace::Images.metadata(id)
      upload.errors.add(:base, I18n.t("isbf_marketplace.private_images_only"))
    end
  end

  module ::IsbfMarketplace::HomeQueryOptions
    def build_topic_list_options
      result = super
      # Category routes call the same list method with category options later.
      result[:isbf_marketplace_home_feed] = true if action_name == "latest"
      result
    end
  end
  ListController.prepend(IsbfMarketplace::HomeQueryOptions)
  TopicQuery.add_custom_filter(:isbf_marketplace_home_feed) do |topics, query|
    if query.options[:isbf_marketplace_home_feed] && query.options[:category].blank? && query.options[:tags].blank? && query.options[:q].blank?
      IsbfMarketplace.home_scope(topics)
    else
      topics
    end
  end
  add_filter_custom_filter("isbf-marketplace") do |scope, values, guardian|
    IsbfMarketplace.filter(scope, values, guardian)
  end

  IsbfMarketplace::Engine.routes.draw do
    get "/" => "products#page"
    post "/uploads" => "products#upload"
    get "/images/:id/thumbnail" => "products#image", defaults: { thumbnail: "true" }
    get "/images/:id" => "products#image"
  end
  Discourse::Application.routes.append { mount ::IsbfMarketplace::Engine, at: "/isbf/marketplace" }
end
