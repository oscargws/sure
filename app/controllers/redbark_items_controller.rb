class RedbarkItemsController < ApplicationController
  before_action :set_redbark_item, only: [ :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]
  before_action :require_admin!, only: [ :create, :select_accounts, :link_accounts, :select_existing_account, :link_existing_account, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]

  # Fetch available accounts from Redbark API and show selection UI
  def select_accounts
    begin
      # Check if family has Redbark credentials configured
      unless Current.family.has_redbark_credentials?
        if turbo_frame_request?
          # Render setup modal for turbo frame requests
          render partial: "redbark_items/setup_required", layout: false
        else
          # Redirect for regular requests
          redirect_to settings_providers_path,
                     alert: t(".no_credentials_configured",
                            default: "Please configure your Redbark API key first in Provider Settings.")
        end
        return
      end

      cache_key = "redbark_accounts_#{Current.family.id}"

      # Try to get cached accounts first
      @available_accounts = Rails.cache.read(cache_key)

      # If not cached, fetch from API
      if @available_accounts.nil?
        redbark_provider = Provider::RedbarkAdapter.build_provider(family: Current.family)

        unless redbark_provider.present?
          redirect_to settings_providers_path, alert: t(".no_api_key",
                                                        default: "Redbark API key not found. Please configure it in Provider Settings.")
          return
        end

        accounts_data = redbark_provider.get_accounts

        @available_accounts = accounts_data[:accounts] || []

        # Cache the accounts for 5 minutes
        Rails.cache.write(cache_key, @available_accounts, expires_in: 5.minutes)
      end

      # Filter out already linked accounts
      redbark_item = Current.family.redbark_items.first
      if redbark_item
        linked_account_ids = redbark_item.redbark_accounts.joins(:account_provider).pluck(:account_id)
        @available_accounts = @available_accounts.reject { |acc| linked_account_ids.include?(acc[:id].to_s) }
      end

      @accountable_type = params[:accountable_type] || "Depository"
      @return_to = safe_return_to_path

      if @available_accounts.empty?
        redirect_to new_account_path, alert: t(".no_accounts_found")
        return
      end

      render layout: false
    rescue Provider::Redbark::RedbarkError => e
      Rails.logger.error("Lunch flow API error in select_accounts: #{e.message}")
      @error_message = e.message
      @return_path = safe_return_to_path
      render partial: "redbark_items/api_error",
             locals: { error_message: @error_message, return_path: @return_path },
             layout: false
    rescue StandardError => e
      Rails.logger.error("Unexpected error in select_accounts: #{e.class}: #{e.message}")
      @error_message = "An unexpected error occurred. Please try again later."
      @return_path = safe_return_to_path
      render partial: "redbark_items/api_error",
             locals: { error_message: @error_message, return_path: @return_path },
             layout: false
    end
  end

  # Create accounts from selected Redbark accounts
  def link_accounts
    selected_account_ids = params[:account_ids] || []
    accountable_type = params[:accountable_type] || "Depository"
    return_to = safe_return_to_path

    if selected_account_ids.empty?
      redirect_to new_account_path, alert: t(".no_accounts_selected")
      return
    end

    # Create or find redbark_item for this family
    redbark_item = Current.family.redbark_items.first_or_create!(
      name: "Redbark Connection"
    )

    # Fetch account details from API
    redbark_provider = Provider::RedbarkAdapter.build_provider(family: Current.family)
    unless redbark_provider.present?
      redirect_to new_account_path, alert: t(".no_api_key")
      return
    end

    accounts_data = redbark_provider.get_accounts

    created_accounts = []
    already_linked_accounts = []
    invalid_accounts = []

    selected_account_ids.each do |account_id|
      # Find the account data from API response
      account_data = accounts_data[:accounts].find { |acc| acc[:id].to_s == account_id.to_s }
      next unless account_data

      # Validate account name is not blank (required by Account model)
      if account_data[:name].blank?
        invalid_accounts << account_id
        Rails.logger.warn "RedbarkItemsController - Skipping account #{account_id} with blank name"
        next
      end

      # Create or find redbark_account
      redbark_account = redbark_item.redbark_accounts.find_or_initialize_by(
        account_id: account_id.to_s
      )
      redbark_account.upsert_redbark_snapshot!(account_data)
      redbark_account.save!

      # Check if this redbark_account is already linked
      if redbark_account.account_provider.present?
        already_linked_accounts << account_data[:name]
        next
      end

      # Create the internal Account with proper balance initialization
      # Use redbark_account.currency (already parsed) and skip initial sync
      # because the provider sync will set the correct currency from the balance API
      account = Account.create_and_sync(
        {
          family: Current.family,
          name: account_data[:name],
          balance: 0, # Initial balance will be set during sync
          currency: redbark_account.currency || "USD",
          accountable_type: accountable_type,
          accountable_attributes: {}
        },
        skip_initial_sync: true
      )

      # Link account to redbark_account via account_providers join table
      AccountProvider.create!(
        account: account,
        provider: redbark_account
      )

      created_accounts << account
    end

    # Trigger sync to fetch transactions if any accounts were created
    redbark_item.sync_later if created_accounts.any?

    # Build appropriate flash message
    if invalid_accounts.any? && created_accounts.empty? && already_linked_accounts.empty?
      # All selected accounts were invalid (blank names)
      redirect_to new_account_path, alert: t(".invalid_account_names", count: invalid_accounts.count)
    elsif invalid_accounts.any? && (created_accounts.any? || already_linked_accounts.any?)
      # Some accounts were created/already linked, but some had invalid names
      redirect_to return_to || accounts_path,
                  alert: t(".partial_invalid",
                           created_count: created_accounts.count,
                           already_linked_count: already_linked_accounts.count,
                           invalid_count: invalid_accounts.count)
    elsif created_accounts.any? && already_linked_accounts.any?
      redirect_to return_to || accounts_path,
                  notice: t(".partial_success",
                           created_count: created_accounts.count,
                           already_linked_count: already_linked_accounts.count,
                           already_linked_names: already_linked_accounts.join(", "))
    elsif created_accounts.any?
      redirect_to return_to || accounts_path,
                  notice: t(".success", count: created_accounts.count)
    elsif already_linked_accounts.any?
      redirect_to return_to || accounts_path,
                  alert: t(".all_already_linked",
                          count: already_linked_accounts.count,
                          names: already_linked_accounts.join(", "))
    else
      redirect_to new_account_path, alert: t(".link_failed")
    end
  rescue Provider::Redbark::RedbarkError => e
    redirect_to new_account_path, alert: t(".api_error", message: e.message)
  end

  # Fetch available Redbark accounts to link with an existing account
  def select_existing_account
    account_id = params[:account_id]

    unless account_id.present?
      redirect_to accounts_path, alert: t(".no_account_specified")
      return
    end

    @account = Current.family.accounts.find(account_id)

    # Check if account is already linked
    if @account.account_providers.exists?
      redirect_to accounts_path, alert: t(".account_already_linked")
      return
    end

    # Check if family has Redbark credentials configured
    unless Current.family.has_redbark_credentials?
      if turbo_frame_request?
        # Render setup modal for turbo frame requests
        render partial: "redbark_items/setup_required", layout: false
      else
        # Redirect for regular requests
        redirect_to settings_providers_path,
                   alert: t(".no_credentials_configured",
                          default: "Please configure your Redbark API key first in Provider Settings.")
      end
      return
    end

    begin
      cache_key = "redbark_accounts_#{Current.family.id}"

      # Try to get cached accounts first
      @available_accounts = Rails.cache.read(cache_key)

      # If not cached, fetch from API
      if @available_accounts.nil?
        redbark_provider = Provider::RedbarkAdapter.build_provider(family: Current.family)

        unless redbark_provider.present?
          redirect_to settings_providers_path, alert: t(".no_api_key",
                                                        default: "Redbark API key not found. Please configure it in Provider Settings.")
          return
        end

        accounts_data = redbark_provider.get_accounts

        @available_accounts = accounts_data[:accounts] || []

        # Cache the accounts for 5 minutes
        Rails.cache.write(cache_key, @available_accounts, expires_in: 5.minutes)
      end

      if @available_accounts.empty?
        redirect_to accounts_path, alert: t(".no_accounts_found")
        return
      end

      # Filter out already linked accounts
      redbark_item = Current.family.redbark_items.first
      if redbark_item
        linked_account_ids = redbark_item.redbark_accounts.joins(:account_provider).pluck(:account_id)
        @available_accounts = @available_accounts.reject { |acc| linked_account_ids.include?(acc[:id].to_s) }
      end

      if @available_accounts.empty?
        redirect_to accounts_path, alert: t(".all_accounts_already_linked")
        return
      end

      @return_to = safe_return_to_path

      render layout: false
    rescue Provider::Redbark::RedbarkError => e
      Rails.logger.error("Lunch flow API error in select_existing_account: #{e.message}")
      @error_message = e.message
      render partial: "redbark_items/api_error",
             locals: { error_message: @error_message, return_path: accounts_path },
             layout: false
    rescue StandardError => e
      Rails.logger.error("Unexpected error in select_existing_account: #{e.class}: #{e.message}")
      @error_message = "An unexpected error occurred. Please try again later."
      render partial: "redbark_items/api_error",
             locals: { error_message: @error_message, return_path: accounts_path },
             layout: false
    end
  end

  # Link a selected Redbark account to an existing account
  def link_existing_account
    account_id = params[:account_id]
    redbark_account_id = params[:redbark_account_id]
    return_to = safe_return_to_path

    unless account_id.present? && redbark_account_id.present?
      redirect_to accounts_path, alert: t(".missing_parameters")
      return
    end

    @account = Current.family.accounts.find(account_id)

    # Check if account is already linked
    if @account.account_providers.exists?
      redirect_to accounts_path, alert: t(".account_already_linked")
      return
    end

    # Create or find redbark_item for this family
    redbark_item = Current.family.redbark_items.first_or_create!(
      name: "Redbark Connection"
    )

    # Fetch account details from API
    redbark_provider = Provider::RedbarkAdapter.build_provider(family: Current.family)
    unless redbark_provider.present?
      redirect_to accounts_path, alert: t(".no_api_key")
      return
    end

    accounts_data = redbark_provider.get_accounts

    # Find the selected Redbark account data
    account_data = accounts_data[:accounts].find { |acc| acc[:id].to_s == redbark_account_id.to_s }
    unless account_data
      redirect_to accounts_path, alert: t(".redbark_account_not_found")
      return
    end

    # Validate account name is not blank (required by Account model)
    if account_data[:name].blank?
      redirect_to accounts_path, alert: t(".invalid_account_name")
      return
    end

    # Create or find redbark_account
    redbark_account = redbark_item.redbark_accounts.find_or_initialize_by(
      account_id: redbark_account_id.to_s
    )
    redbark_account.upsert_redbark_snapshot!(account_data)
    redbark_account.save!

    # Check if this redbark_account is already linked to another account
    if redbark_account.account_provider.present?
      redirect_to accounts_path, alert: t(".redbark_account_already_linked")
      return
    end

    # Link account to redbark_account via account_providers join table
    AccountProvider.create!(
      account: @account,
      provider: redbark_account
    )

    # Trigger sync to fetch transactions
    redbark_item.sync_later

    redirect_to return_to || accounts_path,
                notice: t(".success", account_name: @account.name)
  rescue Provider::Redbark::RedbarkError => e
    redirect_to accounts_path, alert: t(".api_error", message: e.message)
  end

  def create
    @redbark_item = Current.family.redbark_items.build(redbark_params)
    @redbark_item.name ||= "Redbark Connection"

    if @redbark_item.save
      # Trigger initial sync to fetch accounts
      @redbark_item.sync_later

      if turbo_frame_request?
        flash.now[:notice] = t(".success")
        @redbark_items = Current.family.redbark_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "redbark-providers-panel",
            partial: "settings/providers/redbark_panel",
            locals: { redbark_items: @redbark_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to accounts_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @redbark_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "redbark-providers-panel",
          partial: "settings/providers/redbark_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :see_other
      end
    end
  end

  def update
    if @redbark_item.update(redbark_params)
      if turbo_frame_request?
        flash.now[:notice] = t(".success")
        @redbark_items = Current.family.redbark_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "redbark-providers-panel",
            partial: "settings/providers/redbark_panel",
            locals: { redbark_items: @redbark_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to accounts_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @redbark_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "redbark-providers-panel",
          partial: "settings/providers/redbark_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :see_other
      end
    end
  end

  def destroy
    # Ensure we detach provider links before scheduling deletion
    begin
      @redbark_item.unlink_all!(dry_run: false)
    rescue => e
      Rails.logger.warn("Redbark unlink during destroy failed: #{e.class} - #{e.message}")
    end
    @redbark_item.destroy_later
    redirect_to accounts_path, notice: t(".success")
  end

  def sync
    unless @redbark_item.syncing?
      @redbark_item.sync_later
    end

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  # Show unlinked Redbark accounts for setup (similar to SimpleFIN setup_accounts)
  def setup_accounts
    # First, ensure we have the latest accounts from the API
    @api_error = fetch_redbark_accounts_from_api

    # Get Redbark accounts that are not linked (no AccountProvider)
    @redbark_accounts = @redbark_item.redbark_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })

    # Get supported account types from the adapter
    supported_types = Provider::RedbarkAdapter.supported_account_types

    # Map of account type keys to their internal values
    account_type_keys = {
      "depository" => "Depository",
      "credit_card" => "CreditCard",
      "investment" => "Investment",
      "loan" => "Loan",
      "other_asset" => "OtherAsset"
    }

    # Build account type options using i18n, filtering to supported types
    all_account_type_options = account_type_keys.filter_map do |key, type|
      next unless supported_types.include?(type)
      [ t(".account_types.#{key}"), type ]
    end

    # Add "Skip" option at the beginning
    @account_type_options = [ [ t(".account_types.skip"), "skip" ] ] + all_account_type_options

    # Helper to translate subtype options
    translate_subtypes = ->(type_key, subtypes_hash) {
      subtypes_hash.map { |k, v| [ t(".subtypes.#{type_key}.#{k}", default: v[:long] || k.humanize), k ] }
    }

    # Subtype options for each account type (only include supported types)
    all_subtype_options = {
      "Depository" => {
        label: t(".subtype_labels.depository"),
        options: translate_subtypes.call("depository", Depository::SUBTYPES)
      },
      "CreditCard" => {
        label: t(".subtype_labels.credit_card"),
        options: [],
        message: t(".subtype_messages.credit_card")
      },
      "Investment" => {
        label: t(".subtype_labels.investment"),
        options: translate_subtypes.call("investment", Investment::SUBTYPES)
      },
      "Loan" => {
        label: t(".subtype_labels.loan"),
        options: translate_subtypes.call("loan", Loan::SUBTYPES)
      },
      "OtherAsset" => {
        label: t(".subtype_labels.other_asset").presence,
        options: [],
        message: t(".subtype_messages.other_asset")
      }
    }

    @subtype_options = all_subtype_options.slice(*supported_types)
  end

  def complete_account_setup
    account_types = params[:account_types] || {}
    account_subtypes = params[:account_subtypes] || {}

    # Valid account types for this provider
    valid_types = Provider::RedbarkAdapter.supported_account_types

    created_accounts = []
    skipped_count = 0

    begin
      ActiveRecord::Base.transaction do
        account_types.each do |redbark_account_id, selected_type|
          # Skip accounts marked as "skip"
          if selected_type == "skip" || selected_type.blank?
            skipped_count += 1
            next
          end

          # Validate account type is supported
          unless valid_types.include?(selected_type)
            Rails.logger.warn("Invalid account type '#{selected_type}' submitted for Redbark account #{redbark_account_id}")
            next
          end

          # Find account - scoped to this item to prevent cross-item manipulation
          redbark_account = @redbark_item.redbark_accounts.find_by(id: redbark_account_id)
          unless redbark_account
            Rails.logger.warn("Redbark account #{redbark_account_id} not found for item #{@redbark_item.id}")
            next
          end

          # Skip if already linked (race condition protection)
          if redbark_account.account_provider.present?
            Rails.logger.info("Redbark account #{redbark_account_id} already linked, skipping")
            next
          end

          selected_subtype = account_subtypes[redbark_account_id]

          # Default subtype for CreditCard since it only has one option
          selected_subtype = "credit_card" if selected_type == "CreditCard" && selected_subtype.blank?

          # Create account with user-selected type and subtype (raises on failure)
          # Skip initial sync - provider sync will handle balance creation with correct currency
          account = Account.create_and_sync(
            {
              family: Current.family,
              name: redbark_account.name,
              balance: redbark_account.current_balance || 0,
              currency: redbark_account.currency || "USD",
              accountable_type: selected_type,
              accountable_attributes: selected_subtype.present? ? { subtype: selected_subtype } : {}
            },
            skip_initial_sync: true
          )

          # Link account to redbark_account via account_providers join table (raises on failure)
          AccountProvider.create!(
            account: account,
            provider: redbark_account
          )

          created_accounts << account
        end
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
      Rails.logger.error("Redbark account setup failed: #{e.class} - #{e.message}")
      Rails.logger.error(e.backtrace.first(10).join("\n"))
      flash[:alert] = t(".creation_failed", error: e.message)
      redirect_to accounts_path, status: :see_other
      return
    rescue StandardError => e
      Rails.logger.error("Redbark account setup failed unexpectedly: #{e.class} - #{e.message}")
      Rails.logger.error(e.backtrace.first(10).join("\n"))
      flash[:alert] = t(".creation_failed", error: "An unexpected error occurred")
      redirect_to accounts_path, status: :see_other
      return
    end

    # Trigger a sync to process transactions
    @redbark_item.sync_later if created_accounts.any?

    # Set appropriate flash message
    if created_accounts.any?
      flash[:notice] = t(".success", count: created_accounts.count)
    elsif skipped_count > 0
      flash[:notice] = t(".all_skipped")
    else
      flash[:notice] = t(".no_accounts")
    end

    if turbo_frame_request?
      # Recompute data needed by Accounts#index partials
      @manual_accounts = Account.uncached {
        Current.family.accounts
          .visible_manual
          .order(:name)
          .to_a
      }
      @redbark_items = Current.family.redbark_items.ordered

      manual_accounts_stream = if @manual_accounts.any?
        turbo_stream.update(
          "manual-accounts",
          partial: "accounts/index/manual_accounts",
          locals: { accounts: @manual_accounts }
        )
      else
        turbo_stream.replace("manual-accounts", view_context.tag.div(id: "manual-accounts"))
      end

      render turbo_stream: [
        manual_accounts_stream,
        turbo_stream.replace(
          ActionView::RecordIdentifier.dom_id(@redbark_item),
          partial: "redbark_items/redbark_item",
          locals: { redbark_item: @redbark_item }
        )
      ] + Array(flash_notification_stream_items)
    else
      redirect_to accounts_path, status: :see_other
    end
  end

  private

    # Fetch Redbark accounts from the API and store them locally
    # Returns nil on success, or an error message string on failure
    def fetch_redbark_accounts_from_api
      # Skip if we already have accounts cached
      return nil unless @redbark_item.redbark_accounts.empty?

      # Validate API key is configured
      unless @redbark_item.credentials_configured?
        return t("redbark_items.setup_accounts.no_api_key")
      end

      # Use the specific redbark_item's provider (scoped to this family's item)
      redbark_provider = @redbark_item.redbark_provider
      unless redbark_provider.present?
        return t("redbark_items.setup_accounts.no_api_key")
      end

      begin
        accounts_data = redbark_provider.get_accounts
        available_accounts = accounts_data[:accounts] || []

        if available_accounts.empty?
          Rails.logger.info("Redbark API returned no accounts for item #{@redbark_item.id}")
          return nil
        end

        available_accounts.each do |account_data|
          next if account_data[:name].blank?

          redbark_account = @redbark_item.redbark_accounts.find_or_initialize_by(
            account_id: account_data[:id].to_s
          )
          redbark_account.upsert_redbark_snapshot!(account_data)
          redbark_account.save!
        end

        nil # Success
      rescue Provider::Redbark::RedbarkError => e
        Rails.logger.error("Redbark API error: #{e.message}")
        t("redbark_items.setup_accounts.api_error", message: e.message)
      rescue StandardError => e
        Rails.logger.error("Unexpected error fetching Redbark accounts: #{e.class}: #{e.message}")
        t("redbark_items.setup_accounts.api_error", message: e.message)
      end
    end
    def set_redbark_item
      @redbark_item = Current.family.redbark_items.find(params[:id])
    end

    def redbark_params
      params.require(:redbark_item).permit(:name, :sync_start_date, :api_key, :base_url)
    end

    # Sanitize return_to parameter to prevent XSS attacks
    # Only allow internal paths, reject external URLs and javascript: URIs
    def safe_return_to_path
      return nil if params[:return_to].blank?

      return_to = params[:return_to].to_s

      # Parse the URL to check if it's external
      begin
        uri = URI.parse(return_to)

        # Reject absolute URLs with schemes (http:, https:, javascript:, etc.)
        # Only allow relative paths
        return nil if uri.scheme.present?

        # Ensure the path starts with / (is a relative path)
        return nil unless return_to.start_with?("/")

        return_to
      rescue URI::InvalidURIError
        # If the URI is invalid, reject it
        nil
      end
    end
end
