require "test_helper"

class RedbarkItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = RedbarkItem.create!(family: @family, name: "Test Redbark", api_key: "test_key_123", status: :good)
    @importer = RedbarkItem::Importer.new(@item, redbark_provider: mock())
  end

  test "prunes an orphaned unlinked account no longer returned upstream" do
    orphan = @item.redbark_accounts.create!(account_id: "acct-old", name: "Deleted Account", currency: "AUD")

    pruned = @importer.send(:prune_orphaned_redbark_accounts, [ "acct-new" ])

    assert_equal 1, pruned
    assert_nil RedbarkAccount.find_by(id: orphan.id)
  end

  test "keeps an account that is still returned upstream" do
    kept = @item.redbark_accounts.create!(account_id: "acct-1", name: "Still Here", currency: "AUD")

    pruned = @importer.send(:prune_orphaned_redbark_accounts, [ "acct-1" ])

    assert_equal 0, pruned
    assert RedbarkAccount.exists?(kept.id)
  end

  test "keeps an orphaned account that is still linked to an Account" do
    linked = @item.redbark_accounts.create!(account_id: "acct-old", name: "Linked", currency: "AUD")
    account = Account.create!(family: @family, name: "Linked", accountable: Depository.new, balance: 0, currency: "AUD")
    AccountProvider.create!(account: account, provider: linked)

    pruned = @importer.send(:prune_orphaned_redbark_accounts, [ "acct-new" ])

    assert_equal 0, pruned
    assert RedbarkAccount.exists?(linked.id)
  end

  test "never prunes when the upstream list is empty (transient failure guard)" do
    @item.redbark_accounts.create!(account_id: "acct-old", name: "Deleted", currency: "AUD")

    assert_equal 0, @importer.send(:prune_orphaned_redbark_accounts, [])
    assert_equal 1, @item.redbark_accounts.count
  end
end
