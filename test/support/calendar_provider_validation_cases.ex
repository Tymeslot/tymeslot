defmodule Tymeslot.CalendarProviderValidationCases do
  @moduledoc """
  Shared test cases for calendar provider config validation.
  Reduces code duplication across CalDAV-based provider tests.
  """

  import ExUnit.Assertions

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
  Tests that a structurally complete config passes `validate_config/1` without
  touching the network. `validate_config/1` is structural only — the
  connectivity probe used to run here too, doubling the rate-limit charge
  across two buckets for a single form submission; the live check now runs
  separately, through `test_connection/1`.
  """
  @spec test_validation_accepts_without_network_probe(module(), String.t()) :: :ok
  def test_validation_accepts_without_network_probe(provider_module, example_url) do
    config = %{
      base_url: example_url,
      username: "user",
      password: "pass"
    }

    assert :ok = provider_module.validate_config(config)

    :ok
  end
end
