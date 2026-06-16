class RedbarkItemsController < ApplicationController
  before_action :set_redbark_item, only: [ :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]
  before_action :require_admin!, only: [ :create, :select_accounts, :link_accounts, :select_existing_account, :link_existing_account, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]

  def select_accounts
    begin
      unless Current.family.has_redbark_credentials?
        if turbo_frame_request?
          render partial: "redbark_items/setup_required", layout: false
        else
          redirect_to settings_providers_path,
                     alert: t(".no_credentials_configured",
                            default: "Please configure your Redbark API key first in Provider Settings.")
        end
        return
      end

      cache_key = "redbark_accounts_#{Current.family.id}"
      @available_accounts = Rails.cache.read(cache_key)

      if @available_accounts.nil?
        redbark_provider = Provider::RedbarkAdapter.build_provider(family: Current.family)

        unless redbark_provider.present?
          redirect_to settings_providers_path, alert: t(".no_api_key",
                                                        default: "Redbark API key not found. Please configure it in Provider Settings.")
          return
        end

        accounts_data = redbark_provider.get_accounts
        @available_accounts = accounts_data[:accounts] || []
        Rails.cache.write(cache_key, @available_accounts, expires_in: 5.minutes)
      end

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
      Rails.logger.error("Redbark API error in select_accounts: #{e.message}")
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

  def link_accounts
    selected_account_ids = params[:account_ids] || []
    accountable_type = params[:accountable_type] || "Depository"
    return_to = safe_return_to_path

    if selected_account_ids.empty?
      redirect_to new_account_path, alert: t(".no_accounts_selected")
      return
    end

    redbark_item = Current.family.redbark_items.first_or_create!(name: "Redbark Connection")

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
      account_data = accounts_data[:accounts].find { |acc| acc[:id].to_s == account_id.to_s }
      next unless account_data

      if account_data[:name].blank?
        invalid_accounts << account_id
        Rails.logger.warn "RedbarkItemsController - Skipping account #{account_id} with blank name"
        next
      end

      redbark_account = redbark_item.redbark_accounts.find_or_initialize_by(account_id: account_id.to_s)
      redbark_account.upsert_redbark_snapshot!(account_data)
      redbark_account.save!

      if redbark_account.account_provider.present?
        already_linked_accounts << account_data[:name]
        next
      end

      # Balance and currency are set by the provider sync, so skip the initial sync here.
      account = Account.create_and_sync(
        {
          family: Current.family,
          name: account_data[:name],
          balance: 0,
          currency: redbark_account.currency || "AUD",
          accountable_type: accountable_type,
          accountable_attributes: {}
        },
        skip_initial_sync: true
      )

      AccountProvider.create!(account: account, provider: redbark_account)

      created_accounts << account
    end

    redbark_item.sync_later if created_accounts.any?

    if invalid_accounts.any? && created_accounts.empty? && already_linked_accounts.empty?
      redirect_to new_account_path, alert: t(".invalid_account_names", count: invalid_accounts.count)
    elsif invalid_accounts.any? && (created_accounts.any? || already_linked_accounts.any?)
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

  def select_existing_account
    account_id = params[:account_id]

    unless account_id.present?
      redirect_to accounts_path, alert: t(".no_account_specified")
      return
    end

    @account = Current.family.accounts.find(account_id)

    if @account.account_providers.exists?
      redirect_to accounts_path, alert: t(".account_already_linked")
      return
    end

    unless Current.family.has_redbark_credentials?
      if turbo_frame_request?
        render partial: "redbark_items/setup_required", layout: false
      else
        redirect_to settings_providers_path,
                   alert: t(".no_credentials_configured",
                          default: "Please configure your Redbark API key first in Provider Settings.")
      end
      return
    end

    begin
      cache_key = "redbark_accounts_#{Current.family.id}"
      @available_accounts = Rails.cache.read(cache_key)

      if @available_accounts.nil?
        redbark_provider = Provider::RedbarkAdapter.build_provider(family: Current.family)

        unless redbark_provider.present?
          redirect_to settings_providers_path, alert: t(".no_api_key",
                                                        default: "Redbark API key not found. Please configure it in Provider Settings.")
          return
        end

        accounts_data = redbark_provider.get_accounts
        @available_accounts = accounts_data[:accounts] || []
        Rails.cache.write(cache_key, @available_accounts, expires_in: 5.minutes)
      end

      if @available_accounts.empty?
        redirect_to accounts_path, alert: t(".no_accounts_found")
        return
      end

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
      Rails.logger.error("Redbark API error in select_existing_account: #{e.message}")
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

  def link_existing_account
    account_id = params[:account_id]
    redbark_account_id = params[:redbark_account_id]
    return_to = safe_return_to_path

    unless account_id.present? && redbark_account_id.present?
      redirect_to accounts_path, alert: t(".missing_parameters")
      return
    end

    @account = Current.family.accounts.find(account_id)

    if @account.account_providers.exists?
      redirect_to accounts_path, alert: t(".account_already_linked")
      return
    end

    redbark_item = Current.family.redbark_items.first_or_create!(name: "Redbark Connection")

    redbark_provider = Provider::RedbarkAdapter.build_provider(family: Current.family)
    unless redbark_provider.present?
      redirect_to accounts_path, alert: t(".no_api_key")
      return
    end

    accounts_data = redbark_provider.get_accounts

    account_data = accounts_data[:accounts].find { |acc| acc[:id].to_s == redbark_account_id.to_s }
    unless account_data
      redirect_to accounts_path, alert: t(".redbark_account_not_found")
      return
    end

    if account_data[:name].blank?
      redirect_to accounts_path, alert: t(".invalid_account_name")
      return
    end

    redbark_account = redbark_item.redbark_accounts.find_or_initialize_by(account_id: redbark_account_id.to_s)
    redbark_account.upsert_redbark_snapshot!(account_data)
    redbark_account.save!

    if redbark_account.account_provider.present?
      redirect_to accounts_path, alert: t(".redbark_account_already_linked")
      return
    end

    AccountProvider.create!(account: @account, provider: redbark_account)

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
    # Detach provider links before scheduling deletion so holdings/entries are released.
    begin
      @redbark_item.unlink_all!(dry_run: false)
    rescue => e
      Rails.logger.warn("Redbark unlink during destroy failed: #{e.class} - #{e.message}")
    end
    @redbark_item.destroy_later
    redirect_to accounts_path, notice: t(".success")
  end

  def sync
    @redbark_item.sync_later unless @redbark_item.syncing?

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  def setup_accounts
    @api_error = fetch_redbark_accounts_from_api

    @redbark_accounts = @redbark_item.redbark_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })

    supported_types = Provider::RedbarkAdapter.supported_account_types

    account_type_keys = {
      "depository" => "Depository",
      "credit_card" => "CreditCard",
      "investment" => "Investment",
      "loan" => "Loan",
      "other_asset" => "OtherAsset"
    }

    all_account_type_options = account_type_keys.filter_map do |key, type|
      next unless supported_types.include?(type)
      [ t(".account_types.#{key}"), type ]
    end

    @account_type_options = [ [ t(".account_types.skip"), "skip" ] ] + all_account_type_options

    translate_subtypes = ->(type_key, subtypes_hash) {
      subtypes_hash.map { |k, v| [ t(".subtypes.#{type_key}.#{k}", default: v[:long] || k.humanize), k ] }
    }

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

    valid_types = Provider::RedbarkAdapter.supported_account_types

    created_accounts = []
    skipped_count = 0

    begin
      ActiveRecord::Base.transaction do
        account_types.each do |redbark_account_id, selected_type|
          if selected_type == "skip" || selected_type.blank?
            skipped_count += 1
            next
          end

          unless valid_types.include?(selected_type)
            Rails.logger.warn("Invalid account type '#{selected_type}' submitted for Redbark account #{redbark_account_id}")
            next
          end

          # Scoped to this item to prevent cross-item manipulation.
          redbark_account = @redbark_item.redbark_accounts.find_by(id: redbark_account_id)
          unless redbark_account
            Rails.logger.warn("Redbark account #{redbark_account_id} not found for item #{@redbark_item.id}")
            next
          end

          if redbark_account.account_provider.present?
            Rails.logger.info("Redbark account #{redbark_account_id} already linked, skipping")
            next
          end

          selected_subtype = account_subtypes[redbark_account_id]
          # CreditCard has a single subtype, so default it when none was submitted.
          selected_subtype = "credit_card" if selected_type == "CreditCard" && selected_subtype.blank?

          # Balance/currency are set by the provider sync, so skip the initial sync.
          account = Account.create_and_sync(
            {
              family: Current.family,
              name: redbark_account.name,
              balance: redbark_account.current_balance || 0,
              currency: redbark_account.currency || "AUD",
              accountable_type: selected_type,
              accountable_attributes: selected_subtype.present? ? { subtype: selected_subtype } : {}
            },
            skip_initial_sync: true
          )

          AccountProvider.create!(account: account, provider: redbark_account)

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

    @redbark_item.sync_later if created_accounts.any?

    if created_accounts.any?
      flash[:notice] = t(".success", count: created_accounts.count)
    elsif skipped_count > 0
      flash[:notice] = t(".all_skipped")
    else
      flash[:notice] = t(".no_accounts")
    end

    if turbo_frame_request?
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

    # Fetches accounts from the API into local records. Returns nil on success,
    # or a user-facing error message string on failure.
    def fetch_redbark_accounts_from_api
      return nil unless @redbark_item.redbark_accounts.empty?

      unless @redbark_item.credentials_configured?
        return t("redbark_items.setup_accounts.no_api_key")
      end

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

          redbark_account = @redbark_item.redbark_accounts.find_or_initialize_by(account_id: account_data[:id].to_s)
          redbark_account.upsert_redbark_snapshot!(account_data)
          redbark_account.save!
        end

        nil
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

    # Reject external URLs and javascript: URIs so return_to can only be an internal path.
    def safe_return_to_path
      return nil if params[:return_to].blank?

      return_to = params[:return_to].to_s

      begin
        uri = URI.parse(return_to)
        return nil if uri.scheme.present?
        return nil unless return_to.start_with?("/")

        return_to
      rescue URI::InvalidURIError
        nil
      end
    end
end
