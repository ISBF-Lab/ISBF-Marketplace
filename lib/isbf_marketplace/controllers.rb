# frozen_string_literal: true

module IsbfMarketplace
  class Engine < ::Rails::Engine
    engine_name "isbf-marketplace"
    isolate_namespace IsbfMarketplace
  end

  class ProductsController < ::ApplicationController
    wrap_parameters false
    requires_login
    requires_plugin "isbf-marketplace"

    def page
      category = Category.find_by(id: IsbfMarketplace.category_id)
      raise Discourse::NotFound unless category && guardian.can_see_category?(category)
      render html: "".html_safe, layout: "application"
    end

    def upload
      file = params[:file] || Array(params[:files]).first
      render json: Images.upload(current_user, guardian, file)
    rescue StorageError => error
      render_json_error(error.message, status: 422)
    end

    def image
      response.headers["Cache-Control"] = "private, no-store"
      response.headers["X-Content-Type-Options"] = "nosniff"
      image = Images.download(params[:id], current_user, guardian, thumbnail: params[:thumbnail] == "true")
      send_file image[:path], filename: image[:name], type: image[:content_type], disposition: "inline"
    end
  end
end
