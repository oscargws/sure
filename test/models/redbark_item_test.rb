require "test_helper"

class RedbarkItemTest < ActiveSupport::TestCase
  def setup
    @redbark_item = redbark_items(:one)
  end

  test "effective_base_url returns default when base_url blank" do
    @redbark_item.base_url = nil

    assert_equal RedbarkItem::DEFAULT_BASE_URL, @redbark_item.effective_base_url
  end

  test "effective_base_url returns default for non-redbark host (SSRF guard)" do
    @redbark_item.base_url = "https://169.254.169.254/latest/meta-data"

    assert_equal RedbarkItem::DEFAULT_BASE_URL, @redbark_item.effective_base_url
  end

  test "effective_base_url returns default for non-https scheme" do
    @redbark_item.base_url = "http://api.redbark.com"

    assert_equal RedbarkItem::DEFAULT_BASE_URL, @redbark_item.effective_base_url
  end

  test "effective_base_url returns canonical default for valid redbark url" do
    @redbark_item.base_url = "https://api.redbark.com/"

    assert_equal RedbarkItem::DEFAULT_BASE_URL, @redbark_item.effective_base_url
  end

  test "credentials_configured? reflects api_key presence" do
    assert @redbark_item.credentials_configured?

    @redbark_item.api_key = nil
    assert_not @redbark_item.credentials_configured?
  end
end
