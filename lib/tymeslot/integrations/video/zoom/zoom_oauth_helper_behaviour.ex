defmodule Tymeslot.Integrations.Video.Zoom.ZoomOAuthHelperBehaviour do
  @moduledoc """
  Behaviour for Zoom OAuth helpers — defined for mockability in tests.
  """

  @callback authorization_url(integer(), String.t()) :: String.t()
  @callback authorization_url(integer(), String.t(), keyword()) :: String.t()
  @callback exchange_code_for_tokens(String.t(), String.t(), String.t()) ::
              {:ok, map()} | {:error, String.t()}
  @callback refresh_access_token(String.t(), String.t() | nil) ::
              {:ok, map()} | {:error, String.t()}
  @callback validate_token(map()) ::
              {:ok, :valid | :needs_refresh} | {:error, String.t()}
end
