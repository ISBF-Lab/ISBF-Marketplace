# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

RSpec.describe "ISBF marketplace native integration", type: :request do
  fab!(:category)
  fab!(:other_category) { Fabricate(:category) }
  fab!(:member) { Fabricate(:user, active: true, approved: true, trust_level: 1, refresh_auto_groups: true) }
  fab!(:other_member) { Fabricate(:user, active: true, approved: true, trust_level: 1, refresh_auto_groups: true) }
  fab!(:admin)

  before do
    SiteSetting.isbf_marketplace_enabled = true
    SiteSetting.isbf_marketplace_publishing_enabled = true
    SiteSetting.isbf_marketplace_category_id = category.id
    SiteSetting.approve_post_count = 0
    SiteSetting.approve_unless_allowed_groups = Group::AUTO_GROUPS[:trust_level_0].to_s
    SiteSetting.approve_new_topics_unless_allowed_groups = Group::AUTO_GROUPS[:trust_level_0].to_s
    SiteSetting.skip_review_media_groups = Group::AUTO_GROUPS[:trust_level_0].to_s
    category.set_permissions(trust_level_0: :full, staff: :full)
    category.save!
    @storage_root = Dir.mktmpdir("isbf-marketplace-requests")
    IsbfMarketplace::Images.stubs(:root).returns(@storage_root)
  end

  after { FileUtils.remove_entry(@storage_root) }

  def private_image(owner = member)
    id = SecureRandom.uuid
    PluginStore.set(IsbfMarketplace::STORE, "image:#{id}", {
      owner_id: owner.id, bound: false, name: "photo.png", content_type: "image/png", size: 7,
    })
    File.binwrite(IsbfMarketplace::Images.path(id), "private")
    File.binwrite(IsbfMarketplace::Images.path(id, thumbnail: true), "private")
    id
  end

  def payload(extra = {})
    @submission_number = (@submission_number || 0) + 1
    {
      title: "Campus secondhand item #{@submission_number}", raw: "A useful item in good condition for campus pickup.",
      category: category.id, isbf_marketplace_price: "12.34", isbf_marketplace_images: "[]",
    }.merge(extra)
  end

  def submit(extra = {}, actor: member, **fields)
    sign_in(actor)
    post "/posts.json", params: payload(extra.merge(fields))
  end

  def created_post
    expect(response.status).to eq(200), response.body
    Post.find(response.parsed_body.fetch("id"))
  end

  def topic_ids
    expect(response.status).to eq(200), response.body
    response.parsed_body.fetch("topic_list").fetch("topics").map { |topic| topic.fetch("id") }
  end

  def make_product(home: false, created_at: Time.zone.now)
    topic = Fabricate(:topic, category: category, user: member, created_at: created_at, bumped_at: created_at)
    Fabricate(:post, topic: topic, user: member)
    topic.custom_fields[IsbfMarketplace::PRICE_FIELD] = 1234
    topic.custom_fields[IsbfMarketplace::IMAGES_FIELD] = []
    topic.custom_fields[IsbfMarketplace::HOME_FIELD] = home
    topic.save_custom_fields
    topic
  end

  it "publishes one native topic with integer cents, bound private images and home opt-out" do
    id = private_image
    expect do
      submit(isbf_marketplace_images: [id].to_json, raw: "Pickup on campus. ![Photo](/isbf/marketplace/images/#{id})")
    end.to change(Topic.where(category_id: category.id), :count).by(1)
    first = created_post
    expect(first.is_first_post?).to eq(true)
    expect(first.topic.custom_fields).to include(
      IsbfMarketplace::PRICE_FIELD => 1234, IsbfMarketplace::IMAGES_FIELD => [id], IsbfMarketplace::HOME_FIELD => false,
    )
    expect(IsbfMarketplace::Images.metadata(id)).to include(bound: true, topic_id: first.topic_id)
    expect(response.parsed_body.dig("isbf_marketplace", "price_cents")).to eq(1234)
    expect(ReviewableQueuedPost.pending.where(category_id: category.id)).to be_empty
  end

  it "accepts zero-priced goods" do
    submit(isbf_marketplace_price: "0")
    expect(created_post.topic.custom_fields[IsbfMarketplace::PRICE_FIELD]).to eq(0)
  end

  [{ isbf_marketplace_price: nil }, { isbf_marketplace_price: "-1" },
   { isbf_marketplace_price: "1.001" }, { isbf_marketplace_images: "{}" },
   { isbf_marketplace_home: "yes" }].each_with_index do |extra, index|
    it "rejects invalid native product submission #{index + 1} without a topic or reviewable" do
      expect do
        expect do
          submit(extra)
          expect(response.status).to eq(422), response.body
        end.not_to change(ReviewableQueuedPost, :count)
      end.not_to change(Topic, :count)
    end
  end

  it "rejects missing and foreign private image IDs" do
    [SecureRandom.uuid, private_image(other_member)].each do |id|
      expect do
        submit(isbf_marketplace_images: [id].to_json)
        expect(response.status).to eq(422), response.body
      end.not_to change(Topic, :count)
    end
  end

  ["![Public](/uploads/default/original/photo.png)", "![External](https://example.org/photo.png)",
   '<img src="https://example.org/photo.png">',
   "![Reference][photo]\n\n[photo]: https://example.org/photo.png"].each_with_index do |image, index|
    it "rejects public or external images in native product body #{index + 1}" do
      expect do
        submit(raw: "Item details and pickup on campus.\n\n#{image}")
        expect(response.status).to eq(422), response.body
      end.not_to change(Topic, :count)
    end
  end

  it "rejects a private image URL omitted from the attachment metadata" do
    id = private_image
    submit(raw: "Item details. ![Photo](/isbf/marketplace/images/#{id})")
    expect(response.status).to eq(422), response.body
    expect(IsbfMarketplace::Images.metadata(id)[:bound]).to eq(false)
  end

  it "keeps ordinary topics and marketplace replies on the native path" do
    sign_in(member)
    post "/posts.json", params: {
      title: "An ordinary campus discussion", category: other_category.id, raw: "An ordinary discussion without product fields.",
    }
    ordinary = created_post
    expect(ordinary.topic.custom_fields[IsbfMarketplace::PRICE_FIELD]).to be_nil
    submit
    product = created_post
    post "/posts.json", params: { topic_id: product.topic_id, raw: "Is this item still available for campus pickup?" }
    reply = created_post
    expect(reply.post_number).to eq(2)
    expect(response.parsed_body).not_to have_key("isbf_marketplace")
  end

  it "rejects marketplace metadata on ordinary topics and replies" do
    submit(category: other_category.id)
    expect(response.status).to eq(422), response.body
    submit
    first = created_post
    post "/posts.json", params: { topic_id: first.topic_id, raw: "I would like to buy this item.", isbf_marketplace_price: "1" }
    expect(response.status).to eq(422), response.body
  end

  it "lets the author revise price and home visibility through native post editing" do
    submit
    first = created_post
    put "/posts/#{first.id}.json", params: { post: { isbf_marketplace_price: "0.01", isbf_marketplace_home: "true" } }
    expect(response.status).to eq(200), response.body
    expect(first.topic.reload.custom_fields).to include(IsbfMarketplace::PRICE_FIELD => 1, IsbfMarketplace::HOME_FIELD => true)
    get "/latest.json"
    expect(topic_ids).to include(first.topic_id)
    put "/posts/#{first.id}.json", params: { post: { raw: "Updated details: available tomorrow for campus pickup." } }
    expect(response.status).to eq(200), response.body
    expect(first.topic.reload.custom_fields[IsbfMarketplace::PRICE_FIELD]).to eq(1)
    put "/posts/#{first.id}.json", params: { post: { isbf_marketplace_home: "false" } }
    expect(response.status).to eq(200), response.body
    get "/latest.json"
    expect(topic_ids).not_to include(first.topic_id)
  end

  it "retains native edit permissions for another ordinary user and staff" do
    submit
    first = created_post
    sign_in(other_member)
    put "/posts/#{first.id}.json", params: { post: { isbf_marketplace_price: "99" } }
    expect(response.status).to eq(403), response.body
    expect(first.topic.reload.custom_fields[IsbfMarketplace::PRICE_FIELD]).to eq(1234)
    sign_in(admin)
    put "/posts/#{first.id}.json", params: { post: { isbf_marketplace_price: "20" } }
    expect(response.status).to eq(200), response.body
    expect(first.topic.reload.custom_fields[IsbfMarketplace::PRICE_FIELD]).to eq(2000)
  end

  it "allows same-topic image edits while preventing transfers to another product" do
    id = private_image
    submit(isbf_marketplace_images: [id].to_json)
    first = created_post
    put "/posts/#{first.id}.json", params: { post: { isbf_marketplace_images: [id].to_json, isbf_marketplace_price: "10" } }
    expect(response.status).to eq(200), response.body
    submit(isbf_marketplace_images: [id].to_json)
    expect(response.status).to eq(422), response.body
    submit
    second = created_post
    put "/posts/#{second.id}.json", params: { post: { isbf_marketplace_images: [id].to_json } }
    expect([403, 422]).to include(response.status)
    expect(IsbfMarketplace::Images.metadata(id)[:topic_id]).to eq(first.topic_id)
    expect(second.topic.reload.custom_fields[IsbfMarketplace::IMAGES_FIELD]).to eq([])
  end

  it "requires login for submission and both private image representations" do
    id = private_image
    post "/posts.json", params: payload
    expect(response.status).to eq(403), response.body
    ["/isbf/marketplace/images/#{id}", "/isbf/marketplace/images/#{id}/thumbnail"].each do |path|
      get path, headers: { "HTTP_ACCEPT" => "application/json" }
      expect(response.status).to eq(403), response.body
    end
  end

  it "does not expose the marketplace gallery to guests" do
    make_product
    get "/filter.json", params: { q: "isbf-marketplace:all order:created" }
    expect(topic_ids).to be_empty
  end

  it "keeps unbound drafts private to their uploader" do
    id = private_image
    sign_in(other_member)
    get "/isbf/marketplace/images/#{id}"
    expect(response.status).to eq(403), response.body
    sign_in(member)
    get "/isbf/marketplace/images/#{id}"
    expect(response.status).to eq(200), response.body
    expect(response.headers["Cache-Control"]).to include("no-store")
  end

  it "respects read-only category permissions and the publishing switch for native posts" do
    category.set_permissions(trust_level_0: :readonly, staff: :full)
    category.save!
    submit
    expect(response.status).to eq(422), response.body
    submit({}, actor: admin)
    created_post
    SiteSetting.isbf_marketplace_publishing_enabled = false
    submit({}, actor: admin)
    expect(response.status).to eq(422), response.body
  end

  [:silenced_till, :suspended_till].each do |restriction|
    it "does not publish for a member with #{restriction}" do
      member.update!(restriction => 1.day.from_now)
      expect do
        submit
        expect([403, 422]).to include(response.status)
      end.not_to change(Topic, :count)
    end
  end

  context "with native approval required" do
    before { SiteSetting.approve_post_count = 100 }

    def queue_product(id)
      expect do
        submit(isbf_marketplace_images: [id].to_json, isbf_marketplace_home: "true", isbf_marketplace_price: "0.25")
        expect(response.status).to eq(200), response.body
      end.not_to change(Topic, :count)
      ReviewableQueuedPost.pending.where(category_id: category.id).order(:id).last.tap do |reviewable|
        expect(reviewable).to be_present
      end
    end

    it "preserves product payload through native approval and binds images only when published" do
      id = private_image
      reviewable = queue_product(id)
      expect(reviewable.payload).to include(
        IsbfMarketplace::PRICE_FIELD => "0.25", IsbfMarketplace::IMAGES_FIELD => [id].to_json, IsbfMarketplace::HOME_FIELD => "true",
      )
      expect(IsbfMarketplace::Images.metadata(id)[:bound]).to eq(false)
      approval = reviewable.perform(admin, :approve_post)
      expect(approval.success?).to eq(true), approval.errors.inspect
      topic = approval.created_post.topic.reload
      expect(topic.custom_fields).to include(IsbfMarketplace::PRICE_FIELD => 25, IsbfMarketplace::IMAGES_FIELD => [id], IsbfMarketplace::HOME_FIELD => true)
      expect(IsbfMarketplace::Images.metadata(id)).to include(bound: true, topic_id: topic.id)
    end

    it "rejects through native review without publishing or binding the image" do
      id = private_image
      reviewable = queue_product(id)
      expect { expect(reviewable.perform(admin, :reject_post).success?).to eq(true) }.not_to change(Topic, :count)
      expect(reviewable.reload).to be_rejected
      expect(reviewable.payload[IsbfMarketplace::IMAGES_FIELD]).to eq([id].to_json)
      expect(IsbfMarketplace::Images.metadata(id)[:bound]).to eq(false)
    end

    it "revalidates changed queued payload even when native approval skips validations" do
      id = private_image
      reviewable = queue_product(id)
      reviewable.update!(payload: reviewable.payload.merge(IsbfMarketplace::IMAGES_FIELD => [private_image(other_member)].to_json))
      expect do
        begin
          approval = reviewable.perform(admin, :approve_post)
          expect(approval.success?).to eq(false)
        rescue Discourse::InvalidAccess, Discourse::InvalidParameters
          # Both native failure forms must leave the queued item unpublished.
        end
      end.not_to change(Topic, :count)
      expect(reviewable.reload).to be_pending
      expect(IsbfMarketplace::Images.metadata(id)[:bound]).to eq(false)
    end

    it "grants pending photos only to the uploader and native reviewers for this category" do
      id = private_image
      reviewable = queue_product(id)
      group = Fabricate(:group)
      reviewer = Fabricate(:user, groups: [group], refresh_auto_groups: true)
      SiteSetting.enable_category_group_moderation = true
      Fabricate(:category_moderation_group, category: category, group: group)
      expect(Reviewable.viewable_by(reviewer, preload: false)).to exist(id: reviewable.id)
      [member, admin, reviewer].each do |viewer|
        sign_in(viewer)
        get "/isbf/marketplace/images/#{id}"
        expect(response.status).to eq(200), response.body
        expect(response.headers["Cache-Control"]).to include("no-store")
      end
      sign_in(other_member)
      get "/isbf/marketplace/images/#{id}"
      expect(response.status).to eq(403), response.body
      category.category_moderation_groups.where(group: group).delete_all
      sign_in(reviewer)
      get "/isbf/marketplace/images/#{id}/thumbnail"
      expect(response.status).to eq(403), response.body
    end
  end

  context "with a published private photo" do
    before do
      @id = private_image
      submit(isbf_marketplace_images: [@id].to_json)
      @first = created_post
    end

    it "serves members and rechecks category access on subsequent requests" do
      sign_in(other_member)
      get "/isbf/marketplace/images/#{@id}/thumbnail"
      expect(response.status).to eq(200), response.body
      category.set_permissions(staff: :full)
      category.save!
      get "/isbf/marketplace/images/#{@id}/thumbnail"
      expect([403, 404]).to include(response.status)
    end

    [:hidden, :user_deleted, :deleted_post, :deleted_topic, :unlisted].each do |state|
      it "denies both photo sizes to the owner when the product becomes #{state}" do
        case state
        when :hidden then @first.update!(hidden: true)
        when :user_deleted then @first.update!(user_deleted: true)
        when :deleted_post then @first.trash!
        when :deleted_topic then @first.topic.trash!
        when :unlisted then @first.topic.update!(visible: false)
        end
        ["", "/thumbnail"].each do |suffix|
          get "/isbf/marketplace/images/#{@id}#{suffix}"
          expect([403, 404]).to include(response.status)
        end
      end
    end
  end

  context "with native topic lists" do
    before { sign_in(member) }

    it "filters home opt-outs before pagination while keeping category and native filter lists complete" do
      visible = make_product(home: true, created_at: 2.days.ago)
      hidden_from_home = make_product(created_at: 1.day.ago)
      ordinary = Fabricate(:topic, category: other_category, bumped_at: 3.days.ago)
      stub_const(TopicQuery, "DEFAULT_PER_PAGE_COUNT", 1) do
        get "/latest.json"
        expect(topic_ids).to eq([visible.id])
        get "/latest.json", params: { page: 1 }
        expect(topic_ids).to eq([ordinary.id])
      end
      get "/c/#{category.slug}/#{category.id}/l/latest.json"
      expect(topic_ids).to include(visible.id, hidden_from_home.id)
      get "/filter.json", params: { q: "category:#{category.slug} order:created" }
      expect(topic_ids).to include(visible.id, hidden_from_home.id)
      get "/latest.json", params: { category: category.id }
      expect(topic_ids).to include(visible.id, hidden_from_home.id)
    end

    it "shows only published products in the marketplace filter regardless of home opt-in" do
      opted_in = make_product(home: true, created_at: 2.days.ago)
      opted_out = make_product(created_at: 1.day.ago)
      bare = Fabricate(:post, topic: Fabricate(:topic, category: category)).topic
      hidden = make_product
      hidden.first_post.update!(hidden: true)
      deleted = make_product
      deleted.first_post.trash!
      get "/filter.json", params: { q: "isbf-marketplace:all order:created" }
      expect(topic_ids).to eq([opted_out.id, opted_in.id])
      expect(topic_ids).not_to include(bare.id, hidden.id, deleted.id)
    end

    it "does not apply the home exclusion to latest requests carrying a native filter query" do
      product = make_product
      get "/latest.json", params: { q: "category:#{category.slug}" }
      expect(topic_ids).to include(product.id)
    end

    it "retains native category visibility in the marketplace gallery" do
      product = make_product
      category.set_permissions(staff: :full)
      category.save!
      get "/filter.json", params: { q: "isbf-marketplace:all order:created" }
      expect(topic_ids).not_to include(product.id)
      sign_in(admin)
      get "/filter.json", params: { q: "isbf-marketplace:all order:created" }
      expect(topic_ids).to include(product.id)
    end

    it "preserves the native tag listing for a home opt-out product" do
      SiteSetting.tagging_enabled = true
      product = make_product
      tag = Fabricate(:tag)
      product.tags << tag
      get "/tag/#{tag.id}.json"
      expect(topic_ids).to include(product.id)
    end

    it "keeps product search and author activity available when home display is disabled" do
      UserActionManager.enable
      first = nil
      SearchIndexer.with_indexing do
        submit(title: "Marketplace unique searchable bicycle")
        first = created_post
        SearchIndexer.index(first.topic, force: true)
        SearchIndexer.index(first, force: true)
      end
      get "/search.json", params: { q: "searchable bicycle" }
      expect(response.status).to eq(200), response.body
      expect(response.parsed_body.fetch("topics").map { |topic| topic.fetch("id") }).to include(first.topic_id)
      get "/user_actions.json", params: { username: member.username, filter: UserAction::NEW_TOPIC }
      expect(response.status).to eq(200), response.body
      expect(response.parsed_body.fetch("user_actions").map { |action| action.fetch("topic_id") }).to include(first.topic_id)
    end
  end
end
