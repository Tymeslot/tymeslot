defmodule Tymeslot.Timezones do
  @moduledoc """
  Public API for timezone operations.

  Delegates to focused sub-modules for data access, formatting, and validation.
  Callers should alias this single module.
  """

  require Logger

  alias Tymeslot.Timezones.{Data, Formatting}

  defdelegate all_options(), to: Data
  defdelegate search(term), to: Data
  defdelegate country_code(timezone_id), to: Data
  defdelegate normalize(timezone_id), to: Data
  defdelegate sanitize(timezone), to: Data
  defdelegate valid?(timezone_id), to: Data
  defdelegate offered?(timezone_id), to: Data
  defdelegate offered_ids(), to: Data
  defdelegate flag_exists?(country_code), to: Data

  defdelegate format(timezone_id), to: Formatting
  defdelegate utc_offset(timezone_id), to: Formatting
  defdelegate format_utc_offset(seconds), to: Formatting

  @doc """
  Validates a timezone string at the LiveView edge, returning it unchanged if valid
  or `"Etc/UTC"` if invalid.

  Validity is `valid?/1`, a real runtime time-zone database lookup, so any zone
  IANA knows is kept as-is.

  Emits one `Logger.warning` on fallback. Supply `metadata` (a keyword list) to
  include contextual fields — e.g. `[user_id: user.id]` — so operators can surface
  affected accounts from logs.

  ## Examples

      iex> Tymeslot.Timezones.validate_or_utc("Europe/London")
      "Europe/London"

      iex> Tymeslot.Timezones.validate_or_utc("Not/Real")
      "Etc/UTC"
  """
  @spec validate_or_utc(String.t(), keyword()) :: String.t()
  def validate_or_utc(timezone, metadata \\ []) when is_binary(timezone) do
    if valid?(timezone) do
      timezone
    else
      Logger.warning(
        "Invalid user timezone; falling back to UTC for calendar rendering",
        Keyword.merge([timezone: timezone], metadata)
      )

      "Etc/UTC"
    end
  end
end
