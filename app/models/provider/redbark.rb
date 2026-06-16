class Provider::Redbark
  include HTTParty
  extend SslConfigurable

  headers "User-Agent" => "Sure Finance Redbark Client"
  default_options.merge!({ timeout: 120 }.merge(httparty_ssl_options))

  PAGE_LIMIT = 200
  # Safety cap so a misbehaving `hasMore` can never spin forever.
  MAX_PAGES = 200
  # This provider syncs bank accounts only. The balances endpoint rejects
  # brokerage/document accounts outright, so we surface banking accounts only.
  BANKING_CATEGORY = "banking".freeze

  attr_reader :api_key, :base_url

  def initialize(api_key, base_url: "https://api.redbark.com")
    @api_key = api_key
    @base_url = base_url
  end

  # Returns every account the API key can see, each merged with its connection's
  # institution metadata so the rest of the pipeline can treat it like a flat list.
  #
  # Returns: { accounts: [ { id, name, type, currency, status, provider,
  #   connection_id, institution_name, institution_logo, account_number } ], total: N }
  def get_accounts
    connection_index = fetch_collection("/v1/connections").index_by { |c| c[:id] }

    accounts = fetch_paginated("/v1/accounts").filter_map do |acc|
      conn = connection_index[acc[:connectionId]] || {}
      next unless conn[:category] == BANKING_CATEGORY

      {
        id: acc[:id],
        name: acc[:name],
        type: acc[:type],
        currency: acc[:currency],
        status: conn[:status] || "active",
        provider: acc[:provider],
        connection_id: acc[:connectionId],
        institution_name: acc[:institutionName] || conn[:institutionName],
        institution_logo: conn[:institutionLogo],
        account_number: acc[:accountNumber]
      }
    end

    { accounts: accounts, total: accounts.size }
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error "Redbark API: GET /v1/accounts failed: #{e.class}: #{e.message}"
    raise RedbarkError.new("Exception during GET request: #{e.message}", :request_failed)
  end

  # Transactions for one account. The Redbark API requires the owning connection id.
  #
  # Returns: { transactions: [ { id, accountId, status, date, description, amount,
  #   direction, category, merchantName, merchantCategoryCode } ] }
  def get_account_transactions(account_id, connection_id:, start_date: nil, end_date: nil)
    query = { connectionId: connection_id, accountId: account_id }
    query[:from] = start_date.to_date.to_s if start_date
    query[:to] = end_date.to_date.to_s if end_date

    transactions = fetch_paginated("/v1/transactions", query)
    { transactions: transactions }
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error "Redbark API: GET /v1/transactions failed: #{e.class}: #{e.message}"
    raise RedbarkError.new("Exception during GET request: #{e.message}", :request_failed)
  end

  # Current balance for one account.
  #
  # Returns: { balance: { amount: "1234.56", currency: "AUD" } } or { balance: nil }
  def get_account_balance(account_id)
    data = request("/v1/balances", accountIds: account_id)
    row = Array(data[:data]).first
    return { balance: nil } unless row

    { balance: { amount: row[:currentBalance], currency: row[:currency] } }
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error "Redbark API: GET /v1/balances failed: #{e.class}: #{e.message}"
    raise RedbarkError.new("Exception during GET request: #{e.message}", :request_failed)
  end

  private

    def auth_headers
      {
        "Authorization" => "Bearer #{api_key}",
        "Accept" => "application/json"
      }
    end

    # Single GET; returns the parsed body as a symbolized hash.
    def request(path, query = {})
      response = self.class.get("#{base_url}#{path}", headers: auth_headers, query: query)
      handle_response(response)
    end

    # For endpoints that return { data: [...] } with no pagination envelope.
    def fetch_collection(path, query = {})
      Array(request(path, query)[:data])
    end

    # For endpoints that return { data: [...], pagination: { hasMore } }.
    # Walks every page and returns the concatenated rows.
    def fetch_paginated(path, query = {})
      rows = []
      offset = 0
      capped = true

      MAX_PAGES.times do
        body = request(path, query.merge(limit: PAGE_LIMIT, offset: offset))
        rows.concat(Array(body[:data]))

        pagination = body[:pagination] || {}
        unless pagination[:hasMore]
          capped = false
          break
        end
        offset += PAGE_LIMIT
      end

      Rails.logger.warn "Redbark API: hit pagination cap (#{MAX_PAGES} pages) for #{path}; some rows may be unfetched" if capped
      rows
    end

    def handle_response(response)
      case response.code
      when 200
        JSON.parse(response.body, symbolize_names: true)
      when 400
        Rails.logger.error "Redbark API: Bad request - #{response.body}"
        raise RedbarkError.new("Bad request to Redbark API: #{response.body}", :bad_request)
      when 401
        raise RedbarkError.new("Invalid API key", :unauthorized)
      when 403
        raise RedbarkError.new("Access forbidden - check your API key permissions", :access_forbidden)
      when 404
        raise RedbarkError.new("Resource not found", :not_found)
      when 429
        raise RedbarkError.new("Rate limit exceeded. Please try again later.", :rate_limited)
      else
        Rails.logger.error "Redbark API: Unexpected response - Code: #{response.code}, Body: #{response.body}"
        raise RedbarkError.new("Failed to fetch data: #{response.code} #{response.message} - #{response.body}", :fetch_failed)
      end
    end

    class RedbarkError < StandardError
      attr_reader :error_type

      def initialize(message, error_type = :unknown)
        super(message)
        @error_type = error_type
      end
    end
end
