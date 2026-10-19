defmodule Tymeslot.Integrations.Calendar.Blocking do
  @moduledoc """
  Writes to whether a calendar blocks availability (its
  `CalendarEntry.blocks_availability`), and the rule that a booking calendar
  always does.

  A calendar bookings are written to must block, or the host's own events in
  it would be ignored when slots are offered. A booking calendar is the one
  `Defaults.booking_target/1` names for an integration (its stored default,
  else the provider's primary) and any calendar a meeting type names as its
  `target_calendar_id`. So `set/3` refuses to make one show only, and choosing
  a calendar as a booking target (`promote_booking_target/3`,
  `set_default_booking_calendar/2`) makes it block in the same write. Nothing
  demotes it again: a calendar stays blocking when a meeting type stops
  naming it, or is deleted.

  ## Lock order

  Each write here holds its integration's row `FOR UPDATE`, the lock every
  selection write takes (`CalendarSelectionQueries.with_locked/2`, or
  `lock_stored/1` inside a meeting type's transaction, which must go on when
  the integration is gone). A meeting-type write that names a booking calendar
  runs `promote_booking_target/3` first, in its own transaction, so it locks:

    1. the user's row, `FOR KEY SHARE` (`CalendarIntegrationQueries.lock_owner/1`);
    2. the calendar integration's row, `FOR UPDATE`;
    3. the meeting type's row, by writing it.

  Deleting an integration locks its row before it clears the meeting types
  that name it, and deleting an account locks the user's row before its
  cascade reaches either, so neither can hold a meeting type this waits for.
  None of these take the integration cache lock or touch cached events;
  `IntegrationCacheQueries` documents that order, which a cache write meets
  only at the integration row and waits there.

  Every write that changes which calendars block drops the owner's cached
  availability once it commits, never before: a read in between would cache
  the old answer again. A write nested in a caller's transaction (a default
  booking calendar stored while `PrimaryElection` hands the primary on)
  leaves that to the caller, which commits.
  """

  alias Tymeslot.Availability
  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.CalendarSelectionQueries
  alias Tymeslot.Integrations.Calendar.Defaults
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Runtime.CalendarPathResolver
  alias Tymeslot.Integrations.Calendar.Selection
  alias Tymeslot.MeetingTypes.BookingCalendar
  alias Tymeslot.Utils.UriUtils

  @type integration :: CalendarIntegrationSchema.t()

  @typedoc """
  What the owner lets a calendar do: nothing (`:off`, not selected), appear
  in Tymeslot without taking slots (`:show`), or appear and take slots
  (`:block`).
  """
  @type state :: :off | :show | :block

  @typedoc "Why a change to a calendar's use is refused."
  @type refusal ::
          :not_found | :booking_calendar | :free_busy_only | :cannot_block | :not_exchange_main

  @doc """
  Sets whether the calendar `calendar_id` of `integration` blocks
  availability, leaving whether it is shown as it is. See `change/3` for
  the refusals.
  """
  @spec set(integration(), String.t() | integer(), boolean()) ::
          {:ok, integration()} | {:error, refusal() | term()}
  def set(integration, calendar_id, blocks?) when is_boolean(blocks?),
    do: change(integration, calendar_id, {:blocks, blocks?})

  @doc """
  Sets whether the calendar `calendar_id` of `integration` is used, and
  whether it blocks availability, in one write. See `change/3` for the
  refusals.
  """
  @spec set_state(integration(), String.t() | integer(), state()) ::
          {:ok, integration()} | {:error, refusal() | term()}
  def set_state(integration, calendar_id, state) when state in [:off, :show, :block],
    do: change(integration, calendar_id, {:state, state})

  @doc """
  Sets whether an Exchange mailbox's main calendar is shown, leaving whether
  it blocks as it is: its busy time blocks whether or not it is shown. Any
  other calendar is refused (`:not_exchange_main`); its use is `set_state/3`.
  """
  @spec set_shown(integration(), String.t() | integer(), boolean()) ::
          {:ok, integration()} | {:error, refusal() | term()}
  def set_shown(integration, calendar_id, shown?) when is_boolean(shown?),
    do: change(integration, calendar_id, {:shown, shown?})

  # Every write to a calendar's use runs here, under the integration's row
  # lock and against the row as it stands, so no change can reach a state
  # the rules refuse:
  #
  #   * a booking calendar always shows and blocks (`booking_calendar?/2`);
  #   * a calendar shared as busy times only has nothing to show, so it is
  #     off or blocking;
  #   * an Exchange mailbox's main calendar is shown and blocks apart (its
  #     busy time stands for the mailbox), and only it can be shown that
  #     way; the mailbox's other folders cannot block.
  defp change(%{id: id}, calendar_id, requested) do
    calendar_id = to_string(calendar_id)

    id
    |> CalendarSelectionQueries.with_locked(fn fresh ->
      with %CalendarEntry{} = entry <-
             find(fresh.calendar_list, calendar_id) || {:error, :not_found},
           :ok <- check(fresh, entry, requested) do
        Selection.persist_calendar_list(
          fresh,
          apply_change(fresh.calendar_list, entry.id, requested)
        )
      end
    end)
    |> invalidate_on_success()
  end

  defp check(integration, entry, change) do
    kind = kind(integration, entry)
    booking? = booking_calendar?(integration, entry.id)

    case change do
      {:shown, _shown?} when kind != :exchange_main -> {:error, :not_exchange_main}
      {:shown, _shown?} -> :ok
      {:state, :off} when kind == :exchange_main -> :ok
      {:state, :block} when kind == :exchange_folder -> {:error, :cannot_block}
      {:blocks, true} when kind == :exchange_folder -> {:error, :cannot_block}
      {:state, :block} -> :ok
      {:blocks, true} -> :ok
      _stops_blocking when booking? -> {:error, :booking_calendar}
      {:state, :off} -> :ok
      _shown_without_blocking when entry.free_busy_only -> {:error, :free_busy_only}
      _shown_without_blocking -> :ok
    end
  end

  defp kind(integration, entry) do
    cond do
      not ProviderConfig.ews?(integration.provider) -> :other
      entry.primary -> :exchange_main
      true -> :exchange_folder
    end
  end

  defp apply_change(calendar_list, calendar_id, change) do
    Enum.map(calendar_list, fn cal ->
      entry = CalendarEntry.normalize(cal)
      if entry.id == calendar_id, do: changed(entry, change), else: entry
    end)
  end

  defp changed(entry, {:state, :off}), do: %{entry | selected: false}

  defp changed(entry, {:state, state}),
    do: %{entry | selected: true, blocks_availability: state == :block}

  defp changed(entry, {:shown, shown?}), do: %{entry | selected: shown?}
  defp changed(entry, {:blocks, blocks?}), do: %{entry | blocks_availability: blocks?}

  @doc """
  Whether `entry` of `integration` blocks the booking page, for a surface
  that says so. An Exchange mailbox blocks through its main calendar alone,
  shown or not, and through the whole mailbox when it lists none (see
  `AvailabilityView`); any other calendar when it is used and set to block.
  """
  @spec blocks?(%{provider: String.t() | atom()}, CalendarEntry.t()) :: boolean()
  def blocks?(%{provider: provider} = integration, %CalendarEntry{} = entry) do
    cond do
      not ProviderConfig.ews?(provider) -> Selection.blocking?(entry)
      mailbox_without_main?(integration) -> true
      true -> entry.primary and entry.blocks_availability
    end
  end

  @doc """
  Whether `integration` is an Exchange mailbox that lists no main calendar:
  its busy time is then read for the whole mailbox and blocks, with no
  calendar to choose otherwise on.
  """
  @spec mailbox_without_main?(map()) :: boolean()
  def mailbox_without_main?(%{provider: provider} = integration) do
    ProviderConfig.ews?(provider) and
      not Enum.any?(Map.get(integration, :calendar_list) || [], & &1.primary)
  end

  @doc """
  The `t:state/0` an entry is in.
  """
  @spec state(CalendarEntry.t()) :: state()
  def state(%CalendarEntry{selected: false}), do: :off
  def state(%CalendarEntry{blocks_availability: false}), do: :show
  def state(%CalendarEntry{}), do: :block

  @doc """
  Whether `calendar_id` is a booking calendar of `integration`: the calendar
  bookings on it go to, or one a meeting type of its owner names.

  On an Exchange mailbox only the main calendar is held to the rule: busy
  time is read for the mailbox through it, and another folder cannot block
  whatever it is set to.
  """
  @spec booking_calendar?(integration(), String.t()) :: boolean()
  def booking_calendar?(integration, calendar_id),
    do: booking_calendar?(integration, booking_calendar_ids(integration), calendar_id)

  defp booking_calendar?(integration, booking_ids, calendar_id) do
    held_to_rule?(integration, calendar_id) and
      Enum.any?(booking_ids, &UriUtils.uri_safe_match?(&1, calendar_id))
  end

  @doc """
  Writes a whole new `calendar_list`, from a reconnect or a fresh discovery,
  with the credentials, default booking calendar and any other `attrs` that
  go with it, to the row as stored and under its lock
  (`CalendarSelectionQueries.with_locked_stored/2`), replacing the selection
  rather than merging it. A CalDAV-family integration's `calendar_paths` are
  derived from the list in the same write; any other keeps none.

  `build` may instead be a function of the locked row returning the
  `{calendar_list, attrs}` to write, for a caller whose choice depends on
  what the row holds: one read before a network call can be stale by the
  time it is written.

  A calendar of the list that is a booking calendar (`booking_calendar?/2`)
  is kept selected and blocking whatever the list says: one of the stored
  integration, as bookings still go to it, and the one bookings default to
  on the row as written, which the new list or `attrs` can move.
  """
  @spec replace_selection(integration(), [CalendarEntry.t()], map()) ::
          {:ok, integration()} | {:error, Ecto.Changeset.t() | :not_found}
  def replace_selection(integration, calendar_list, attrs) when is_map(attrs),
    do: replace_selection(integration, fn _stored -> {calendar_list, attrs} end)

  @spec replace_selection(integration(), (integration() -> {[CalendarEntry.t()], map()})) ::
          {:ok, integration()} | {:error, Ecto.Changeset.t() | :not_found}
  def replace_selection(%{id: id}, build) when is_function(build, 1) do
    id
    |> CalendarSelectionQueries.with_locked_stored(fn stored ->
      {calendar_list, attrs} = build.(stored)
      held = hold(stored, calendar_list, booking_calendar_ids(stored))
      # Holding it cannot move the pick: a CalDAV-family row picks among
      # the calendars already selected, any other by id or primary flag.
      written = written(stored, held, attrs)
      held = hold(written, held, default_booking_ids(written))

      Management.update_calendar_integration(
        stored,
        Map.merge(attrs, list_attrs(stored, held))
      )
    end)
    |> invalidate_on_success()
  end

  defp hold(integration, calendar_list, booking_ids) do
    Enum.map(calendar_list, fn entry ->
      if booking_calendar?(integration, booking_ids, entry.id),
        do: %{entry | selected: true, blocks_availability: true},
        else: entry
    end)
  end

  defp written(stored, calendar_list, attrs),
    do: struct(stored, Map.merge(attrs, list_attrs(stored, calendar_list)))

  defp list_attrs(integration, calendar_list) do
    if ProviderConfig.caldav_based?(integration.provider),
      do: Selection.calendar_list_attrs(calendar_list),
      else: %{calendar_list: calendar_list}
  end

  defp held_to_rule?(integration, calendar_id) do
    not ProviderConfig.ews?(integration.provider) or
      match?(%CalendarEntry{primary: true}, find(integration.calendar_list, calendar_id))
  end

  defp booking_calendar_ids(integration) do
    default_booking_ids(integration) ++
      BookingCalendar.ids(integration.user_id, integration.id)
  end

  # The calendar a booking on the integration goes to when nothing names one:
  # for a CalDAV-family integration the path the booking client resolves
  # (its stored booking calendar, else the first selected writable path),
  # for any other its stored booking calendar, else the provider's primary.
  defp default_booking_ids(integration) do
    if ProviderConfig.caldav_based?(integration.provider) do
      case CalendarPathResolver.resolve(integration) do
        nil -> []
        path -> [path]
      end
    else
      case Defaults.booking_target(integration) do
        {_writable, %CalendarEntry{id: id}} -> [id]
        :none -> []
      end
    end
  end

  @doc """
  Per integration id, the ids of its booking calendars (see
  `booking_calendar?/2`), for a page listing the user's `integrations`
  together. One query, whatever the number of integrations.
  """
  @spec booking_calendar_ids_by_integration(pos_integer(), [integration()]) ::
          %{pos_integer() => [String.t()]}
  def booking_calendar_ids_by_integration(user_id, integrations) do
    targets = BookingCalendar.ids_by_integration(user_id)

    Map.new(integrations, fn integration ->
      {integration.id,
       Enum.uniq(default_booking_ids(integration) ++ Map.get(targets, integration.id, []))}
    end)
  end

  @doc """
  Makes `calendar_id` of the user's integration `integration_id` block, as a
  meeting type is about to name it as its booking calendar. Call it inside
  the transaction that writes the meeting type, before that write (see the
  lock order in the moduledoc).

  `{:ok, :promoted}` when it changed the calendar, `{:ok, :unchanged}` when
  it already blocked, or when the integration or the calendar is gone (the
  meeting type's own validation answers for those), and `{:error, :not_found}`
  when the user is gone, their account deleted while this waited.
  """
  @spec promote_booking_target(pos_integer(), pos_integer(), String.t()) ::
          {:ok, :promoted | :unchanged} | {:error, term()}
  def promote_booking_target(user_id, integration_id, calendar_id) do
    with true <- CalendarIntegrationQueries.lock_owner(user_id),
         {:ok, %{user_id: ^user_id} = stored} <-
           CalendarSelectionQueries.lock_stored(integration_id) do
      promote(stored, calendar_id)
    else
      false -> {:error, :not_found}
      _gone_or_another_users -> {:ok, :unchanged}
    end
  end

  defp promote(fresh, calendar_id) do
    case find(fresh.calendar_list, calendar_id) do
      %CalendarEntry{blocks_availability: false} ->
        with {:ok, _updated} <-
               Selection.persist_calendar_list(fresh, put(fresh.calendar_list, calendar_id, true)),
             do: {:ok, :promoted}

      _blocking_or_unlisted ->
        {:ok, :unchanged}
    end
  end

  @doc """
  Stores `calendar_id` as the integration's default booking calendar, making
  it block in the same write. Read and written under the integration's row
  lock, so a selection changed meanwhile is kept.
  """
  @spec set_default_booking_calendar(integration(), String.t()) ::
          {:ok, integration()} | {:error, Ecto.Changeset.t() | :not_found | term()}
  def set_default_booking_calendar(%{id: id}, calendar_id) do
    id
    |> CalendarSelectionQueries.with_locked(fn fresh ->
      attrs =
        case find(fresh.calendar_list, calendar_id) do
          %CalendarEntry{blocks_availability: false} ->
            Selection.calendar_list_attrs(put(fresh.calendar_list, calendar_id, true))

          _blocking_or_unlisted ->
            %{}
        end

      Management.update_calendar_integration(
        fresh,
        Map.put(attrs, :default_booking_calendar_id, calendar_id)
      )
    end)
    |> invalidate_on_success()
  end

  defp find(calendar_list, calendar_id) do
    Enum.find(calendar_list || [], fn cal ->
      UriUtils.uri_safe_match?(CalendarEntry.normalize(cal).id, calendar_id)
    end)
  end

  defp put(calendar_list, calendar_id, blocks?) do
    Enum.map(calendar_list || [], fn cal ->
      entry = CalendarEntry.normalize(cal)

      if UriUtils.uri_safe_match?(entry.id, calendar_id),
        do: %{entry | blocks_availability: blocks?},
        else: entry
    end)
  end

  defp invalidate_on_success({:ok, %{user_id: user_id}} = ok) do
    unless CalendarIntegrationQueries.in_transaction?(),
      do: Availability.changed(user_id)

    ok
  end

  defp invalidate_on_success(error), do: error
end
