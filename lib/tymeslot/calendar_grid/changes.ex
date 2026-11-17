defmodule Tymeslot.CalendarGrid.Changes do
  @moduledoc """
  Context module for changing calendar events: creating, blocking time, editing,
  moving between calendars, deleting (now or behind an undo window),
  changing an event's video, and the series and timing rules those changes follow.

  `Tymeslot.CalendarGrid` keeps reading (ranges, search, sync, colours,
  preferences); every write the grid and the calendar surface make goes
  through this module.
  """

  alias Tymeslot.CalendarGrid.BlockTime
  alias Tymeslot.CalendarGrid.CreateParams
  alias Tymeslot.CalendarGrid.EventDeletion
  alias Tymeslot.CalendarGrid.EventEdit
  alias Tymeslot.CalendarGrid.EventMove
  alias Tymeslot.CalendarGrid.EventVideo
  alias Tymeslot.CalendarGrid.GuestUpdate
  alias Tymeslot.CalendarGrid.Moves
  alias Tymeslot.CalendarGrid.NewEvent
  alias Tymeslot.CalendarGrid.RepeatRefusal
  alias Tymeslot.CalendarGrid.ScheduledDelete
  alias Tymeslot.CalendarGrid.SeriesEdit
  alias Tymeslot.CalendarGrid.SeriesStart
  alias Tymeslot.CalendarGrid.WriteQueue.SeriesActivity
  alias Tymeslot.Integrations.Calendar.ProviderConfig

  @doc """
  Applies `changes` to an existing event, writes the whole updated event to
  its provider, and records the edit on the cached row. See
  `Tymeslot.CalendarGrid.EventEdit.update_event/4`.
  """
  @spec update_event(pos_integer(), map(), EventEdit.changes(), keyword()) ::
          {:ok, map()} | {:error, EventEdit.failure()}
  defdelegate update_event(user_id, event, changes, opts \\ []), to: EventEdit

  @doc """
  Moves an event to another calendar, creating it on the destination before
  deleting the original; a member of a series moves the whole series. See
  `Tymeslot.CalendarGrid.EventMove.move_event/3`.
  """
  @spec move_event(pos_integer(), map(), EventMove.destination()) ::
          {:ok, EventMove.moved()} | {:error, term()}
  defdelegate move_event(user_id, event, destination), to: EventMove

  @doc "See `Tymeslot.CalendarGrid.EventMove.reported/4`."
  defdelegate move_event_reported(user_id, event, destination, series_to),
    to: EventMove,
    as: :reported

  @doc "See `Tymeslot.CalendarGrid.EventMove.crash_report/2`."
  defdelegate move_crash_report(event, series_to), to: EventMove, as: :crash_report

  @doc """
  Gives an event a room on the organiser's video integration, or removes its
  video link when the integration is `nil`, on both the provider event and the
  cached row, or answers `{:ok, :unchanged}` when the choice is the one the
  event already has. See `Tymeslot.CalendarGrid.EventVideo.change_event_video/3`.
  """
  @spec change_event_video(pos_integer(), map(), pos_integer() | nil) ::
          {:ok, String.t() | nil | :unchanged}
          | {:error, :missing_meeting_url | :not_found | :linked_to_booking | term()}
  defdelegate change_event_video(user_id, event, video_integration_id), to: EventVideo

  @doc """
  An event as a successful video change wrote it: its new link, integration
  and description. See `Tymeslot.CalendarGrid.EventVideo.changed_event/4`.
  """
  @spec changed_event(pos_integer(), map(), pos_integer() | nil, String.t() | nil) :: map()
  defdelegate changed_event(user_id, event, video_integration_id, url), to: EventVideo

  @doc """
  Whether an event's video may be changed from the grid: not on the calendar
  copy of a booking, whose room belongs to the meeting. See
  `Tymeslot.CalendarGrid.EventVideo.ensure_video_changeable/1`.
  """
  @spec ensure_video_changeable(map()) :: :ok | {:error, :linked_to_booking}
  defdelegate ensure_video_changeable(event), to: EventVideo

  @doc """
  Deletes an event from its calendar, cancels the Tymeslot meeting it was
  booked as, and removes its cached row; for a member of a series, `scope`
  says whether one occurrence or the whole series goes. See
  `Tymeslot.CalendarGrid.EventDeletion.delete_event/4`, also for `opts`.
  """
  @spec delete_event(pos_integer(), EventDeletion.event(), EventDeletion.scope(), keyword()) ::
          {:ok, EventDeletion.deleted()} | {:error, EventDeletion.failure()}
  defdelegate delete_event(user_id, event, scope \\ :occurrence, opts \\ []), to: EventDeletion

  @doc """
  How an event may be deleted from the grid: on its own, in a scope, or not
  at all. See `Tymeslot.CalendarGrid.EventDeletion.deletion_scopes/1`.
  """
  @spec deletion_scopes(map()) :: {:ok, :single | :series} | {:error, :recurring_event}
  defdelegate deletion_scopes(event), to: EventDeletion

  @doc """
  Whether deleting an event would tell anyone. See
  `Tymeslot.CalendarGrid.EventDeletion.notice/2`.
  """
  @spec delete_notice(pos_integer(), map()) ::
          :silent | {:notifies, :booking | {:attendees, pos_integer()}}
  defdelegate delete_notice(user_id, event), to: EventDeletion, as: :notice

  @doc """
  Schedules a delete behind its undo window. See
  `Tymeslot.CalendarGrid.ScheduledDelete.schedule/4`.
  """
  @spec schedule_delete(pos_integer(), map(), EventDeletion.scope(), keyword()) ::
          {:ok, pos_integer()} | {:error, term()}
  defdelegate schedule_delete(user_id, event, scope, opts), to: ScheduledDelete, as: :schedule

  @doc """
  Cancels a scheduled delete that has not started. See
  `Tymeslot.CalendarGrid.ScheduledDelete.cancel/2`.
  """
  @spec cancel_scheduled_delete(pos_integer(), pos_integer()) ::
          :ok | {:error, :cancelled | :too_late}
  defdelegate cancel_scheduled_delete(user_id, token), to: ScheduledDelete, as: :cancel

  @doc """
  The user's scheduled deletes that have not finished. See
  `Tymeslot.CalendarGrid.ScheduledDelete.pending/1`.
  """
  @spec pending_deletes(pos_integer()) :: [map()]
  defdelegate pending_deletes(user_id), to: ScheduledDelete, as: :pending

  @doc """
  Whether an event may be moved to another calendar: on its own, with its
  whole series, or not at all. See
  `Tymeslot.CalendarGrid.EventMove.ensure_movable/1`.
  """
  @spec ensure_movable(map()) :: :ok | {:ok, :series} | {:error, :recurring_event}
  defdelegate ensure_movable(event), to: EventMove

  @doc """
  Whether the series an event belongs to can move to an integration, and
  what the move will not carry. See
  `Tymeslot.CalendarGrid.EventMove.series_move_notes/2`.
  """
  @spec series_move_notes(map(), map()) :: {:ok, [atom()]} | {:error, atom()}
  defdelegate series_move_notes(event, integration), to: EventMove

  @doc """
  How an event may be edited from the grid: on its own, in a scope, or, for
  a series whose provider has no scoped edit, as that one event only. See
  `Tymeslot.CalendarGrid.EventEdit.edit_scopes/1`.
  """
  @spec edit_scopes(map()) :: {:ok, :single | :this_only | :series}
  defdelegate edit_scopes(event), to: EventEdit

  @doc """
  Whether the grid can give an event of `provider` a repeat rule, or change
  the one it has (see `ProviderConfig.writes_repeat_rules?/1`).
  """
  @spec repeatable_provider?(atom() | String.t() | nil) :: boolean()
  defdelegate repeatable_provider?(provider), to: ProviderConfig, as: :writes_repeat_rules?

  @doc """
  The first start of the series `event` belongs to, which a whole-series
  repeat pattern is written against (see `SeriesStart.of/1`).
  """
  @spec series_start(map()) :: Date.t() | DateTime.t() | nil
  defdelegate series_start(event), to: SeriesStart, as: :of

  @doc """
  Where the series put `event`, which a change of it and the following
  occurrences splits the series at (see `SeriesStart.slot/1`).
  """
  @spec occurrence_slot(map()) :: Date.t() | DateTime.t() | nil
  defdelegate occurrence_slot(event), to: SeriesStart, as: :slot

  @doc """
  The rule an edit of `event` and every following occurrence writes to the
  series it starts, given the new `rule` with its `COUNT` as given for the
  whole series: the `COUNT` less the occurrences before the split, counted
  on the wall clock of `zone` (see `SeriesEdit.following_rule/3`).
  """
  @spec following_rule(map(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, :ends_before | :start_unknown}
  defdelegate following_rule(event, rule, zone), to: SeriesEdit

  @doc """
  Why a calendar of `provider` would refuse `rule` for a series starting on
  `start_date`, or `nil` (see `RepeatRefusal.reason/4`).
  """
  @spec repeat_refusal(atom() | String.t() | nil, String.t() | nil, Date.t(), String.t() | nil) ::
          RepeatRefusal.reason() | nil
  defdelegate repeat_refusal(provider, rule, start_date, timezone),
    to: RepeatRefusal,
    as: :reason

  @doc """
  The timing a timed event takes when it is drawn from one wall-clock minute
  to another in `timezone`: a move keeps its real length, a resize takes the
  drawn end. See `Tymeslot.CalendarGrid.Moves.resolve/4`.
  """
  @spec resolve_timing(map(), Moves.wall(), Moves.wall(), String.t()) ::
          {:ok, %{start_at: DateTime.t(), end_at: DateTime.t()}}
          | {:error, :invalid_time | :out_of_range}
  defdelegate resolve_timing(event, start_wall, end_wall, timezone), to: Moves, as: :resolve

  @doc """
  Whether the write queue is writing to another event of the series `event`
  belongs to. See `SeriesActivity.busy?/2`.
  """
  defdelegate series_busy?(queue, event), to: SeriesActivity, as: :busy?

  @doc """
  Blocks a stretch from bookings: a busy event on the organiser's default
  writable calendar that blocks availability, else time off. See
  `Tymeslot.CalendarGrid.BlockTime.block/4`.
  """
  @spec block_time(pos_integer(), DateTime.t(), DateTime.t(), String.t()) ::
          {:ok, BlockTime.blocked()} | {:error, BlockTime.refusal()}
  defdelegate block_time(user_id, start_at, end_at, title), to: BlockTime, as: :block

  @doc """
  Whether `start_at..end_at` is a span `block_time/4` takes. See
  `Tymeslot.CalendarGrid.BlockTime.check_span/2`.
  """
  @spec check_block_span(DateTime.t(), DateTime.t()) ::
          :ok | {:error, :invalid_range | :in_past | :too_long}
  defdelegate check_block_span(start_at, end_at), to: BlockTime, as: :check_span

  @doc """
  Takes back a block, for undo. See `Tymeslot.CalendarGrid.BlockTime.unblock/2`.
  """
  @spec unblock_time(pos_integer(), BlockTime.blocked()) :: :ok | {:error, term()}
  defdelegate unblock_time(user_id, result), to: BlockTime, as: :unblock

  @doc """
  Creates an event on one of the organiser's calendars, caches it so both
  calendars show it at once, and invites its guests. See
  `Tymeslot.CalendarGrid.NewEvent.create/2`.
  """
  @spec create_event(pos_integer(), CreateParams.t() | map()) ::
          {:ok, NewEvent.created()} | {:error, NewEvent.failure()}
  defdelegate create_event(user_id, payload), to: NewEvent, as: :create

  @doc "Caches a newly created event. See `Tymeslot.CalendarGrid.NewEvent.cache/1`."
  @spec cache_created_event(map()) :: :ok
  defdelegate cache_created_event(attrs), to: NewEvent, as: :cache

  @doc """
  Tells an event's guests what changed since `opened_with`, once the user
  is found to organise it on a calendar they can write. See
  `Tymeslot.CalendarGrid.GuestUpdate.tell/5`.
  """
  @spec tell_guests(pos_integer(), [map()], map(), map(), atom() | nil) ::
          {:ok, :sent | :noop} | {:error, GuestUpdate.refusal() | term()}
  defdelegate tell_guests(user_id, integrations, opened_with, event, scope),
    to: GuestUpdate,
    as: :tell
end
