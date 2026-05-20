defmodule Tymeslot.Emails.Shared.Sanitise do
  @moduledoc """
  HTML-escape helper for email templates — the canonical safety boundary between
  raw user input and rendered MJML/HTML.
  """

  alias Phoenix.HTML
  alias Tymeslot.Security.UrlValidation

  @doc """
  Sanitizes text for email display.
  """
  @spec sanitize_for_email(String.t() | nil) :: String.t()
  def sanitize_for_email(nil), do: ""

  def sanitize_for_email(text) when is_binary(text) do
    text
    |> String.trim()
    |> HTML.html_escape()
    |> HTML.safe_to_string()
  end

  @doc """
  Validates and sanitises a URL for use in an email `href`. Returns `"#"` for
  anything that doesn't parse as an http(s) URL.
  """
  @spec sanitize_url(String.t() | nil) :: String.t()
  def sanitize_url(url) do
    case UrlValidation.validate_http_url(url) do
      :ok -> sanitize_for_email(url)
      _other -> "#"
    end
  end
end
