require "test_helper"

class Provider::RedbarkAdapterTest < ActiveSupport::TestCase
  test "supports the banking account types" do
    assert_equal %w[Depository CreditCard Loan], Provider::RedbarkAdapter.supported_account_types
  end

  test "registers with the provider factory" do
    assert Provider::Factory.registered?("RedbarkAccount")
  end

  test "connection_configs returns a redbark config when the family can connect" do
    configs = Provider::RedbarkAdapter.connection_configs(family: families(:dylan_family))

    assert_equal 1, configs.size
    assert_equal "redbark", configs.first[:key]
    assert_equal "Redbark", configs.first[:name]
    assert configs.first[:can_connect]
  end

  test "build_provider returns nil when no credentials are configured" do
    assert_nil Provider::RedbarkAdapter.build_provider(family: families(:empty))
  end
end
