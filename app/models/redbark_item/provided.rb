module RedbarkItem::Provided
  extend ActiveSupport::Concern

  def redbark_provider
    return nil unless credentials_configured?

    Provider::Redbark.new(api_key, base_url: effective_base_url)
  end
end
