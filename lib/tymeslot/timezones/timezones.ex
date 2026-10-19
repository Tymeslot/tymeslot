defmodule Tymeslot.Timezones do
  @moduledoc """
  Public API for timezone operations.

  Delegates to focused sub-modules for data access, formatting, and validation.
  Callers should alias this single module.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Timezones.{Data, Formatting}

  # Longest IANA id is well under 40 chars; this is an injection guard, not a
  # format check, so it stays generous.
  @max_timezone_length 100

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
  defdelegate flag_exists?(country_code), to: Data

  defdelegate format(timezone_id), to: Formatting
  defdelegate utc_offset(timezone_id), to: Formatting
  defdelegate utc_offset(timezone_id, at), to: Formatting

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
  Checks a timezone someone chose, for a form that should tell them when it
  is wrong.

  Identity is decided by `valid?/1`, a real IANA lookup, so anything the time
  zone database resolves is accepted, including three-segment ids such as
  `America/Argentina/Buenos_Aires` and offset zones such as `Etc/GMT+5`. An
  oversized string is refused before it reaches the lookup. The error is a
  translated message; the log line says which check failed.
  """
  @spec validate(term()) :: {:ok, String.t()} | {:error, String.t()}
  def validate(timezone) when is_binary(timezone) do
    cond do
      String.length(timezone) > @max_timezone_length ->
        Logger.warning("Timezone validation failed: too long",
          timezone_length: String.length(timezone)
        )

        {:error, invalid_message()}

      not valid?(timezone) ->
        Logger.warning("Timezone validation failed: unknown zone", timezone: timezone)
        {:error, invalid_message()}

      true ->
        {:ok, timezone}
    end
  end

  def validate(timezone) do
    Logger.warning("Timezone validation failed: not a string",
      value_type: LogFormat.reason(timezone)
    )

    {:error, invalid_message()}
  end

  defp invalid_message, do: dgettext("errors", "Invalid timezone")
end
