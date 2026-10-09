# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

RSpec.describe IsbfMarketplace::Images do
  fab!(:user)
  let(:guardian) { Guardian.new(user) }

  before do
    @storage_root = Dir.mktmpdir("isbf-marketplace-images")
    @incoming = []
    described_class.stubs(:root).returns(@storage_root)
    IsbfMarketplace.stubs(:ensure_can_submit!).with(user, guardian).returns(true)
    SiteSetting.authorized_extensions = "jpg|jpeg|png|gif|webp|svg|pdf"
    SiteSetting.max_image_size_kb = 2048
    SiteSetting.isbf_marketplace_storage_limit_mb = 1
  end

  after do
    @incoming.each(&:close!)
    FileUtils.remove_entry(@storage_root)
  end

  def incoming(contents = nil, name = "logo.png")
    unless contents
      fixture = file_from_fixtures("logo.png")
      contents = fixture.read
      fixture.close
    end
    temporary = Tempfile.new("isbf-marketplace-incoming")
    temporary.binmode
    temporary.write(contents)
    temporary.rewind
    @incoming << temporary
    ActionDispatch::Http::UploadedFile.new(tempfile: temporary, filename: name, type: "image/png")
  end

  def storage_bytes
    PluginStore.get(IsbfMarketplace::STORE, described_class::QUOTA_KEY)
  end

  it "decodes real images into private thumbnails without native upload records" do
    upload_count = Upload.count
    optimized_count = OptimizedImage.count
    file = incoming
    original = File.binread(file.path)
    result = described_class.upload(user, guardian, file)

    expect(Upload.count).to eq(upload_count)
    expect(OptimizedImage.count).to eq(optimized_count)
    expect(described_class.valid_id?(result[:id])).to eq(true)
    expect(result).to include(original_filename: "logo.png", extension: "png", filesize: original.bytesize)
    expect(result[:url]).to eq("/isbf/marketplace/images/#{result[:id]}")
    expect(result[:short_url]).to eq(result[:url])
    expect(result[:thumbnail_url]).to eq("#{result[:url]}/thumbnail")
    expect(File.binread(described_class.path(result[:id]))).to eq(original)
    thumbnail = described_class.path(result[:id], thumbnail: true)
    expect(FastImage.type(thumbnail)).to eq(:png)
    expect(FastImage.size(thumbnail).max).to be <= 224
    expect(File.stat(thumbnail).mode & 0o777).to eq(0o600)
    expect(File.stat(described_class.path(result[:id])).mode & 0o777).to eq(0o600)
    expect(storage_bytes).to eq(original.bytesize + File.size(thumbnail))
    expect(described_class.metadata(result[:id])).to include(owner_id: user.id, bound: false, content_type: "image/png")
  end

  it "checks submission permissions before writing any bytes" do
    IsbfMarketplace.expects(:ensure_can_submit!).with(user, guardian).raises(Discourse::InvalidAccess)
    expect { described_class.upload(user, guardian, incoming) }.to raise_error(Discourse::InvalidAccess)
    expect(Dir.children(@storage_root)).to be_empty
  end

  it "rejects anonymous uploads" do
    expect { described_class.upload(nil, Guardian.new, incoming) }.to raise_error(Discourse::InvalidAccess)
    expect(Dir.children(@storage_root)).to be_empty
  end

  it "retains the native upload rate limit" do
    limiter = mock("upload rate limiter")
    RateLimiter.expects(:new).with(user, "uploads-per-minute", SiteSetting.max_uploads_per_minute, 60).returns(limiter)
    limiter.expects(:performed!).raises(RateLimiter::LimitExceeded.new(60))
    expect { described_class.upload(user, guardian, incoming) }.to raise_error(RateLimiter::LimitExceeded)
    expect(Dir.children(@storage_root)).to be_empty
  end

  it "intersects the raster allowlist with the native upload extension policy" do
    SiteSetting.authorized_extensions = "jpg"
    expect { described_class.upload(user, guardian, incoming) }.to raise_error(IsbfMarketplace::StorageError)
    expect(Dir.children(@storage_root)).to be_empty
  end

  it "rejects vector, PDF, XML, empty, and disguised nonimage content" do
    [
      ["<svg xmlns='http://www.w3.org/2000/svg'/>", "picture.svg"],
      ["%PDF-1.4", "picture.pdf"],
      ["<?xml version='1.0'?><svg/>", "picture.png"],
      ["", "picture.png"],
      ["ordinary text", "picture.webp"],
    ].each do |contents, name|
      expect { described_class.upload(user, guardian, incoming(contents, name)) }.to raise_error(IsbfMarketplace::StorageError)
      expect(Dir.children(@storage_root)).to be_empty
    end
  end

  it "rejects a real image carrying a mismatched raster extension" do
    expect { described_class.upload(user, guardian, incoming(nil, "picture.jpg")) }.to raise_error(IsbfMarketplace::StorageError)
    expect(Dir.children(@storage_root)).to be_empty
  end

  it "enforces the native maximum image size" do
    SiteSetting.max_image_size_kb = 1
    expect { described_class.upload(user, guardian, incoming("x" * 1025)) }.to raise_error(IsbfMarketplace::StorageError)
    expect(Dir.children(@storage_root)).to be_empty
  end

  it "rejects oversized dimensions before asking the native decoder to process them" do
    FastImage.stubs(:type).returns(:png)
    FastImage.stubs(:size).returns([100_000, 100_000])
    OptimizedImage.expects(:resize).never
    expect { described_class.upload(user, guardian, incoming) }.to raise_error(IsbfMarketplace::StorageError, /像素/)
    expect(Dir.children(@storage_root)).to be_empty
  end

  it "requires successful decoding even when header inspection succeeds" do
    OptimizedImage.expects(:resize).returns(false)
    expect { described_class.upload(user, guardian, incoming) }.to raise_error(IsbfMarketplace::StorageError, /解码/)
    expect(Dir.children(@storage_root)).to be_empty
    expect(storage_bytes).to be_nil
  end

  it "rejects a truncated real image with an intact dimension header" do
    file = incoming
    header = File.binread(file.path, 33)
    expect(FastImage.size(StringIO.new(header))).to be_present
    expect { described_class.upload(user, guardian, incoming(header)) }.to raise_error(IsbfMarketplace::StorageError)
    expect(Dir.children(@storage_root)).to be_empty
  end

  it "accounts for thumbnails when enforcing the shared quota" do
    result = described_class.upload(user, guardian, incoming)
    first_total = storage_bytes
    PluginStore.set(IsbfMarketplace::STORE, described_class::QUOTA_KEY, 1024 * 1024 - result[:filesize])
    expect { described_class.upload(user, guardian, incoming) }.to raise_error(IsbfMarketplace::StorageError, /空间/)
    expect(Dir.children(@storage_root).sort).to eq([
      "#{result[:id]}.original", "#{result[:id]}.thumbnail.png",
    ].sort)
    expect(first_total).to be > result[:filesize]
    expect(storage_bytes).to eq(1024 * 1024 - result[:filesize])
  end

  it "caps the storage setting at 2048 MiB" do
    SiteSetting.stubs(:isbf_marketplace_storage_limit_mb).returns(4096)
    PluginStore.set(IsbfMarketplace::STORE, described_class::QUOTA_KEY, 2048 * 1024 * 1024)
    expect { described_class.upload(user, guardian, incoming) }.to raise_error(IsbfMarketplace::StorageError)
    expect(Dir.children(@storage_root)).to be_empty
  end

  it "rolls back files and quota when metadata persistence fails" do
    PluginStore.set(IsbfMarketplace::STORE, described_class::QUOTA_KEY, 0)
    PluginStore.stubs(:set).returns(false)
    expect { described_class.upload(user, guardian, incoming) }.to raise_error(IsbfMarketplace::StorageError)
    expect(Dir.children(@storage_root)).to be_empty
    expect(storage_bytes).to eq(0)
    expect(PluginStoreRow.where(plugin_name: IsbfMarketplace::STORE).where("key LIKE ?", "image:%")).to be_empty
  end

  it "rolls back both metadata and files when the quota update fails" do
    PluginStoreRow.any_instance.stubs(:update!).raises(ActiveRecord::StatementInvalid)
    expect { described_class.upload(user, guardian, incoming) }.to raise_error(IsbfMarketplace::StorageError)
    expect(Dir.children(@storage_root)).to be_empty
    expect(PluginStoreRow.where(plugin_name: IsbfMarketplace::STORE).where("key LIKE ?", "image:%")).to be_empty
  end

  it "cleans up pending images when the filesystem runs out of space" do
    File.stubs(:rename).raises(Errno::ENOSPC)
    expect { described_class.upload(user, guardian, incoming) }.to raise_error(IsbfMarketplace::StorageError)
    expect(Dir.children(@storage_root)).to be_empty
    expect(PluginStoreRow.where(plugin_name: IsbfMarketplace::STORE).where("key LIKE ?", "image:%")).to be_empty
  end

  it "uses the same delegated access decision for originals and thumbnails" do
    result = described_class.upload(user, guardian, incoming)
    IsbfMarketplace.expects(:image_accessible?).with(result[:id], user, guardian).twice.returns(false)
    [false, true].each do |thumbnail|
      expect { described_class.download(result[:id], user, guardian, thumbnail: thumbnail) }.to raise_error(Discourse::InvalidAccess)
    end
  end

  it "does not grant owners a download bypass once an image is bound" do
    result = described_class.upload(user, guardian, incoming)
    described_class.mark_bound!(result[:id], 123)
    expect(described_class.metadata(result[:id])).to include(bound: true, topic_id: 123, owner_id: user.id)
    IsbfMarketplace.expects(:image_accessible?).with(result[:id], user, guardian).returns(false)
    expect { described_class.download(result[:id], user, guardian) }.to raise_error(Discourse::InvalidAccess)
    expect { described_class.mark_bound!(result[:id], 456) }.to raise_error(IsbfMarketplace::StorageError)
    expect(described_class.metadata(result[:id])[:topic_id]).to eq(123)
  end

  it "serves authorized thumbnails with the actual private PNG content type" do
    result = described_class.upload(user, guardian, incoming)
    IsbfMarketplace.expects(:image_accessible?).with(result[:id], user, guardian).returns(true)
    response = described_class.download(result[:id], user, guardian, thumbnail: true)
    expect(response).to include(content_type: "image/png", name: "#{result[:id]}.png")
    expect(response[:size]).to eq(File.size(response[:path]))
    expect(response[:path]).to eq(described_class.path(result[:id], thumbnail: true))
  end

  it "rejects malformed UUIDs and traversal before storage access" do
    ["../secret", "/etc/passwd", "%2e%2e%2fsecret", SecureRandom.uuid + "/../secret", nil].each do |id|
      expect { described_class.path(id) }.to raise_error(Discourse::InvalidParameters)
    end
  end

  it "rejects both public Rails paths and the shared upload tree" do
    [Rails.root.join("public", "marketplace").to_s, "/shared/uploads/marketplace"].each do |root|
      described_class.stubs(:root).returns(root)
      expect { described_class.path(SecureRandom.uuid) }.to raise_error(IsbfMarketplace::StorageError)
    end
  end

  it "rejects a symlinked ancestor of the storage root" do
    Dir.mktmpdir("isbf-image-ancestor") do |outside|
      link = File.join(@storage_root, "link")
      File.symlink(outside, link)
      described_class.stubs(:root).returns(File.join(link, "nested"))
      expect { described_class.upload(user, guardian, incoming) }.to raise_error(IsbfMarketplace::StorageError, /符号链接/)
      expect(Dir.children(outside)).to be_empty
    end
  end

  it "rejects a symlink substituted for a thumbnail" do
    result = described_class.upload(user, guardian, incoming)
    thumbnail = described_class.path(result[:id], thumbnail: true)
    File.unlink(thumbnail)
    File.symlink(described_class.path(result[:id]), thumbnail)
    expect { described_class.download(result[:id], user, guardian, thumbnail: true) }.to raise_error(IsbfMarketplace::StorageError, /符号链接/)
  end
end
