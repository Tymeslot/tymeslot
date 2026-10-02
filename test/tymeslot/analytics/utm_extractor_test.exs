defmodule Tymeslot.Analytics.UtmExtractorTest do
  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :analytics

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

    test "keeps campaign-level attribution params (ref, mc_cid, gclsrc) in tracking_params" do
      params = %{
        "utm_source" => "linkedin",
        "ref" => "newsletter-42",
        "mc_cid" => "a1b2c3",
        "gclsrc" => "aw.ds"
      }

      result = UtmExtractor.extract(params)

      assert result.utm_source == "linkedin"

      assert result.tracking_params == %{
               "ref" => "newsletter-42",
               "mc_cid" => "a1b2c3",
               "gclsrc" => "aw.ds"
             }
    end

    test "drops per-person click and subscriber identifiers, keeping campaign tags" do
      params = %{
        "fbclid" => "IwAR-click",
        "mc_eid" => "subscriber-1",
        "mc_cid" => "campaign-1",
        "ref" => "spring"
      }

      result = UtmExtractor.extract(params)

      assert result.tracking_params == %{
               "ad_network" => "meta",
               "mc_cid" => "campaign-1",
               "ref" => "spring"
             }
    end

    test "records a Google click as the network only, never the gclid" do
      result = UtmExtractor.extract(%{"gclid" => "Cj0KCQ-click", "utm_source" => "x"})

      assert result.utm_source == "x"
      assert result.tracking_params == %{"ad_network" => "google"}
    end

    test "maps each click identifier to the network that issued it" do
      networks = %{
        "gclid" => "google",
        "gbraid" => "google",
        "wbraid" => "google",
        "dclid" => "google",
        "fbclid" => "meta",
        "msclkid" => "microsoft",
        "ttclid" => "tiktok",
        "twclid" => "x",
        "li_fat_id" => "linkedin",
        "yclid" => "yandex",
        "rdt_cid" => "reddit",
        "epik" => "pinterest"
      }

      mismatches =
        Enum.reject(networks, fn {key, network} ->
          UtmExtractor.extract(%{key => "id-123"}).tracking_params == %{"ad_network" => network}
        end)

      assert mismatches == []
    end

    test "drops Instagram's igshid without recording a network" do
      assert UtmExtractor.extract(%{"igshid" => "sharer-1"}).tracking_params == %{}
    end

    test "accepts a known ad_network back from the query string, so it survives navigation" do
      assert UtmExtractor.extract(%{"ad_network" => "google"}).tracking_params ==
               %{"ad_network" => "google"}
    end

    test "drops an ad_network value that names no known network" do
      assert UtmExtractor.extract(%{"ad_network" => "invitee@example.com"}).tracking_params ==
               %{}
    end

    test "drops non-allowlisted params so visitor PII is never persisted" do
      params = %{
        "utm_source" => "linkedin",
        "ref" => "keep-me",
        "email" => "invitee@example.com",
        "phone" => "+15555550123",
        "session" => "secret-token",
        "anything_custom" => "nope"
      }

      result = UtmExtractor.extract(params)

      assert result.utm_source == "linkedin"
      assert result.tracking_params == %{"ref" => "keep-me"}
    end

    test "ignores non-string param values to prevent JSON pollution" do
      params = %{"ref" => "x", "blob" => %{nested: "thing"}}
      result = UtmExtractor.extract(params)
      assert result.tracking_params == %{"ref" => "x"}
    end

    test "drops Phoenix routing keys (username, slug, etc.)" do
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

    test "truncates over-long allowlisted tracking values to 255 bytes" do
      long_value = String.duplicate("v", 1000)
      result = UtmExtractor.extract(%{"ref" => long_value})
      assert byte_size(result.tracking_params["ref"]) == 255
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
