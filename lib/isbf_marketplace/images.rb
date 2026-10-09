# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "tempfile"
require "fastimage"

module IsbfMarketplace
  module Images
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    QUOTA_KEY = "storage-bytes"
    MAX_STORAGE_BYTES = 2048 * 1024 * 1024
    MAX_PIXELS = 40_000_000
    CHUNK_BYTES = 64 * 1024
    TYPES = { "jpg" => :jpeg, "jpeg" => :jpeg, "png" => :png, "gif" => :gif, "webp" => :webp }.freeze
    CONTENT_TYPES = { jpeg: "image/jpeg", png: "image/png", gif: "image/gif", webp: "image/webp" }.freeze

    class << self
      def valid_id?(id)
        id.is_a?(String) && UUID.match?(id)
      end

      def root
        ENV["ISBF_MARKETPLACE_STORAGE_PATH"].presence ||
          (Rails.env.test? ? Rails.root.join("tmp/isbf-marketplace-private-test").to_s : "/shared/isbf-marketplace-private")
      end

      def path(id, thumbnail: false)
        raise Discourse::InvalidParameters.new(:id) unless valid_id?(id)
        destination = File.join(private_root!, "#{id}.#{thumbnail ? "thumbnail.png" : "original"}")
        reject_symlinks!(destination)
        destination
      end

      def metadata(id)
        path(id)
        row = PluginStore.get(IsbfMarketplace::STORE, "image:#{id}")
        return nil unless row
        {
          id: id,
          name: row["name"],
          size: row["size"],
          owner_id: row["owner_id"],
          bound: row["bound"] == true,
          topic_id: row["topic_id"],
          content_type: row["content_type"],
          width: row["width"],
          height: row["height"],
          url: "/isbf/marketplace/images/#{id}",
          thumbnail_url: "/isbf/marketplace/images/#{id}/thumbnail",
        }
      end

      def mark_bound!(id, topic_id)
        path(id)
        PluginStoreRow.transaction do
          row = PluginStoreRow.lock.find_by!(plugin_name: IsbfMarketplace::STORE, key: "image:#{id}")
          data = PluginStore.cast_value(row.type_name, row.value)
          if data["bound"] == true && data["topic_id"] != topic_id
            raise IsbfMarketplace::StorageError, "图片已用于其他商品"
          end
          data["bound"] = true
          data["topic_id"] = topic_id
          unless PluginStore.set(IsbfMarketplace::STORE, "image:#{id}", data)
            raise IsbfMarketplace::StorageError, "无法保存图片关联"
          end
        end
      end

      def download(id, user, guardian, thumbnail: false)
        destination = path(id, thumbnail: thumbnail)
        unless user && IsbfMarketplace.image_accessible?(id, user, guardian)
          raise Discourse::InvalidAccess
        end
        info = metadata(id)
        raise Discourse::NotFound unless info && File.file?(destination)
        {
          path: destination,
          name: thumbnail ? "#{id}.png" : info[:name],
          size: File.size(destination),
          content_type: thumbnail ? "image/png" : info[:content_type],
        }
      end

      def upload(user, guardian, file)
        raise Discourse::InvalidAccess unless user
        IsbfMarketplace.ensure_can_submit!(user, guardian)
        unless file.is_a?(ActionDispatch::Http::UploadedFile)
          raise Discourse::InvalidParameters.new(:file)
        end
        RateLimiter.new(user, "uploads-per-minute", SiteSetting.max_uploads_per_minute, 1.minute).performed!
        name = File.basename(file.original_filename.to_s.tr("\\", "/"))
        extension = File.extname(name).delete_prefix(".").downcase
        validate_upload!(user, name, file.size, extension)
        id = SecureRandom.uuid
        original_path = path(id)
        thumbnail_path = path(id, thumbnail: true)
        FileUtils.mkdir_p(private_root!, mode: 0o700)
        # Recheck ancestors after creation, before creating or publishing private bytes.
        private_root!
        original = thumbnail = nil
        published = []
        committed = false
        begin
          original = Tempfile.new([".pending-", ".#{extension}"], private_root!)
          original.binmode
          size = copy_upload!(file, original)
          validate_upload!(user, name, size, extension)
          original.flush
          original.fsync
          type, width, height = inspect_image!(original.path, extension)
          thumbnail = Tempfile.new([".pending-thumbnail-", ".png"], private_root!)
          thumbnail.close
          scale = [224.0 / width, 224.0 / height, 1.0].min
          begin
            decoded = OptimizedImage.resize(
              original.path, thumbnail.path,
              [(width * scale).floor, 1].max, [(height * scale).floor, 1].max,
              format: "png", raise_on_error: true,
            )
            raise IsbfMarketplace::StorageError, "图片无法完整解码" unless decoded
          rescue IsbfMarketplace::StorageError
            raise
          rescue StandardError
            raise IsbfMarketplace::StorageError, "图片无法完整解码"
          end
          thumb_type, thumb_width, thumb_height = inspect_image!(thumbnail.path, "png")
          unless thumb_type == :png && thumb_width <= 224 && thumb_height <= 224
            raise IsbfMarketplace::StorageError, "无法生成图片缩略图"
          end
          thumbnail_size = File.size(thumbnail.path)
          File.chmod(0o600, thumbnail.path)
          original.close
          total_size = size + thumbnail_size
          DistributedMutex.synchronize("isbf-marketplace-image-storage") do
            PluginStoreRow.transaction do
              counter = PluginStoreRow.find_or_create_by!(plugin_name: IsbfMarketplace::STORE, key: QUOTA_KEY) do |row|
                row.type_name = "Integer"
                row.value = "0"
              end
              # The row lock also enforces quota if the Redis mutex lease expires.
              counter.lock!
              if total_size > quota_limit - counter.value.to_i
                raise IsbfMarketplace::StorageError, "商城图片存储空间已满"
              end
              [[original.path, original_path], [thumbnail.path, thumbnail_path]].each do |from, to|
                path(id, thumbnail: to == thumbnail_path)
                raise IsbfMarketplace::StorageError, "图片存储路径已存在" if File.exist?(to)
                File.rename(from, to)
                published << to
              end
              unless PluginStore.set(IsbfMarketplace::STORE, "image:#{id}", {
                name: name, size: size, thumbnail_size: thumbnail_size, owner_id: user.id,
                bound: false, content_type: CONTENT_TYPES.fetch(type), width: width, height: height,
              })
                raise IsbfMarketplace::StorageError, "无法保存图片信息"
              end
              counter.update!(value: (counter.value.to_i + total_size).to_s)
            end
            committed = true
          end
          info = metadata(id)
          {
            id: id, original_filename: name, filesize: size, extension: extension,
            short_url: info[:url], url: info[:url], thumbnail_url: info[:thumbnail_url],
            width: width, height: height,
          }
        ensure
          published.each { |destination| File.unlink(destination) if File.exist?(destination) } unless committed
          original&.close!
          thumbnail&.close!
        end
      rescue SystemCallError, IOError, ActiveRecord::ActiveRecordError
        raise IsbfMarketplace::StorageError, "商城图片存储暂时不可用"
      end

      private

      def private_root!
        base = File.expand_path(root)
        [Rails.root.join("public").to_s, "/shared/uploads"].each do |public_root|
          public_root = File.expand_path(public_root)
          if base == public_root || base.start_with?(public_root + File::SEPARATOR)
            raise IsbfMarketplace::StorageError, "图片必须存储在非公开目录"
          end
        end
        reject_symlinks!(base)
        if File.exist?(base) && !File.directory?(base)
          raise IsbfMarketplace::StorageError, "图片存储目录无效"
        end
        base
      end

      def reject_symlinks!(destination)
        current = destination
        loop do
          if File.symlink?(current)
            raise IsbfMarketplace::StorageError, "图片存储路径不能包含符号链接"
          end
          parent = File.dirname(current)
          break if parent == current
          current = parent
        end
      end

      def quota_limit
        [[SiteSetting.isbf_marketplace_storage_limit_mb.to_i, 0].max * 1024 * 1024, MAX_STORAGE_BYTES].min
      end

      def validate_upload!(user, name, size, extension)
        unless TYPES.key?(extension) && size.positive?
          raise IsbfMarketplace::StorageError, "请上传有效的 JPG、PNG、GIF 或 WEBP 图片"
        end
        if SiteSetting.max_image_size_kb.to_i > 0 && size > SiteSetting.max_image_size_kb.to_i * 1024
          raise IsbfMarketplace::StorageError, "图片超过站点允许的大小"
        end
        transient = Upload.new(user: user, original_filename: name, filesize: size, validate_file_size: true)
        unless transient.valid?
          raise IsbfMarketplace::StorageError, transient.errors.full_messages.join("; ").presence || "图片类型或大小不符合站点设置"
        end
      end

      def copy_upload!(file, temporary)
        size = 0
        limit = [quota_limit, SiteSetting.max_image_size_kb.to_i > 0 ? SiteSetting.max_image_size_kb.to_i * 1024 : MAX_STORAGE_BYTES].min
        file.rewind
        while chunk = file.read(CHUNK_BYTES)
          size += chunk.bytesize
          raise IsbfMarketplace::StorageError, "图片超过允许的大小" if size > limit
          temporary.write(chunk)
        end
        size
      end

      def inspect_image!(image_path, extension)
        type = FastImage.type(image_path)
        dimensions = FastImage.size(image_path)
        unless type == TYPES.fetch(extension) && dimensions && dimensions.all? { |value| value.is_a?(Numeric) && value.positive? }
          raise IsbfMarketplace::StorageError, "图片内容与文件类型不符或图片已损坏"
        end
        native_limit = SiteSetting.respond_to?(:max_image_megapixels) ? SiteSetting.max_image_megapixels.to_f * 1_000_000 : 0
        limit = native_limit.positive? ? [native_limit, MAX_PIXELS].min : MAX_PIXELS
        if dimensions[0] * dimensions[1] > limit
          raise IsbfMarketplace::StorageError, "图片像素过大"
        end
        [type, *dimensions]
      rescue IsbfMarketplace::StorageError
        raise
      rescue StandardError
        raise IsbfMarketplace::StorageError, "图片已损坏或格式不受支持"
      end
    end
  end
end
