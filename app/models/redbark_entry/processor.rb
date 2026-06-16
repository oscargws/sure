require "digest/md5"

class RedbarkEntry::Processor
  include CurrencyNormalizable

  # redbark_transaction is the raw hash fetched from the Redbark API and stored as JSONB.
  # Transaction structure: { id, accountId, status, date, description, amount,
  #   direction, category, merchantName, merchantCategoryCode }
  def initialize(redbark_transaction, redbark_account:)
    @redbark_transaction = redbark_transaction
    @redbark_account = redbark_account
  end

  def process
    unless account.present?
      Rails.logger.warn "RedbarkEntry::Processor - No linked account for redbark_account #{redbark_account.id}, skipping transaction #{external_id}"
      return nil
    end

    # If this incoming pending transaction already has a posted counterpart (the
    # posted version arrived first, out of order), skip it so we don't create a
    # duplicate. The reverse case (pending first, posted later) is handled by the
    # shared import adapter's pending->posted reconciliation.
    if is_pending?
      existing_posted = find_existing_posted_version
      if existing_posted
        Rails.logger.info "RedbarkEntry::Processor - Skipping pending #{external_id}; posted version #{existing_posted.external_id} already exists"
        return existing_posted
      end
    end

    begin
      import_adapter.import_transaction(
        external_id: external_id,
        amount: amount,
        currency: currency,
        date: date,
        name: name,
        source: "redbark",
        merchant: merchant,
        notes: notes,
        extra: extra_metadata
      )
    rescue ArgumentError => e
      Rails.logger.error "RedbarkEntry::Processor - Validation error for transaction #{external_id}: #{e.message}"
      raise
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
      Rails.logger.error "RedbarkEntry::Processor - Failed to save transaction #{external_id}: #{e.message}"
      raise StandardError.new("Failed to import transaction: #{e.message}")
    rescue => e
      Rails.logger.error "RedbarkEntry::Processor - Unexpected error processing transaction #{external_id}: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      raise StandardError.new("Unexpected error importing transaction: #{e.message}")
    end
  end

  private
    attr_reader :redbark_transaction, :redbark_account

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      @account ||= redbark_account.current_account
    end

    def data
      @data ||= redbark_transaction.with_indifferent_access
    end

    # Redbark transaction ids are always present and stable (e.g. "bank_tx_..."),
    # so the external id is a simple namespaced passthrough.
    def external_id
      @external_id ||= "redbark_#{data[:id]}"
    end

    def name
      data[:merchantName].presence || data[:description].presence || "Unknown transaction"
    end

    # Keep the bank's raw description as a note when it differs from the display name.
    def notes
      description = data[:description].presence
      return nil if description.nil? || description == name

      description
    end

    def merchant
      merchant_name = data[:merchantName].to_s.strip
      return nil if merchant_name.blank?

      merchant_id = Digest::MD5.hexdigest(merchant_name.downcase)

      @merchant ||= begin
        import_adapter.find_or_create_merchant(
          provider_merchant_id: "redbark_merchant_#{merchant_id}",
          name: merchant_name,
          source: "redbark"
        )
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.error "RedbarkEntry::Processor - Failed to create merchant '#{merchant_name}': #{e.message}"
        nil
      end
    end

    # Redbark amounts are signed strings, and each transaction also carries an
    # explicit direction (credit = money in, debit = money out). Sure/Maybe stores
    # expenses as positive and income as negative, so a debit maps to +magnitude
    # and a credit maps to -magnitude.
    def amount
      magnitude = BigDecimal(data[:amount].to_s).abs
      data[:direction].to_s == "credit" ? -magnitude : magnitude
    rescue ArgumentError => e
      Rails.logger.error "Failed to parse Redbark transaction amount: #{data[:amount].inspect} - #{e.message}"
      raise
    end

    # The Redbark transactions endpoint does not return a per-transaction currency,
    # so we use the linked account's currency.
    def currency
      account&.currency || parse_currency(redbark_account.currency) || "AUD"
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for Redbark account #{redbark_account.id}, falling back to account currency")
    end

    def date
      Date.parse(data[:date].to_s)
    rescue ArgumentError, TypeError => e
      Rails.logger.error("Failed to parse Redbark transaction date '#{data[:date]}': #{e.message}")
      raise ArgumentError, "Unable to parse transaction date: #{data[:date].inspect}"
    end

    # Store provider-specific metadata. The pending flag lives under the "redbark"
    # key so Transaction::PENDING_PROVIDERS / the import adapter can reconcile
    # pending→posted the same way as the other providers.
    def extra_metadata
      {
        redbark: {
          pending: is_pending?,
          category: data[:category].presence,
          merchant_category_code: data[:merchantCategoryCode].presence
        }.compact
      }
    end

    def is_pending?
      data[:status].to_s == "pending"
    end

    # Finds a posted Redbark entry this pending transaction would duplicate, using
    # the same exact amount + currency + 8-day forward window the import adapter
    # uses for reconciliation. Excludes entries that are themselves still pending
    # so two pending transactions can't match each other.
    def find_existing_posted_version
      return nil unless account.present?

      query = account.entries
        .joins("INNER JOIN transactions t ON t.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where(source: "redbark")
        .where(amount: amount)
        .where(currency: currency)
        .where("entries.date BETWEEN ? AND ?", date, date + 8)
        .where("(t.extra -> 'redbark' ->> 'pending')::boolean IS DISTINCT FROM true")
        .order(:date)

      query = query.where(name: name) if data[:merchantName].present?
      query.first
    end
end
