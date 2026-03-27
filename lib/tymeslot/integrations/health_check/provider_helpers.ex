defmodule Tymeslot.Integrations.HealthCheck.ProviderHelpers do
  @moduledoc false

  require Logger

  @doc """
  Converts a provider name string to an existing atom, returning `nil` for
  empty, nil, or unrecognised values instead of raising.
  """
  @spec safe_to_existing_atom(String.t() | nil) :: atom() | nil
  def safe_to_existing_atom(nil), do: nil

  def safe_to_existing_atom("") do
    Logger.warning("Empty provider name encountered")
    nil
  end

  def safe_to_existing_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError ->
      Logger.warning("Provider name not recognised, check for typos",
        value: value,
        hint: "Valid providers: google, outlook, caldav, nextcloud, radicale, teams, etc."
      )

      nil
  end
end
