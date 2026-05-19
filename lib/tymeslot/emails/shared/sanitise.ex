defmodule Tymeslot.Emails.Shared.Sanitise do
  @moduledoc """
  Safety boundary between raw user input and rendered email content.

  Two helpers cover the two distinct sinks:

  - `sanitize_for_email/1` — HTML-escapes text destined for the MJML/HTML body.
  - `sanitize_for_header/1` — strips control characters from values destined
    for headers like Subject so they cannot inject additional headers via
    embedded CR/LF.
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
  Sanitises a value bound for an email header (typically Subject).

  Replaces ASCII control characters — including CR and LF — with a single
  space and collapses runs of whitespace. This is the boundary that prevents
  email header injection when a user-authored field (meeting title, attendee
  name, etc.) is interpolated into the Subject line: CR/LF in headers would
  otherwise allow an attacker to add their own headers to the outgoing email.
  """
  @spec sanitize_for_header(String.t() | nil) :: String.t()
  def sanitize_for_header(nil), do: ""

  def sanitize_for_header(value) when is_binary(value) do
    value
    |> String.replace(~r/[\x00-\x1F\x7F]/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
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
