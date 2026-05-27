defmodule Tymeslot.Analytics.UtmExtractorTest do
  use ExUnit.Case, async: true

  alias Tymeslot.Analytics.UtmExtractor

  describe "extract/1" do
    test "pulls the five standard UTM fields into typed keys" do
      params = %{
        "utm_source" => "linkedin",
        "utm_medium" => "social",
        "utm_campaign" => "spring",
        "utm_content" => "ad-a",
        "utm_term" => "consultant"
      }

      assert UtmExtractor.extract(params) == %{
               utm_source: "linkedin",
               utm_medium: "social",
               utm_campaign: "spring",
               utm_content: "ad-a",
               utm_term: "consultant",
               tracking_params: %{}
             }
    end

    test "puts any non-UTM string params into tracking_params" do
      params = %{
        "utm_source" => "linkedin",
        "ref" => "newsletter-42",
        "gclid" => "abc"
      }

      result = UtmExtractor.extract(params)

      assert result.utm_source == "linkedin"
      assert result.tracking_params == %{"ref" => "newsletter-42", "gclid" => "abc"}
    end

    test "ignores non-string param values to prevent JSON pollution" do
      params = %{"ref" => "x", "blob" => %{nested: "thing"}}
      result = UtmExtractor.extract(params)
      assert result.tracking_params == %{"ref" => "x"}
    end

    test "ignores Phoenix routing keys (username, slug, etc.)" do
      params = %{"username" => "alice", "slug" => "intro", "utm_source" => "x"}
      result = UtmExtractor.extract(params)
      assert result.utm_source == "x"
      assert result.tracking_params == %{}
    end

    test "truncates values longer than 255 chars" do
      long = String.duplicate("a", 1000)
      result = UtmExtractor.extract(%{"utm_source" => long})
      assert String.length(result.utm_source) == 255
    end

    test "handles nil and empty maps" do
      assert UtmExtractor.extract(nil) == empty_result()
      assert UtmExtractor.extract(%{}) == empty_result()
    end

    defp empty_result do
      %{
        utm_source: nil,
        utm_medium: nil,
        utm_campaign: nil,
        utm_content: nil,
        utm_term: nil,
        tracking_params: %{}
      }
    end
  end

  describe "referrer_host/1" do
    test "extracts host from a full URL" do
      assert UtmExtractor.referrer_host("https://www.linkedin.com/feed/") == "www.linkedin.com"
    end

    test "downcases the host" do
      assert UtmExtractor.referrer_host("https://Example.COM/x") == "example.com"
    end

    test "returns nil for unparseable input" do
      assert UtmExtractor.referrer_host(nil) == nil
      assert UtmExtractor.referrer_host("") == nil
      assert UtmExtractor.referrer_host("not a url") == nil
    end
  end
end
