defmodule Tymeslot.CalendarProviderValidationCases do
  @moduledoc """
  Shared test cases for calendar provider config validation.
  Reduces code duplication across CalDAV-based provider tests.
  """

  import ExUnit.Assertions
  import ExUnit.CaptureLog

  @doc """
  Tests basic validation: missing required fields and invalid URL format.
  """
  @spec test_basic_validation(module(), String.t()) :: :ok
  def test_basic_validation(provider_module, example_url) do
    # Missing base_url
    config = %{username: "user", password: "pass"}
    assert {:error, message} = provider_module.validate_config(config)
    assert String.contains?(message, "base_url")

    # Missing username
    config = %{base_url: example_url, password: "pass"}
    assert {:error, message} = provider_module.validate_config(config)
    assert String.contains?(message, "username")

    # Missing password
    config = %{base_url: example_url, username: "user"}
    assert {:error, message} = provider_module.validate_config(config)
    assert String.contains?(message, "password")

    # Invalid URL format
    config = %{
      base_url: "not-a-valid-url",
      username: "user",
      password: "pass"
    }

    assert {:error, message} = provider_module.validate_config(config)
    assert String.contains?(message, "URL")

    :ok
  end

  @doc """
  Tests that validation attempts connection when all required fields are present.
  """
  @spec test_validation_attempts_connection(module(), String.t()) :: :ok
  def test_validation_attempts_connection(provider_module, example_url) do
    config = %{
      base_url: example_url,
      username: "user",
      password: "pass"
    }

    # Will fail connection but validates structure
    capture_log(fn ->
      result = provider_module.validate_config(config)
      assert match?({:error, _}, result)
    end)

    :ok
  end
end
