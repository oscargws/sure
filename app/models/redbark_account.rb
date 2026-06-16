class RedbarkAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :redbark_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, presence: true
  validates :account_id, uniqueness: { scope: :redbark_item_id, allow_nil: true }

  def current_account
    account
  end

  # Maps a normalized account from Provider::Redbark#get_accounts onto our columns.
  def upsert_redbark_snapshot!(account_snapshot)
    snapshot = account_snapshot.with_indifferent_access

    assign_attributes(
      current_balance: nil, # set later from the balances endpoint
      currency: parse_currency(snapshot[:currency]) || "AUD",
      name: snapshot[:name],
      account_id: snapshot[:id].to_s,
      connection_id: snapshot[:connection_id],
      account_status: snapshot[:status],
      account_type: snapshot[:type],
      provider: snapshot[:provider],
      institution_metadata: {
        name: snapshot[:institution_name],
        logo: snapshot[:institution_logo]
      }.compact,
      raw_payload: account_snapshot
    )

    save!
  end

  def upsert_redbark_transactions_snapshot!(transactions_snapshot)
    assign_attributes(
      raw_transactions_payload: transactions_snapshot
    )

    save!
  end

  private

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for Redbark account #{id}, defaulting to USD")
    end
end
