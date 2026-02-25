defmodule Tymeslot.Locales do
  @moduledoc """
  Shared locale utilities for the core domain layer.

  Provides access to locale configuration without coupling domain modules
  to the web layer's LocaleHandler.
  """

  @doc """
  Returns the configured default locale code, falling back to "en".
  """
  @spec default_locale() :: String.t()
  def default_locale do
    Application.get_env(:tymeslot, :locales, [])[:default] || "en"
  end

  @doc """
  Returns the list of supported locale codes from application configuration.
  Returns an empty list if the configuration key is absent.
  """
  @spec supported_codes() :: [String.t()]
  def supported_codes do
    :tymeslot
    |> Application.get_env(:locales, [])
    |> Keyword.get(:supported, [])
    |> Enum.map(& &1.code)
  end
end
