defmodule Tymeslot.Infrastructure.Logging.EmailMasker do
  @moduledoc """
  Masks email addresses in text: `jane@example.com` becomes
  `j***@example.com`.

  The one masking rule for every sink that stores or sends text from the
  application: log formatting (`LogFormat`), stored error reports
  (`ErrorTracking.Filter`, `ReasonScrubber`) and admin alert payloads
  (`AdminAlerts.PIIScrubber`).

  Bump `ErrorTracking.ReasonScrubber`'s `@rules_version` with any change to
  the pattern or to how an address is masked, so stored error reports are
  masked again.
  """

  @email_regex ~r/([A-Za-z0-9._%+-])[A-Za-z0-9._%+-]*(@[A-Za-z0-9.-]+\.[A-Za-z]{2,})/

  @doc """
  Masks every email address embedded in `string`, leaving the rest of the
  text as it was. Idempotent.
  """
  @spec mask_emails(String.t()) :: String.t()
  def mask_emails(string) when is_binary(string) do
    Regex.replace(@email_regex, string, fn _full, first_char, domain ->
      "#{first_char}***#{domain}"
    end)
  end

  @doc """
  The masked form of `value` when `value` is an email address and nothing
  else, or nil.
  """
  @spec mask_email(String.t()) :: String.t() | nil
  def mask_email(value) when is_binary(value) do
    case Regex.run(@email_regex, value) do
      [^value, first_char, domain] -> "#{first_char}***#{domain}"
      _not_an_address -> nil
    end
  end
end
