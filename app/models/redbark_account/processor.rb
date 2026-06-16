class RedbarkAccount::Processor
  include CurrencyNormalizable

  attr_reader :redbark_account

  def initialize(redbark_account)
    @redbark_account = redbark_account
  end

  def process
    unless redbark_account.current_account.present?
      Rails.logger.info "RedbarkAccount::Processor - No linked account for redbark_account #{redbark_account.id}, skipping processing"
      return
    end

    Rails.logger.info "RedbarkAccount::Processor - Processing redbark_account #{redbark_account.id} (account #{redbark_account.account_id})"

    begin
      process_account!
    rescue StandardError => e
      Rails.logger.error "RedbarkAccount::Processor - Failed to process account #{redbark_account.id}: #{e.message}"
      Rails.logger.error "Backtrace: #{e.backtrace.join("\n")}"
      report_exception(e, "account")
      raise
    end

    process_transactions
  end

  private

    def process_account!
      account = redbark_account.current_account
      return if account.blank?

      balance = redbark_account.current_balance || 0

      # CDR reports liabilities (credit cards, loans) as a negative currentBalance
      # (funds owed); Sure shows the outstanding amount as a positive balance, so
      # we negate for those types. Matches Plaid's liability handling.
      balance = -balance if account.accountable_type.in?(%w[CreditCard Loan])

      currency = parse_currency(redbark_account.currency) || account.currency || "AUD"

      ActiveRecord::Base.transaction do
        account.update!(currency: currency, cash_balance: balance)

        # Anchor the bank-reported balance via set_current_balance so
        # Balance::ReverseCalculator works backward from it, avoiding the
        # spurious cash-adjustment spikes a direct balance write can cause.
        result = account.set_current_balance(balance)
        raise "Failed to set current balance: #{result.error}" unless result.success?
      end
    end

    def process_transactions
      RedbarkAccount::Transactions::Processor.new(redbark_account).process
    rescue => e
      report_exception(e, "transactions")
    end

    def report_exception(error, context)
      Sentry.capture_exception(error) do |scope|
        scope.set_tags(
          redbark_account_id: redbark_account.id,
          context: context
        )
      end
    end
end
