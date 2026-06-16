require "test_helper"

class RedbarkEntry::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @redbark_item = RedbarkItem.create!(
      name: "Test Redbark Connection",
      api_key: "test_key",
      family: @family
    )
    @redbark_account = RedbarkAccount.create!(
      redbark_item: @redbark_item,
      name: "Test Account",
      currency: "AUD",
      account_id: "rb_acc_123",
      connection_id: "rb_conn_1"
    )

    @account = Account.create!(
      family: @family,
      name: "Test Checking",
      accountable: Depository.new(subtype: "checking"),
      balance: 1000,
      currency: "AUD"
    )

    AccountProvider.create!(account: @account, provider: @redbark_account)
    @redbark_account.reload
  end

  # Redbark transaction shape: { id, accountId, status, date, description, amount,
  #   direction, category, merchantName, merchantCategoryCode }
  def txn(overrides = {})
    {
      id: "bank_tx_abc",
      accountId: "rb_acc_123",
      status: "posted",
      date: "2026-06-15",
      description: "From PAYPAL AUSTRALIA",
      amount: "-78.38",
      direction: "debit",
      category: "SERVICES",
      merchantName: "PayPal",
      merchantCategoryCode: nil
    }.merge(overrides)
  end

  test "a debit is stored as a positive (expense) amount" do
    result = RedbarkEntry::Processor.new(txn, redbark_account: @redbark_account).process

    assert_not_nil result
    assert_equal BigDecimal("78.38"), result.amount
    assert_equal "redbark_bank_tx_abc", result.external_id
  end

  test "a credit is stored as a negative (income) amount" do
    result = RedbarkEntry::Processor.new(
      txn(id: "bank_tx_cr", amount: "100.00", direction: "credit", merchantName: nil, description: "Salary"),
      redbark_account: @redbark_account
    ).process

    assert_equal BigDecimal("-100.00"), result.amount
  end

  test "name uses merchantName and falls back to description" do
    with_merchant = RedbarkEntry::Processor.new(txn, redbark_account: @redbark_account).process
    assert_equal "PayPal", with_merchant.name

    without_merchant = RedbarkEntry::Processor.new(
      txn(id: "bank_tx_nodesc", merchantName: nil, description: "ATM WITHDRAWAL"),
      redbark_account: @redbark_account
    ).process
    assert_equal "ATM WITHDRAWAL", without_merchant.name
  end

  test "creates a merchant from merchantName" do
    result = RedbarkEntry::Processor.new(txn, redbark_account: @redbark_account).process

    assert_equal "PayPal", result.entryable.merchant&.name
  end

  test "stores the pending flag under the redbark extra key" do
    pending = RedbarkEntry::Processor.new(
      txn(id: "bank_tx_p", status: "pending"),
      redbark_account: @redbark_account
    ).process

    assert_equal true, pending.entryable.pending?
    assert_equal true, pending.entryable.extra.dig("redbark", "pending")

    posted = RedbarkEntry::Processor.new(
      txn(id: "bank_tx_q", status: "posted"),
      redbark_account: @redbark_account
    ).process

    assert_not posted.entryable.pending?
  end

  test "uses the linked account currency" do
    result = RedbarkEntry::Processor.new(txn, redbark_account: @redbark_account).process

    assert_equal "AUD", result.currency
  end

  test "re-syncing the same transaction does not create a duplicate" do
    first = RedbarkEntry::Processor.new(txn, redbark_account: @redbark_account).process
    count_before = @account.entries.where(source: "redbark").count

    second = RedbarkEntry::Processor.new(txn, redbark_account: @redbark_account).process

    assert_equal first.id, second.id
    assert_equal count_before, @account.entries.where(source: "redbark").count
  end

  test "skips a pending transaction when a posted version already exists" do
    posted = RedbarkEntry::Processor.new(
      txn(id: "bank_tx_posted", status: "posted", amount: "-12.50", merchantName: "Cafe", description: "Coffee"),
      redbark_account: @redbark_account
    ).process
    count_before = @account.entries.where(source: "redbark").count

    # Same transaction arrives later as a pending row with a different id, one day earlier.
    result = RedbarkEntry::Processor.new(
      txn(id: "bank_tx_pending", status: "pending", amount: "-12.50", date: "2026-06-14", merchantName: "Cafe", description: "Coffee"),
      redbark_account: @redbark_account
    ).process

    assert_equal posted.id, result.id, "should return the existing posted entry, not create a pending duplicate"
    assert_equal count_before, @account.entries.where(source: "redbark").count
  end

  test "still creates a pending entry when no posted version matches" do
    pending = RedbarkEntry::Processor.new(
      txn(id: "bank_tx_only_pending", status: "pending", amount: "-9.99", merchantName: "Newsagent"),
      redbark_account: @redbark_account
    ).process

    assert pending.entryable.pending?
    assert_equal "redbark_bank_tx_only_pending", pending.external_id
  end
end
