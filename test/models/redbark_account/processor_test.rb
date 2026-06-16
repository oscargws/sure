require "test_helper"

class RedbarkAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @redbark_item = RedbarkItem.create!(name: "Test Redbark", api_key: "test_key", family: @family)
  end

  def linked_account(accountable_type:, redbark_balance:)
    redbark_account = RedbarkAccount.create!(
      redbark_item: @redbark_item,
      name: "Acct",
      currency: "AUD",
      account_id: "rb_#{accountable_type.downcase}",
      connection_id: "conn",
      current_balance: redbark_balance
    )
    accountable = accountable_type.constantize.new
    account = Account.create!(family: @family, name: "Acct", accountable: accountable, balance: 0, currency: "AUD")
    AccountProvider.create!(account: account, provider: redbark_account)
    [ redbark_account, account ]
  end

  test "depository balance passes through unchanged" do
    redbark_account, account = linked_account(accountable_type: "Depository", redbark_balance: 1000)

    RedbarkAccount::Processor.new(redbark_account.reload).process

    assert_equal BigDecimal("1000"), account.reload.cash_balance
  end

  test "credit card outstanding (negative CDR balance) is stored as a positive owed amount" do
    # CDR reports a card you owe $500 on as currentBalance = -500.
    redbark_account, account = linked_account(accountable_type: "CreditCard", redbark_balance: -500)

    RedbarkAccount::Processor.new(redbark_account.reload).process

    assert_equal BigDecimal("500"), account.reload.cash_balance
  end

  test "loan principal (negative CDR balance) is stored as a positive owed amount" do
    redbark_account, account = linked_account(accountable_type: "Loan", redbark_balance: -10_000)

    RedbarkAccount::Processor.new(redbark_account.reload).process

    assert_equal BigDecimal("10000"), account.reload.cash_balance
  end
end
