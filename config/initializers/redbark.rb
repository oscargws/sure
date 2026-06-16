# Redbark integration runtime configuration
Rails.application.configure do
  # Controls whether pending transactions are included in Redbark syncs
  # When true, adds include_pending=true to transaction fetch requests
  # Default: false (only posted/settled transactions)
  config.x.redbark.include_pending = ENV["REDBARK_INCLUDE_PENDING"].to_s.strip.downcase.in?(%w[1 true yes])

  # Debug logging for raw Redbark API responses
  # When enabled, logs the full raw JSON payload from Redbark API
  # Default: false (only log summary info)
  config.x.redbark.debug_raw = ENV["REDBARK_DEBUG_RAW"].to_s.strip.downcase.in?(%w[1 true yes])
end
