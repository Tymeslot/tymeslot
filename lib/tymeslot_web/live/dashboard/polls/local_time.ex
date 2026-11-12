defmodule TymeslotWeb.Dashboard.Polls.LocalTime do
  @moduledoc """
  Converts between a `datetime-local` input's value, which carries no zone,
  and UTC, reading the value in the poll's timezone. Shared by the poll create
  form and the poll editor, with the zone the create form starts in.
  """

  alias Tymeslot.Profiles
  alias Tymeslot.Utils.DateTimeUtils

  @doc "The zone a new poll starts in: the host's own, or the app's default."
  @spec host_timezone(map() | nil) :: String.t()
  def host_timezone(%{timezone: timezone}) when is_binary(timezone) and timezone != "",
    do: timezone

  def host_timezone(_profile), do: Profiles.get_default_timezone()

  @doc "The UTC moment `value` names in `timezone`, or nil for a blank or unreadable value."
  @spec to_utc(String.t() | nil, String.t()) :: DateTime.t() | nil
  def to_utc(value, _timezone) when value in [nil, ""], do: nil

  def to_utc(value, timezone) do
    with {:ok, naive} <- parse_naive(value),
         {:ok, datetime} <- DateTimeUtils.convert_to_utc(naive, timezone) do
      DateTime.truncate(datetime, :second)
    else
      _other -> nil
    end
  end

  @doc "`datetime` as a `datetime-local` value in `timezone`; empty for nil."
  @spec to_input(DateTime.t() | nil, String.t()) :: String.t()
  def to_input(nil, _timezone), do: ""

  def to_input(%DateTime{} = datetime, timezone) do
    datetime
    |> DateTimeUtils.convert_to_timezone(timezone)
    |> DateTime.to_naive()
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_iso8601()
    |> String.slice(0, 16)
  end

  defp parse_naive(value) do
    normalized = if String.length(value) == 16, do: value <> ":00", else: value
    NaiveDateTime.from_iso8601(normalized)
  end
end
