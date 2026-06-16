class RedbarkItem::Importer
  attr_reader :redbark_item, :redbark_provider

  def initialize(redbark_item, redbark_provider:)
    @redbark_item = redbark_item
    @redbark_provider = redbark_provider
  end

  def import
    Rails.logger.info "RedbarkItem::Importer - Starting import for item #{redbark_item.id}"

    accounts_data = fetch_accounts_data
    unless accounts_data
      Rails.logger.error "RedbarkItem::Importer - Failed to fetch accounts data for item #{redbark_item.id}"
      return {
        success: false,
        error: "Failed to fetch accounts data",
        accounts_updated: 0,
        accounts_created: 0,
        accounts_failed: 0,
        accounts_pruned: 0,
        transactions_imported: 0,
        transactions_failed: 0
      }
    end

    begin
      redbark_item.upsert_redbark_snapshot!(accounts_data)
    rescue => e
      Rails.logger.error "RedbarkItem::Importer - Failed to store accounts snapshot: #{e.message}"
    end

    accounts_updated = 0
    accounts_created = 0
    accounts_failed = 0
    accounts_pruned = 0

    if accounts_data[:accounts].present?
      linked_account_ids = redbark_item.redbark_accounts
                                       .joins(:account_provider)
                                       .pluck(:account_id)
                                       .map(&:to_s)
      all_existing_ids = redbark_item.redbark_accounts.pluck(:account_id).map(&:to_s)

      accounts_data[:accounts].each do |account_data|
        account_id = account_data[:id]&.to_s
        next unless account_id.present?
        next if account_data[:name].blank?

        if linked_account_ids.include?(account_id)
          begin
            import_account(account_data)
            accounts_updated += 1
          rescue => e
            accounts_failed += 1
            Rails.logger.error "RedbarkItem::Importer - Failed to update account #{account_id}: #{e.message}"
          end
        elsif !all_existing_ids.include?(account_id)
          # Record newly-discovered accounts as unlinked so the user can link them later.
          begin
            redbark_account = redbark_item.redbark_accounts.build(
              account_id: account_id,
              name: account_data[:name],
              currency: account_data[:currency] || "AUD"
            )
            redbark_account.upsert_redbark_snapshot!(account_data)
            accounts_created += 1
          rescue => e
            accounts_failed += 1
            Rails.logger.error "RedbarkItem::Importer - Failed to create account #{account_id}: #{e.message}"
          end
        end
      end

      # Guard pruning to a non-empty upstream list so a transient empty/failed
      # response can never wipe out all accounts.
      upstream_account_ids = accounts_data[:accounts].filter_map { |a| a[:id].to_s.presence }
      accounts_pruned = prune_orphaned_redbark_accounts(upstream_account_ids)
    end

    Rails.logger.info "RedbarkItem::Importer - Updated #{accounts_updated} accounts, created #{accounts_created} new (#{accounts_failed} failed), pruned #{accounts_pruned}"

    transactions_imported = 0
    transactions_failed = 0

    redbark_item.redbark_accounts.joins(:account).merge(Account.visible).each do |redbark_account|
      begin
        result = fetch_and_store_transactions(redbark_account)
        if result[:success]
          transactions_imported += result[:transactions_count]
        else
          transactions_failed += 1
        end
      rescue => e
        transactions_failed += 1
        Rails.logger.error "RedbarkItem::Importer - Failed to fetch/store transactions for account #{redbark_account.account_id}: #{e.message}"
      end
    end

    Rails.logger.info "RedbarkItem::Importer - Completed import for item #{redbark_item.id}: #{accounts_updated} updated, #{accounts_created} new, #{transactions_imported} transactions"

    {
      success: accounts_failed == 0 && transactions_failed == 0,
      accounts_updated: accounts_updated,
      accounts_created: accounts_created,
      accounts_failed: accounts_failed,
      accounts_pruned: accounts_pruned,
      transactions_imported: transactions_imported,
      transactions_failed: transactions_failed
    }
  end

  private

    # Removes RedbarkAccount records that no longer exist upstream and are not
    # linked to any Account, so a deleted bank account stops lingering as an
    # unlinked "Need setup" record.
    #
    # account_id is nullable, and SQL `NULL NOT IN (...)` is never TRUE, so a
    # NULL-id unlinked record would be silently retained; we OR those back in.
    # The per-record account_provider guard still protects any linked record.
    def prune_orphaned_redbark_accounts(upstream_account_ids)
      return 0 if upstream_account_ids.blank?

      scope = redbark_item.redbark_accounts.includes(:account_provider)
      orphaned = scope.where.not(account_id: upstream_account_ids).or(scope.where(account_id: nil))

      pruned = 0
      orphaned.each do |redbark_account|
        next if redbark_account.account_provider.present?

        begin
          pruned += 1 if redbark_account.destroy
        rescue => e
          Rails.logger.error "RedbarkItem::Importer - Failed to prune RedbarkAccount id=#{redbark_account.id}: #{e.message}"
        end
      end

      pruned
    end

    def fetch_accounts_data
      accounts_data = redbark_provider.get_accounts

      unless accounts_data.is_a?(Hash)
        Rails.logger.error "RedbarkItem::Importer - Invalid accounts_data format: #{accounts_data.class}"
        return nil
      end

      accounts_data
    rescue Provider::Redbark::RedbarkError => e
      if e.error_type == :unauthorized || e.error_type == :access_forbidden
        redbark_item.update!(status: :requires_update) rescue nil
      end
      Rails.logger.error "RedbarkItem::Importer - Redbark API error: #{e.message}"
      nil
    rescue JSON::ParserError => e
      Rails.logger.error "RedbarkItem::Importer - Failed to parse Redbark API response: #{e.message}"
      nil
    rescue => e
      Rails.logger.error "RedbarkItem::Importer - Unexpected error fetching accounts: #{e.class} - #{e.message}"
      nil
    end

    def import_account(account_data)
      raise ArgumentError, "Invalid account data format" unless account_data.is_a?(Hash)

      account_id = account_data[:id]
      raise ArgumentError, "Account ID is required" if account_id.blank?

      # Sync only updates accounts the user already linked; new accounts are
      # discovered (and linked) elsewhere.
      redbark_account = redbark_item.redbark_accounts.find_by(account_id: account_id.to_s)
      return unless redbark_account

      redbark_account.upsert_redbark_snapshot!(account_data)
      redbark_account.save!
    rescue ActiveRecord::RecordInvalid => e
      raise StandardError.new("Failed to save account: #{e.message}")
    end

    def fetch_and_store_transactions(redbark_account)
      # Transactions require the owning connection id. If it's missing, sync the
      # balance and move on rather than calling the API with a blank connectionId.
      if redbark_account.connection_id.blank?
        Rails.logger.warn "RedbarkItem::Importer - Account #{redbark_account.account_id} has no connection_id; fetching balance only"
        fetch_and_update_balance(redbark_account) rescue nil
        return { success: true, transactions_count: 0 }
      end

      start_date = determine_sync_start_date(redbark_account)
      include_pending = Rails.configuration.x.redbark.include_pending

      begin
        transactions_data = redbark_provider.get_account_transactions(
          redbark_account.account_id,
          connection_id: redbark_account.connection_id,
          start_date: start_date
        )

        if Rails.configuration.x.redbark.debug_raw
          Rails.logger.debug "Redbark raw response: #{transactions_data.to_json}"
        end

        unless transactions_data.is_a?(Hash)
          return { success: false, transactions_count: 0, error: "Invalid response format" }
        end

        fetched = Array(transactions_data[:transactions])

        # The Redbark API has no include_pending toggle, so we filter client-side.
        # Default is posted-only; pending is opt-in via REDBARK_INCLUDE_PENDING.
        unless include_pending
          fetched = fetched.select { |tx| tx.is_a?(Hash) && tx.with_indifferent_access[:status] == "posted" }
        end

        transactions_count = fetched.count

        if fetched.present?
          existing = redbark_account.raw_transactions_payload.to_a
          existing_ids = existing.filter_map { |tx| tx.with_indifferent_access[:id] }.to_set

          new_transactions = fetched.select do |tx|
            tx.is_a?(Hash) && !existing_ids.include?(tx.with_indifferent_access[:id])
          end

          redbark_account.upsert_redbark_transactions_snapshot!(existing + new_transactions) if new_transactions.any?
        end

        # Balance is best-effort; never fail the transaction import over it.
        fetch_and_update_balance(redbark_account) rescue nil

        { success: true, transactions_count: transactions_count }
      rescue Provider::Redbark::RedbarkError => e
        Rails.logger.error "RedbarkItem::Importer - Redbark API error for account #{redbark_account.id}: #{e.message}"
        { success: false, transactions_count: 0, error: e.message }
      rescue JSON::ParserError => e
        { success: false, transactions_count: 0, error: "Failed to parse response" }
      rescue => e
        Rails.logger.error "RedbarkItem::Importer - Unexpected error fetching transactions for account #{redbark_account.id}: #{e.class} - #{e.message}"
        { success: false, transactions_count: 0, error: "Unexpected error: #{e.message}" }
      end
    end

    def fetch_and_update_balance(redbark_account)
      balance_info = redbark_provider.get_account_balance(redbark_account.account_id)[:balance]
      return unless balance_info.is_a?(Hash) && balance_info[:amount].present?

      redbark_account.update!(
        current_balance: balance_info[:amount],
        currency: balance_info[:currency].presence || redbark_account.currency
      )
    rescue Provider::Redbark::RedbarkError, ActiveRecord::RecordInvalid => e
      Rails.logger.error "RedbarkItem::Importer - Failed to update balance for account #{redbark_account.id}: #{e.message}"
    end

    FIRST_SYNC_WINDOW = 90.days
    INCREMENTAL_BUFFER = 7.days

    # First sync (no stored transactions) pulls the full historical window so the
    # user gets meaningful history on connect; later syncs fetch from the last
    # sync with a buffer to catch late-posting items.
    def determine_sync_start_date(redbark_account)
      has_stored_transactions = redbark_account.raw_transactions_payload.to_a.any?

      if has_stored_transactions && redbark_item.last_synced_at
        redbark_item.last_synced_at - INCREMENTAL_BUFFER
      else
        FIRST_SYNC_WINDOW.ago
      end
    end
end
