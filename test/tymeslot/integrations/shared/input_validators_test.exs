defmodule Tymeslot.Integrations.Shared.InputValidatorsTest do
  use Tymeslot.DataCase, async: true

  @moduletag :integrations

  alias Tymeslot.Integrations.Shared.InputValidators

  describe "validate_integration_name/2 (with metadata)" do
    test "accepts valid name with metadata" do
      assert {:ok, "My Calendar"} =
               InputValidators.validate_integration_name("My Calendar", %{})
    end

    test "rejects empty name with metadata" do
      assert {:error, %{name: _error}} = InputValidators.validate_integration_name("", %{})
    end

    test "strips leading zero-width space and returns clean value" do
      # U+200B is a Unicode Cf-category character that String.trim/1 does not remove.
      assert {:ok, "Gmail"} = InputValidators.validate_integration_name("\u200BGmail", %{})
    end

    test "rejects a name that is only invisible characters" do
      # After stripping U+200B and U+200C the value is empty — too short to be valid.
      assert {:error, %{name: _error}} =
               InputValidators.validate_integration_name("\u200B\u200C", %{})
    end
  end

  describe "normalize_url_protocol/1" do
    test "leaves https:// urls unchanged" do
      assert InputValidators.normalize_url_protocol("https://example.com") ==
               "https://example.com"
    end

    test "leaves http:// urls unchanged" do
      assert InputValidators.normalize_url_protocol("http://example.com") ==
               "http://example.com"
    end

    test "adds https:// to urls without protocol" do
      assert InputValidators.normalize_url_protocol("example.com") ==
               "https://example.com"
    end

    test "adds https:// to domain with path" do
      assert InputValidators.normalize_url_protocol("example.com/path") ==
               "https://example.com/path"
    end

    test "returns empty string unchanged" do
      assert InputValidators.normalize_url_protocol("") == ""
    end

    test "trims whitespace before normalizing" do
      assert InputValidators.normalize_url_protocol("  example.com  ") ==
               "https://example.com"
    end
  end

  describe "validate_server_url/3" do
    test "accepts valid https URL" do
      assert {:ok, _url} =
               InputValidators.validate_server_url("https://example.com", %{})
    end

    test "adds https:// to protocol-less URL" do
      assert {:ok, url} = InputValidators.validate_server_url("example.com", %{})
      assert String.starts_with?(url, "https://")
    end

    test "rejects URL without a host" do
      assert {:error, _msg} = InputValidators.validate_server_url("https://", %{})
    end

    test "rejects URL without a dot in domain (non-localhost)" do
      assert {:error, _msg} = InputValidators.validate_server_url("https://nodot", %{})
    end

    test "uses custom error message from opts" do
      assert {:error, "Custom error"} =
               InputValidators.validate_server_url(
                 "https://",
                 %{},
                 error_message: "Custom error"
               )
    end

    test "applies custom validate_url_fn" do
      always_fail = fn _url -> {:error, "always fails"} end

      assert {:error, "always fails"} =
               InputValidators.validate_server_url(
                 "https://example.com",
                 %{},
                 validate_url_fn: always_fail
               )
    end

    test "falls back to the HTTP/HTTPS allow-list when no validate_url_fn is given" do
      # 2000 characters is `UrlValidation`'s own limit, so a longer URL only
      # fails if the default really does run that check.
      long_url = "https://example.com/" <> String.duplicate("a", 2_000)

      assert {:error, message} = InputValidators.validate_server_url(long_url, %{})
      assert message =~ "2000 characters"
    end
  end

  describe "validate_server_url/3 stores the URL as typed" do
    test "keeps a path segment containing a double hyphen" do
      url = "https://meet.example.com/team--sync"
      assert {:ok, ^url} = InputValidators.validate_server_url(url, %{})
    end

    test "keeps a percent-encoded hash rather than decoding it into a fragment" do
      url = "https://meet.example.com/room%23a"
      assert {:ok, ^url} = InputValidators.validate_server_url(url, %{})
    end

    test "keeps a path segment that reads as a hex literal" do
      url = "https://meet.example.com/0xdeadbeef-room"
      assert {:ok, ^url} = InputValidators.validate_server_url(url, %{})
    end

    test "keeps percent-encoded slashes, question marks and percent signs" do
      url = "https://meet.example.com/a%2Fb%3Fc?token=100%25"
      assert {:ok, ^url} = InputValidators.validate_server_url(url, %{})
    end

    test "keeps a relative-looking path segment" do
      url = "https://meet.example.com/../rooms/standup"
      assert {:ok, ^url} = InputValidators.validate_server_url(url, %{})
    end

    test "refuses rather than rewrites a URL containing a newline" do
      assert {:error, _msg} =
               InputValidators.validate_server_url(
                 "https://meet.example.com/room\nHost: elsewhere.example",
                 %{}
               )
    end

    test "refuses a URL containing an inner space" do
      assert {:error, _msg} =
               InputValidators.validate_server_url("https://meet.example.com/my room", %{})
    end

    test "refuses a URL containing an invisible character" do
      assert {:error, _msg} =
               InputValidators.validate_server_url("https://meet.exa​mple.com/room", %{})
    end

    test "still strips null bytes, which PostgreSQL rejects" do
      assert {:ok, "https://meet.example.com/room"} =
               InputValidators.validate_server_url("https://meet.example.com/ro\x00om", %{})
    end
  end
end
