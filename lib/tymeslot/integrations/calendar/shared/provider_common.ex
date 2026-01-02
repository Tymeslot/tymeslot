defmodule Tymeslot.Integrations.Calendar.Shared.ProviderCommon do
  @moduledoc """
  Utilities shared across calendar provider implementations.
  """

  alias Tymeslot.Integrations.Calendar.Providers.CaldavCommon

  @doc """
  Ensures all required fields are present in the config map.
  """
  @spec validate_required_fields(map(), list(atom())) :: :ok | {:error, String.t()}
  def validate_required_fields(config, required_fields) do
    missing_fields = required_fields -- Map.keys(config)

    if Enum.empty?(missing_fields) do
      :ok
    else
      {:error, "Missing required fields: #{Enum.join(missing_fields, ", ")}"}
    end
  end

  @doc """
  Validates URL format (http/https with host present).
  """
  @spec validate_url(String.t(), keyword()) :: :ok | {:error, String.t()}
  def validate_url(url, opts \\ []) do
    case valid_url?(url) do
      true -> :ok
      false -> {:error, Keyword.get(opts, :message, "Invalid URL format")}
    end
  end

  @doc """
  Runs a CalDAV connection test and normalizes error responses.
  """
  @spec test_caldav_connection(map(), keyword()) :: :ok | {:error, String.t()}
  def test_caldav_connection(client, opts \\ []) do
    error_formatter = Keyword.get(opts, :error_formatter, &default_caldav_error/1)
    test_opts = Keyword.get(opts, :test_opts, [])

    case CaldavCommon.test_connection(client, test_opts) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, error_formatter.(reason)}
    end
  end

  @doc """
  Helper for providers to format calendars returned from their API.
  """
  @spec discover_calendars(map(), (map() -> {:ok, [map()]} | {:error, term()}), (map() -> map())) ::
          {:ok, [map()]} | {:error, term()}
  def discover_calendars(integration, list_fun, mapper) do
    case list_fun.(integration) do
      {:ok, calendars} -> {:ok, Enum.map(calendars, mapper)}
      error -> error
    end
  end

  defp valid_url?(url) when is_binary(url) do
    uri = URI.parse(url)
    uri.scheme in ["http", "https"] and uri.host not in [nil, ""]
  end

  defp valid_url?(_), do: false

  defp default_caldav_error({:error, message}) when is_binary(message), do: message
  defp default_caldav_error(reason), do: "Connection failed: #{inspect(reason)}"
end
