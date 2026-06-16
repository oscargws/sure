class RedbarkItem::Syncer
  include SyncStats::Collector

  attr_reader :redbark_item

  def initialize(redbark_item)
    @redbark_item = redbark_item
  end

  def perform_sync(sync)
    sync.update!(status_text: "Importing accounts from Redbark...") if sync.respond_to?(:status_text)
    import_result = redbark_item.import_latest_redbark_data

    sync.update!(status_text: "Checking account configuration...") if sync.respond_to?(:status_text)
    collect_setup_stats(sync, provider_accounts: redbark_item.redbark_accounts)

    linked_accounts = redbark_item.redbark_accounts.joins(:account_provider)
    unlinked_accounts = redbark_item.redbark_accounts.left_joins(:account_provider).where(account_providers: { id: nil })

    if unlinked_accounts.any?
      redbark_item.update!(pending_account_setup: true)
      sync.update!(status_text: "#{unlinked_accounts.count} accounts need setup...") if sync.respond_to?(:status_text)
    else
      redbark_item.update!(pending_account_setup: false)
    end

    if linked_accounts.any?
      sync.update!(status_text: "Processing transactions...") if sync.respond_to?(:status_text)
      mark_import_started(sync)
      redbark_item.process_accounts

      sync.update!(status_text: "Calculating balances...") if sync.respond_to?(:status_text)
      redbark_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )

      account_ids = linked_accounts.includes(:account_provider).filter_map { |la| la.current_account&.id }
      collect_transaction_stats(sync, account_ids: account_ids, source: "redbark")
    end

    # Surface importer failures so a sync isn't reported as completed when the
    # upstream API rejected fetches for some accounts (e.g. a 429 rate limit).
    collect_health_stats(sync, errors: import_failures_as_errors(import_result).presence)
  rescue => e
    collect_health_stats(sync, errors: [ { message: e.message, category: "sync_error" } ])
    raise
  end

  def perform_post_sync
    # no-op
  end

  private

    # Translates the RedbarkItem::Importer result hash into the error shape
    # collect_health_stats expects. Returns [] for a fully successful import.
    def import_failures_as_errors(import_result)
      return [] unless import_result.is_a?(Hash)
      return [] if import_result[:success]

      errors = []
      accounts_failed = import_result[:accounts_failed].to_i
      transactions_failed = import_result[:transactions_failed].to_i

      if accounts_failed.positive?
        errors << {
          message: I18n.t("provider_warnings.redbark_accounts_failed", count: accounts_failed),
          category: "redbark_import"
        }
      end
      if transactions_failed.positive?
        errors << {
          message: I18n.t("provider_warnings.redbark_transactions_failed", count: transactions_failed),
          category: "redbark_import"
        }
      end
      if errors.empty? && import_result[:error].present?
        errors << {
          message: I18n.t("provider_warnings.redbark_import_error", error: import_result[:error]),
          category: "redbark_import"
        }
      end
      errors
    end
end
