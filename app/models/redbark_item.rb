class RedbarkItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable

  DEFAULT_BASE_URL = "https://api.redbark.com".freeze

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  # Encrypt sensitive credentials and raw payloads if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :api_key, deterministic: true
    encrypts :raw_payload
    encrypts :raw_institution_payload
  end

  validates :name, presence: true
  validates :api_key, presence: true, on: :create

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later

  has_many :redbark_accounts, dependent: :destroy
  has_many :accounts, through: :redbark_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def import_latest_redbark_data
    provider = redbark_provider
    unless provider
      Rails.logger.error "RedbarkItem #{id} - Cannot import: Redbark provider is not configured (missing API key)"
      raise StandardError.new("Redbark provider is not configured")
    end

    RedbarkItem::Importer.new(self, redbark_provider: provider).import
  rescue => e
    Rails.logger.error "RedbarkItem #{id} - Failed to import data: #{e.message}"
    raise
  end

  def process_accounts
    return [] if redbark_accounts.empty?

    results = []
    # Only process accounts that are linked and have active status
    redbark_accounts.joins(:account).merge(Account.visible).each do |redbark_account|
      begin
        result = RedbarkAccount::Processor.new(redbark_account).process
        results << { redbark_account_id: redbark_account.id, success: true, result: result }
      rescue => e
        Rails.logger.error "RedbarkItem #{id} - Failed to process account #{redbark_account.id}: #{e.message}"
        results << { redbark_account_id: redbark_account.id, success: false, error: e.message }
        # Continue processing other accounts even if one fails
      end
    end

    results
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    return [] if accounts.empty?

    results = []
    # Only schedule syncs for active accounts
    accounts.visible.each do |account|
      begin
        account.sync_later(
          parent_sync: parent_sync,
          window_start_date: window_start_date,
          window_end_date: window_end_date
        )
        results << { account_id: account.id, success: true }
      rescue => e
        Rails.logger.error "RedbarkItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}"
        results << { account_id: account.id, success: false, error: e.message }
        # Continue scheduling other accounts even if one fails
      end
    end

    results
  end

  def upsert_redbark_snapshot!(accounts_snapshot)
    assign_attributes(
      raw_payload: accounts_snapshot
    )

    save!
  end

  def has_completed_initial_setup?
    # Setup is complete if we have any linked accounts
    accounts.any?
  end

  def sync_status_summary
    # Use centralized count helper methods for consistency
    total_accounts = total_accounts_count
    linked_count = linked_accounts_count
    unlinked_count = unlinked_accounts_count

    if total_accounts == 0
      "No accounts found"
    elsif unlinked_count == 0
      "#{linked_count} #{'account'.pluralize(linked_count)} synced"
    else
      "#{linked_count} synced, #{unlinked_count} need setup"
    end
  end

  def linked_accounts_count
    redbark_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    redbark_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    redbark_accounts.count
  end

  def institution_display_name
    # Try to get institution name from stored metadata
    institution_name.presence || institution_domain.presence || name
  end

  def connected_institutions
    # Get unique institutions from all accounts
    redbark_accounts.includes(:account)
                      .where.not(institution_metadata: nil)
                      .map { |acc| acc.institution_metadata }
                      .uniq { |inst| inst["name"] || inst["institution_name"] }
  end

  def institution_summary
    institutions = connected_institutions
    case institutions.count
    when 0
      "No institutions connected"
    when 1
      institutions.first["name"] || institutions.first["institution_name"] || "1 institution"
    else
      "#{institutions.count} institutions"
    end
  end

  def credentials_configured?
    api_key.present?
  end

  # Constrain the outbound base URL to the canonical Redbark host to prevent SSRF
  # via a user-supplied base_url. Anything that is not exactly the trusted endpoint
  # falls back to the safe default.
  def effective_base_url
    return DEFAULT_BASE_URL if base_url.blank?

    uri = URI.parse(base_url)
    return DEFAULT_BASE_URL unless uri.is_a?(URI::HTTPS)
    return DEFAULT_BASE_URL unless uri.host == "api.redbark.com"
    return DEFAULT_BASE_URL unless [ "", "/" ].include?(uri.path)
    return DEFAULT_BASE_URL unless uri.query.blank?
    return DEFAULT_BASE_URL unless uri.fragment.blank?

    DEFAULT_BASE_URL
  rescue URI::InvalidURIError
    DEFAULT_BASE_URL
  end
end
