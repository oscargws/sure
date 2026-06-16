require "test_helper"

class Provider::RedbarkTest < ActiveSupport::TestCase
  setup do
    @client = Provider::Redbark.new("test_key")
  end

  test "get_accounts returns only banking-category accounts, merged with connection metadata" do
    stub_request(:get, "https://api.redbark.com/v1/connections").to_return(
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: {
        data: [
          { id: "conn-bank", category: "banking", status: "active", institutionName: "Macquarie", institutionLogo: "logo.png" },
          { id: "conn-broker", category: "brokerage", status: "active", institutionName: "Stake" }
        ]
      }.to_json
    )

    stub_request(:get, "https://api.redbark.com/v1/accounts").with(query: { limit: "200", offset: "0" }).to_return(
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: {
        data: [
          { id: "acc-bank", connectionId: "conn-bank", provider: "fiskil", name: "Everyday", type: "transaction", currency: "AUD", accountNumber: "xxxx1" },
          { id: "acc-broker", connectionId: "conn-broker", provider: "snaptrade", name: "Brokerage", type: "other", currency: "USD" }
        ],
        pagination: { hasMore: false }
      }.to_json
    )

    result = @client.get_accounts

    assert_equal 1, result[:accounts].size
    acc = result[:accounts].first
    assert_equal "acc-bank", acc[:id]
    assert_equal "conn-bank", acc[:connection_id]
    assert_equal "Macquarie", acc[:institution_name]
    assert_equal "logo.png", acc[:institution_logo]
  end

  test "get_account_transactions threads the connection id and returns the rows" do
    stub_request(:get, "https://api.redbark.com/v1/transactions")
      .with(query: { connectionId: "conn-bank", accountId: "acc-bank", from: "2026-01-01", limit: "200", offset: "0" })
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          data: [ { id: "bank_tx_1", amount: "-10.00", direction: "debit", status: "posted", date: "2026-03-01" } ],
          pagination: { hasMore: false }
        }.to_json
      )

    result = @client.get_account_transactions("acc-bank", connection_id: "conn-bank", start_date: Date.new(2026, 1, 1))

    assert_equal 1, result[:transactions].size
    assert_equal "bank_tx_1", result[:transactions].first[:id]
  end

  test "get_account_balance maps currentBalance + currency" do
    stub_request(:get, "https://api.redbark.com/v1/balances").with(query: { accountIds: "acc-bank" }).to_return(
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: { data: [ { accountId: "acc-bank", currentBalance: "469.30", availableBalance: "400.00", currency: "AUD" } ] }.to_json
    )

    result = @client.get_account_balance("acc-bank")

    assert_equal "469.30", result[:balance][:amount]
    assert_equal "AUD", result[:balance][:currency]
  end

  test "raises an unauthorized RedbarkError on 401" do
    stub_request(:get, "https://api.redbark.com/v1/connections").to_return(status: 401, body: "")

    error = assert_raises(Provider::Redbark::RedbarkError) { @client.get_accounts }
    assert_equal :unauthorized, error.error_type
  end

  test "fetch_paginated walks every page" do
    stub_request(:get, "https://api.redbark.com/v1/connections").to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { data: [ { id: "c", category: "banking", status: "active" } ] }.to_json
    )
    stub_request(:get, "https://api.redbark.com/v1/accounts").with(query: { limit: "200", offset: "0" }).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { data: [ { id: "a1", connectionId: "c", name: "A1", type: "transaction", currency: "AUD" } ], pagination: { hasMore: true } }.to_json
    )
    stub_request(:get, "https://api.redbark.com/v1/accounts").with(query: { limit: "200", offset: "200" }).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { data: [ { id: "a2", connectionId: "c", name: "A2", type: "transaction", currency: "AUD" } ], pagination: { hasMore: false } }.to_json
    )

    result = @client.get_accounts

    assert_equal %w[a1 a2], result[:accounts].map { |a| a[:id] }
  end
end
