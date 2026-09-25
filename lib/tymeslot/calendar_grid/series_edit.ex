defmodule Tymeslot.CalendarGrid.SeriesEdit do
  @moduledoc """
  Editing a member of a recurring series from the grid, in one of the scopes
  of `Tymeslot.CalendarGrid.RecurrenceScope`: this event, this and every
  following one, or all of them.

  `Tymeslot.CalendarGrid.EventEdit.update_event/4` routes an edit here when
  the cached row belongs to a series. What a scope takes depends on how the
  row's provider addresses part of a series, which
  `Tymeslot.CalendarGrid.Occurrence.series_family/1` answers once for edits
  and deletes alike:

    * **Google and Outlook** give every occurrence an id of its own. An edit
      of this event only is written to that id, exactly like an edit of a
      one-off event. "This and following" and "all events" need a write to
      the series' master, and are refused with `:unsupported_scope` until
      that write exists.
    * **The CalDAV family** holds a whole series in one resource, and any
      write for one occurrence would land on the series' master (see
      `EventEdit`'s moduledoc). Every edit is refused with
      `:recurring_event` until the writer can author a `RECURRENCE-ID`
      override.
    * **Exchange** has no scoped write. An edit of this event is written to
      the item's own id, as it always has been; the wider scopes are refused
      with `:unsupported_scope`.

  ## Failure

  A failed write of a series member is never queued for offline replay. The
  CalDAV offline queue refuses to replay a series member, so a queued edit
  would sit in the queue for good while the grid showed it as saved.
  """

  alias Tymeslot.CalendarGrid.EventEdit
  alias Tymeslot.CalendarGrid.Occurrence
  alias Tymeslot.CalendarGrid.RecurrenceScope

  @doc """
  How a series member whose provider is in `family` may be edited from the
  grid: `{:ok, :single}` outside a series, `{:ok, :series}` when the edit
  takes a scope, `{:error, :recurring_event}` when it cannot take one.
  """
  @spec edit_scopes(Occurrence.series_family()) ::
          {:ok, :single | :series} | {:error, :recurring_event}
  def edit_scopes(:single), do: {:ok, :single}
  def edit_scopes(:provider_ids), do: {:ok, :series}
  def edit_scopes(_caldav_or_unsupported), do: {:error, :recurring_event}

  @doc """
  Applies `changes` to `event`, a member of a series whose cached row is
  `stored` and whose provider is in `family`, in `scope`.

  Returns what `EventEdit.update_event/4` returns, except that a failure is
  always `:not_queued` (see the moduledoc).
  """
  @spec update_event(
          pos_integer(),
          map(),
          map() | nil,
          Occurrence.series_family(),
          RecurrenceScope.t(),
          EventEdit.changes(),
          keyword()
        ) :: {:ok, map()} | {:error, EventEdit.failure()}
  def update_event(user_id, event, stored, family, scope, changes, opts)

  def update_event(_user_id, _event, _stored, :caldav, _scope, _changes, _opts),
    do: refuse(:recurring_event)

  def update_event(user_id, event, stored, _family, :this_only, changes, opts),
    do: EventEdit.write_edit(user_id, event, stored, changes, opts, :never_queue)

  def update_event(_user_id, _event, _stored, _family, scope, _changes, _opts)
      when scope in [:following, :all],
      do: refuse(:unsupported_scope)

  defp refuse(reason), do: {:error, %{reason: reason, retry: :not_queued}}
end
