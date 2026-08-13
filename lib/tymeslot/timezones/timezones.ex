defmodule Tymeslot.Timezones do
  @moduledoc """
  Public API for timezone operations.

  Delegates to focused sub-modules for data access, formatting, and validation.
  Callers should alias this single module.
  """

  require Logger

  alias Tymeslot.Timezones.{Data, Formatting}

  # Fail the build if `tz` compiled against a different IANA release than the
  # one Core pins. The pin only takes effect when config/ and priv/tz/ are both
  # in place before `mix deps.compile`; when they are not, `tz` quietly falls
  # back to its own bundled release and every conversion drifts by whatever DST
  # rules changed in between. That is invisible at runtime, so catch it here.
  @pinned_iana_version Application.compile_env!(:tz, :iana_version)

  if Tz.iana_version() != @pinned_iana_version do
    raise """
    IANA time zone data mismatch: `tz` compiled #{Tz.iana_version()}, but Core \
    pins #{@pinned_iana_version}.

    In a container build this usually means config/ and priv/tz/ were copied \
    after `mix deps.compile` rather than before it. Locally, run:

        mix tz.download #{@pinned_iana_version} && mix deps.compile tz --force
    """
  end

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

  @fallback "Etc/UTC"

  @doc """
  The zone to render in when the user's own is unknown, missing, or invalid.

  Use this instead of spelling a literal at the call site. The dashboard used to
  carry three: `"UTC"`, `"Etc/UTC"`, and a `nil` that reached `format/1` — which
  matters because they do not render alike, so the same account could be shown
  a different zone depending on which surface it was looking at.

  ## Examples

      iex> Tymeslot.Timezones.fallback()
      "Etc/UTC"
  """
  @spec fallback() :: String.t()
  def fallback, do: @fallback

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

      @fallback
    end
  end
end
