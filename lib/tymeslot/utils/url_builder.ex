defmodule Tymeslot.Utils.UrlBuilder do
  @moduledoc """
  Utility module for building application URLs consistently.

  This module delegates to the Endpoint configuration for scheme, host, and port.
  All URL generation is built on top of `TymeslotWeb.Endpoint.url/0`, which means:
  - The `:url` config in `config/config.exs`, `config/dev.exs`, `config/test.exs`, etc.
    determines the scheme, host, and port used in generated URLs.
  - For email links and redirects, ensure the Endpoint `:url` config matches the URL
    clients will actually use to access the application.

  See `config/dev.exs` for dev setup and `config/runtime.exs` for production setup.
  """

  alias TymeslotWeb.Endpoint

  @doc """
  Builds the base URL for the application based on environment configuration.

  ## Examples
      iex> UrlBuilder.base_url()
      "https://example.com"

      iex> UrlBuilder.base_url()
      "http://localhost:4000"
  """
  @spec base_url() :: String.t()
  def base_url do
    # Use Endpoint.url() as the single source of truth
    # The Endpoint respects the :url config (scheme, host, port) from config files
    Endpoint.url()
  end

  @doc """
  Builds a full URL for a given path.

  ## Examples
      iex> UrlBuilder.build_url("/email-change/abc123")
      "https://example.com/email-change/abc123"
  """
  @spec build_url(String.t()) :: String.t()
  def build_url(path) when is_binary(path) do
    base = base_url()

    # Ensure path starts with /
    path = if String.starts_with?(path, "/"), do: path, else: "/#{path}"

    "#{base}#{path}"
  end

  @doc """
  Builds an email change verification URL.
  """
  @spec email_change_url(String.t()) :: String.t()
  def email_change_url(token) when is_binary(token) do
    build_url("/email-change/#{token}")
  end

  @doc """
  Builds an email verification URL.
  """
  @spec email_verification_url(String.t()) :: String.t()
  def email_verification_url(token) when is_binary(token) do
    build_url("/auth/verify-complete/#{token}")
  end

  @doc """
  Builds a password reset URL.
  """
  @spec password_reset_url(String.t()) :: String.t()
  def password_reset_url(token) when is_binary(token) do
    build_url("/auth/reset-password/#{token}")
  end
end
