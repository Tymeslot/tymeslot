defmodule Tymeslot.Integrations.Calendar.Shared.PathUtilsTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.Shared.PathUtils

  describe "ensure_scheme/1" do
    test "leaves valid https URLs untouched" do
      assert PathUtils.ensure_scheme("https://cloud.example.com") ==
               "https://cloud.example.com"
    end

    test "leaves valid http URLs untouched" do
      assert PathUtils.ensure_scheme("http://cloud.example.com") ==
               "http://cloud.example.com"
    end

    test "prepends https:// to a bare host" do
      assert PathUtils.ensure_scheme("cloud.example.com") ==
               "https://cloud.example.com"
    end

    test "normalises protocol-relative //host to https://host" do
      assert PathUtils.ensure_scheme("//cloud.example.com") ==
               "https://cloud.example.com"
    end

    test "trims surrounding whitespace before checking the scheme" do
      assert PathUtils.ensure_scheme("  https://cloud.example.com  ") ==
               "https://cloud.example.com"
    end

    # Regression: a Nextcloud integration was once stored with base_url
    # "https://https:/" — the input was the malformed "https:/cloud.lukabreitig.com"
    # (single slash), which the old literal `starts_with?("https://")` check
    # missed, so "https://" was naively prepended a second time, producing
    # "https://https:/cloud.lukabreitig.com" and a host of "https". Guard
    # against any "https?:/*" prefix the input may already carry.
    test "repairs https with a single slash and no host" do
      refute String.starts_with?(PathUtils.ensure_scheme("https:/"), "https://https")
    end

    test "repairs https:/host (single slash) without doubling the scheme" do
      assert PathUtils.ensure_scheme("https:/cloud.example.com") ==
               "https://cloud.example.com"
    end

    test "repairs https:host (no slashes) without doubling the scheme" do
      assert PathUtils.ensure_scheme("https:cloud.example.com") ==
               "https://cloud.example.com"
    end

    test "repairs http:/host (single slash)" do
      assert PathUtils.ensure_scheme("http:/cloud.example.com") ==
               "https://cloud.example.com"
    end
  end
end
