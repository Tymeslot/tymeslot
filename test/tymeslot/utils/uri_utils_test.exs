defmodule Tymeslot.Utils.UriUtilsTest do
  use ExUnit.Case, async: true

  @moduletag :utils

  alias Tymeslot.Utils.UriUtils

  describe "safe_decode/1" do
    test "decodes a valid percent-encoded string" do
      assert UriUtils.safe_decode("/dav/user%40example.org/Calendar") ==
               "/dav/user@example.org/Calendar"
    end

    test "returns the string unchanged when there is nothing to decode" do
      assert UriUtils.safe_decode("/dav/user@example.org/Calendar") ==
               "/dav/user@example.org/Calendar"
    end

    test "returns the original string on malformed percent-encoding" do
      assert UriUtils.safe_decode("/path/%GGbad") == "/path/%GGbad"
    end

    test "returns empty string unchanged" do
      assert UriUtils.safe_decode("") == ""
    end
  end

  describe "uri_safe_match?/2" do
    test "matches identical strings" do
      assert UriUtils.uri_safe_match?("/dav/user/Calendar", "/dav/user/Calendar")
    end

    test "matches percent-encoded vs decoded" do
      assert UriUtils.uri_safe_match?(
               "/dav/user%40example.org/Calendar",
               "/dav/user@example.org/Calendar"
             )
    end

    test "matches when both are percent-encoded" do
      assert UriUtils.uri_safe_match?(
               "/dav/user%40example.org/Calendar",
               "/dav/user%40example.org/Calendar"
             )
    end

    test "matches with mixed encoding (space as %20)" do
      assert UriUtils.uri_safe_match?("/cal/My%20Calendar", "/cal/My Calendar")
    end

    test "rejects different paths" do
      refute UriUtils.uri_safe_match?("/dav/user/Calendar", "/dav/other/Calendar")
    end

    test "returns false when first argument is nil" do
      refute UriUtils.uri_safe_match?(nil, "/dav/user/Calendar")
    end

    test "returns false when second argument is nil" do
      refute UriUtils.uri_safe_match?("/dav/user/Calendar", nil)
    end

    test "returns false when both arguments are nil" do
      refute UriUtils.uri_safe_match?(nil, nil)
    end

    test "matches empty strings" do
      assert UriUtils.uri_safe_match?("", "")
    end

    test "returns false for mismatched empty string and non-empty string" do
      refute UriUtils.uri_safe_match?("", "/dav/user/Calendar")
    end

    test "treats malformed percent-encoding as literal when both sides match" do
      assert UriUtils.uri_safe_match?("/path/%GGbad", "/path/%GGbad")
    end

    test "returns false when one side has malformed encoding and the other differs" do
      refute UriUtils.uri_safe_match?("/path/%GGbad", "/path/other")
    end
  end
end
