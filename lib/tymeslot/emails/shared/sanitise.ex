defmodule Tymeslot.Emails.Shared.Sanitise do
  @moduledoc """
  HTML-escape helper for email templates — the canonical safety boundary between
  raw user input and rendered MJML/HTML.
  """

  alias Phoenix.HTML

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
end
