defmodule Tymeslot.Integrations.Calendar.RemovedCalendars do
  @moduledoc """
  What Tymeslot records, and tells the owner, when it stops using a calendar
  because the calendar server no longer has it.

  Every path that deselects a calendar the server stopped listing (an event
  read that gets a 404, a CalDAV sync, a Google sync, and discovery, which
  deselects by leaving the calendar out of the merged list) does the same
  three things in the transaction that holds the integration's row:

    * works out what it removed with `removed/2`: the calendars selected
      before and not selected after;
    * writes `merge/3` of them into `removed_calendars` in the same update
      that deselects them, for the dashboard notice;
    * schedules one email listing them with `notify/2`.

  The deselection is the claim on the email: a retried sync finds those
  calendars already deselected, removes nothing, and sends nothing. A
  calendar the owner deselects themselves never passes through here.
  """

  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.RemovedCalendar
  alias Tymeslot.Utils.UriUtils

  @doc """
  The calendars selected in `old_list` that are not selected in `new_list`,
  matched by path or id, percent-encoded or not, as discovery matches them.
  A calendar missing from `new_list` altogether counts
  as removed, which is how discovery deselects.
  """
  @spec removed([CalendarEntry.t()], [CalendarEntry.t()]) :: [CalendarEntry.t()]
  def removed(old_list, new_list) do
    kept = new_list |> Enum.filter(& &1.selected) |> Enum.flat_map(&keys/1) |> MapSet.new()

    Enum.filter(old_list, fn entry ->
      entry.selected and not Enum.any?(keys(entry), &MapSet.member?(kept, &1))
    end)
  end

  @doc """
  `existing` with `removed` added as of `now`. A calendar already listed,
  under either encoding of its path, is replaced, not listed twice.
  """
  @spec merge([RemovedCalendar.t()], [CalendarEntry.t()], DateTime.t()) :: [RemovedCalendar.t()]
  def merge(existing, removed, now) do
    removed_at = DateTime.truncate(now, :second)

    added =
      Enum.map(removed, fn entry ->
        %RemovedCalendar{id: calendar_id(entry), name: name(entry), removed_at: removed_at}
      end)

    added_ids = MapSet.new(added, &UriUtils.safe_decode(&1.id))
    Enum.reject(existing, &MapSet.member?(added_ids, UriUtils.safe_decode(&1.id))) ++ added
  end

  @doc """
  Schedules the one email telling the owner about `removed`. Call it in the
  transaction that deselects them, so a failure rolls the deselection back
  and the next run tries both again.
  """
  @spec notify(
          %{
            required(:id) => pos_integer(),
            required(:user_id) => pos_integer(),
            optional(atom()) => term()
          },
          [CalendarEntry.t()]
        ) :: :ok | {:error, term()}
  def notify(_integration, []), do: :ok

  def notify(%{id: id, user_id: user_id}, removed) do
    EmailScheduler.schedule_calendars_removed_notification(
      user_id,
      id,
      Enum.map(removed, &name/1)
    )
  end

  # Decoded, so a server that starts percent-encoding a path it used to send
  # plain (or the reverse) still names the same calendar.
  defp keys(%CalendarEntry{path: path, id: id}),
    do: [path, id] |> Enum.reject(&is_nil/1) |> Enum.map(&UriUtils.safe_decode/1)

  defp calendar_id(entry), do: entry.path || entry.id

  # A calendar the server never named is shown by its path or id.
  defp name(%CalendarEntry{name: name} = entry) when name in [nil, ""], do: calendar_id(entry)
  defp name(%CalendarEntry{name: name}), do: name
end
