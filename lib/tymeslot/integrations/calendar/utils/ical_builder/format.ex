defmodule Tymeslot.Integrations.Calendar.ICalBuilder.Format do
  @moduledoc """
  Low-level iCalendar (RFC 5545) value formatting and escaping primitives.

  Pure leaf functions shared across the iCal builder: date/time serialisation,
  text escaping, value sanitisation, and UID generation. No event assembly
  logic lives here.
  """

  # The mark of an event Tymeslot created. The CalDAV and ICS syncs know
  # nothing else about who made an event, so a uid carries it only when the
  # event really is Tymeslot's (`uid_origin/1`).
  @tymeslot_suffix "@tymeslot.com"

  @doc """
  Generates a unique identifier for an event.

  An event of Tymeslot's own (`:tymeslot`, the default) gets
  `{random-hex}@tymeslot.com`. A new copy of somebody else's event
  (`:foreign`), such as one moved to another calendar, gets the bare
  `{random-hex}`, so the copy is not taken for Tymeslot's on the next sync.
  """
  @spec generate_uid(:tymeslot | :foreign) :: String.t()
  def generate_uid(origin \\ :tymeslot)
  def generate_uid(:tymeslot), do: random_hex() <> @tymeslot_suffix
  def generate_uid(:foreign), do: random_hex()

  defp random_hex, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  @doc """
  Who created the event `uid` names, as far as the uid tells: `:tymeslot`
  for one `generate_uid/1` marked as Tymeslot's, `:foreign` for any other.
  """
  @spec uid_origin(String.t() | nil) :: :tymeslot | :foreign
  def uid_origin(uid) when is_binary(uid) do
    if String.ends_with?(uid, @tymeslot_suffix), do: :tymeslot, else: :foreign
  end

  def uid_origin(_none), do: :foreign

  @doc """
  Formats a DateTime for iCalendar format.

  Converts to UTC and formats as: YYYYMMDDTHHMMSSZ

  ## Examples

      iex> Format.format_datetime(~U[2024-01-15 10:30:45.123456Z])
      "20240115T103045Z"
  """
  @spec format_datetime(DateTime.t()) :: String.t()
  def format_datetime(%DateTime{} = datetime) do
    datetime
    |> DateTime.to_iso8601(:basic)
    |> String.replace(~r/\.\d+/, "")
  end

  @doc """
  Formats a Date for all-day events in iCalendar format.

  ## Examples

      iex> Format.format_date(~D[2024-01-15])
      "20240115"
  """
  @spec format_date(Date.t()) :: String.t()
  def format_date(%Date{} = date) do
    Date.to_iso8601(date, :basic)
  end

  @doc """
  Formats a NaiveDateTime as a floating (zoneless) iCalendar date-time.

  Used for events that carry wall-clock time without a UTC offset, so no `Z`
  suffix and no TZID parameter are emitted.
  """
  @spec format_naive_datetime(NaiveDateTime.t()) :: String.t()
  def format_naive_datetime(%NaiveDateTime{} = ndt) do
    ndt
    |> NaiveDateTime.to_iso8601(:basic)
    |> String.replace(~r/\.\d+/, "")
  end

  @doc """
  Escapes text for iCalendar format.

  Handles special characters according to RFC 5545.
  """
  @spec escape_text(String.t() | nil) :: String.t()
  def escape_text(nil), do: ""

  def escape_text(text) when is_binary(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace(",", "\\,")
    |> String.replace(";", "\\;")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "")
  end

  @doc """
  Strips CR, LF, and C0 control characters from a value destined for a
  non-text iCal property (URI, mailto), preventing property injection.

  Non-binary values pass through unchanged.
  """
  @spec sanitize_ical_value(value) :: value when value: var
  def sanitize_ical_value(value) when is_binary(value) do
    String.replace(value, ~r/[\r\n\x00-\x1f]/, "")
  end

  def sanitize_ical_value(value), do: value
end
