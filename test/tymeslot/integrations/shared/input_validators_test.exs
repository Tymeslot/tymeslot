defmodule Tymeslot.Integrations.Shared.InputValidatorsTest do
  use Tymeslot.DataCase, async: true

  @moduletag :integrations

  alias Tymeslot.Integrations.Shared.InputValidators

  describe "validate_integration_name/1" do
    test "accepts valid name" do
      assert {:ok, "My Calendar"} = InputValidators.validate_integration_name("My Calendar")
    end

    test "trims whitespace" do
      assert {:ok, "My Calendar"} = InputValidators.validate_integration_name("  My Calendar  ")
    end

    test "rejects empty string" do
      assert {:error, %{name: _error}} = InputValidators.validate_integration_name("")
    end

    test "rejects whitespace-only string" do
      assert {:error, %{name: _error}} = InputValidators.validate_integration_name("   ")
    end

    test "rejects name exceeding 120 characters" do
      long_name = String.duplicate("a", 121)
      assert {:error, %{name: _error}} = InputValidators.validate_integration_name(long_name)
    end

    test "rejects non-string values" do
      assert {:error, %{name: _error}} = InputValidators.validate_integration_name(123)
      assert {:error, %{name: _error}} = InputValidators.validate_integration_name(nil)
    end
  end

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
  end
end
