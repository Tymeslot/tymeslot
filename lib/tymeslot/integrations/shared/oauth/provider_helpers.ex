defmodule Tymeslot.Integrations.Shared.OAuth.ProviderHelpers do
  @moduledoc """
  Shared URL-building helpers for OAuth provider integrations.

  Provides small, pure utilities that are common across Zoom, Microsoft Teams,
  Outlook Calendar, and Google OAuth helpers, keeping provider-specific modules
  focused on their own config and flow.
  """

  @doc """
  Conditionally adds a `login_hint` key to an OAuth params map.

  Returns `params` unchanged when `hint` is `nil`; otherwise inserts
  `{:login_hint, hint}`. Used when building authorization URLs to pre-fill
  the identity provider's account-selection UI.
  """
  @spec maybe_put_login_hint(map(), String.t() | nil) :: map()
  def maybe_put_login_hint(params, nil), do: params
  def maybe_put_login_hint(params, hint), do: Map.put(params, :login_hint, hint)

  @doc """
  Builds a complete OAuth authorization URL.

  Applies `login_hint` to `params` (if non-`nil`), URL-encodes the result,
  and appends it to `base_url` with a `?` separator.

  ## Examples

      iex> build_authorization_url("https://example.com/auth", %{client_id: "abc"}, nil)
      "https://example.com/auth?client_id=abc"

      iex> build_authorization_url("https://example.com/auth", %{client_id: "abc"}, "user@example.com")
      "https://example.com/auth?client_id=abc&login_hint=user%40example.com"
  """
  @spec build_authorization_url(String.t(), map(), String.t() | nil) :: String.t()
  def build_authorization_url(base_url, params, login_hint) do
    "#{base_url}?" <> URI.encode_query(maybe_put_login_hint(params, login_hint))
  end
end
