defmodule Tymeslot.Integrations.Calendar.Events do
  @moduledoc """
  Public API for calendar event operations.

  Handles listing, creating, updating, and deleting calendar events.
  Adds context validation and normalisation before invoking the
  configured behaviour module (defaults to `Calendar.Operations`).
  """

  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Integrations.Calendar.CalDAV.QueueWiring
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Integrations.Calendar.Runtime.EventFetcher
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Utils.ContextUtils

  require Logger

  # Failures a later replay cannot recover: queueing them would only keep a
  # dead row in the offline queue.
  @non_queueable_errors [:unauthorized, :not_found, :meeting_not_found, :rate_limited]

  @type user_id :: pos_integer()
  @type integration_id :: pos_integer()
  @type create_context :: write_context()
  @type write_context ::
          user_id()
          | {integration_id(), user_id()}
          | MeetingSchema.t()
          | MeetingTypeSchema.t()
          | nil
  @type calendar_event_data :: %{
          required(:summary) => String.t(),
          required(:start_time) => DateTime.t(),
          required(:end_time) => DateTime.t(),
          optional(:location) => String.t(),
          optional(atom()) => term()
        }

  # ---------------------------
  # Queries
  # ---------------------------

  @doc """
  List events for a user. If user_id is nil, falls back to runtime behavior.
  """
  @spec list_events(user_id() | nil) :: {:ok, list()} | {:error, term()}
  def list_events(user_id \\ nil) do
    case user_id do
      id when is_integer(id) and id > 0 -> EventFetcher.list_events(id)
      nil -> EventFetcher.list_events(nil)
      _other -> {:error, :invalid_user_id}
    end
  end

  @doc """
  Fetch calendar events for the user's entire booking window.

  This ensures that all events within the advance booking period are available
  for conflict checking, not just the current month.

  Falls back to list_events if profile cannot be loaded.
  """
  @spec get_calendar_events(Date.t() | any(), user_id(), keyword()) ::
          {:ok, list()} | {:error, term()}
  def get_calendar_events(_date, organizer_user_id, opts \\ []) do
    debug_module = Keyword.get(opts, :debug_calendar_module)

    cond do
      is_function(debug_module, 1) ->
        debug_module.(organizer_user_id)

      is_atom(debug_module) && debug_module != nil ->
        {start_date, end_date} = calculate_booking_window_range(organizer_user_id, opts)
        debug_module.get_events_for_range_fresh(organizer_user_id, start_date, end_date)

      true ->
        fetch_events_for_booking_window(organizer_user_id)
    end
  end

  @doc """
  Compatibility: context-aware variant that extracts a debug calendar module and organizer profile if present.
  """
  @spec get_calendar_events_from_context(
          any(),
          user_id(),
          %{
            optional(:debug_calendar_module) => module() | nil,
            optional(:organizer_profile) => map() | nil
          }
          | nil
        ) ::
          {:ok, list()} | {:error, term()}
  def get_calendar_events_from_context(date, organizer_user_id, context) do
    debug_module =
      if val = ContextUtils.get_from_context(context, :debug_calendar_module) do
        val
      else
        Application.get_env(:tymeslot, :calendar_module)
      end

    opts = [
      debug_calendar_module: debug_module,
      organizer_profile: ContextUtils.get_from_context(context, :organizer_profile)
    ]

    get_calendar_events(date, organizer_user_id, opts)
  end

  @doc """
  Get fresh events for range with user context (preferred variant).
  """
  @spec get_events_for_range_fresh(user_id(), Date.t(), Date.t()) ::
          {:ok, list()} | {:error, term()}
  def get_events_for_range_fresh(user_id, start_date, end_date)
      when is_integer(user_id) do
    behaviour_module().get_events_for_range_fresh(user_id, start_date, end_date)
  end

  # ---------------------------
  # CRUD
  # ---------------------------

  @doc """
  Create an event using the user's booking calendar.

  Accepts a user_id, Meeting, or MeetingType to determine the target calendar.
  If a Meeting or MeetingType is provided, uses their configured calendar integration.
  Falls back to the user's primary calendar if not specified.
  """
  @spec create_event(calendar_event_data(), create_context()) ::
          {:ok, CreatedEvent.t()} | {:error, term()}
  def create_event(event_data, context) do
    case context do
      id when is_integer(id) and id > 0 ->
        behaviour_module().create_event(event_data, id)

      {integration_id, user_id}
      when is_integer(integration_id) and integration_id > 0 and
             is_integer(user_id) and user_id > 0 ->
        behaviour_module().create_event(event_data, {integration_id, user_id})

      %MeetingSchema{} = meeting ->
        behaviour_module().create_event(event_data, meeting)

      %MeetingTypeSchema{} = meeting_type ->
        behaviour_module().create_event(event_data, meeting_type)

      nil ->
        behaviour_module().create_event(event_data, nil)

      _other ->
        {:error, :invalid_context}
    end
  end

  @doc """
  Update an event with optional target integration, meeting context, or user_id.
  """
  @spec update_event(
          String.t(),
          map(),
          pos_integer() | MeetingSchema.t() | {pos_integer(), pos_integer()} | nil
        ) ::
          :ok | {:error, term()}
  def update_event(uid, event_data, context) do
    behaviour_module().update_event(uid, event_data, context)
  end

  @doc """
  Delete an event with optional target integration, meeting context, or user_id.

  `opts` reach the provider unchanged; pass `provider_event_id:` when the
  event is addressed by its provider-native id rather than its iCal UID.
  """
  @spec delete_event(String.t(), write_context(), keyword()) :: :ok | {:error, term()}
  def delete_event(uid, context \\ nil, opts \\ []) do
    behaviour_module().delete_event(uid, context, opts)
  end

  @doc """
  Deletes an event on the provider, then reconciles any Tymeslot meeting
  linked to it as externally deleted.

  The linked meeting is looked up before the delete, so its attendee email
  can still be reported once the reconciliation has cancelled it. Nothing is
  reconciled when the delete fails.

  Returns `{:ok, result}` where `result` carries `:uid`, `:integration_id`,
  `:reconcile_result` and, when a meeting was linked, `:meeting_attendee_email`.

  An `{:error, _}` return means the provider refused the delete and the event
  is still on the calendar. A reconciliation that fails once the event is
  gone is not that: it is reported in `:reconcile_result`, whether it came
  back as an error or blew up, so callers can tell the organiser their
  booking may still stand rather than that the delete failed.
  """
  @spec delete_event_and_reconcile(
          String.t(),
          String.t() | nil,
          {integration_id(), user_id()},
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def delete_event_and_reconcile(
        uid,
        provider_event_id,
        {integration_id, _user_id} = context,
        opts
      ) do
    linked_meeting = Sync.find_meeting(integration_id, provider_event_id, uid)

    with :ok <- delete_event(uid, context, opts) do
      reconcile_result = reconcile_deleted(integration_id, provider_event_id, uid)
      result = %{uid: uid, integration_id: integration_id, reconcile_result: reconcile_result}

      case linked_meeting do
        {:ok, meeting} -> {:ok, Map.put(result, :meeting_attendee_email, meeting.attendee_email)}
        {:error, :not_found} -> {:ok, result}
      end
    end
  end

  # The event is already off the calendar by the time this runs, so a raise
  # here must not escape as a failed delete: the caller would report an event
  # that no longer exists as still needing deleting, and say nothing about the
  # booking that was left standing. Reported as a failed reconciliation
  # instead, which is what it is.
  defp reconcile_deleted(integration_id, provider_event_id, uid) do
    Sync.reconcile(integration_id, provider_event_id, uid, :deleted)
  rescue
    error ->
      Logger.error("Reconciliation crashed after the calendar event was deleted",
        calendar_integration_id: integration_id,
        provider_event_id: provider_event_id,
        uid: uid,
        error: Exception.format(:error, error, __STACKTRACE__)
      )

      {:error, error}
  end

  @doc """
  Whether a calendar event is linked to a Tymeslot meeting, matched by
  provider event id first and iCal UID second.
  """
  @spec event_linked_to_booking?(integration_id(), String.t() | nil, String.t() | nil) ::
          boolean()
  def event_linked_to_booking?(integration_id, provider_event_id, uid) do
    match?({:ok, _meeting}, Sync.find_meeting(integration_id, provider_event_id, uid))
  end

  @doc """
  Queues a failed write on `target` for replay on the next sync cycle.

  `target` names the event (`:uid` and `:calendar_integration_id`) and
  `event_data` carries the fields needed to rebuild the write. Returns `:ok`
  when the write was queued, or `:ignored` when the integration has no
  offline queue (every provider outside the CalDAV family).

  Callers should consult `queueable_error?/1` first: a failure a retry cannot
  recover would only leave a dead row in the queue.
  """
  @spec queue_for_offline_retry(QueueWiring.meeting(), QueueWiring.action(), map()) ::
          :ok | :ignored
  def queue_for_offline_retry(target, action, event_data) do
    QueueWiring.tag(target, action, event_data)
  end

  @doc """
  Whether a failed calendar write is worth queueing for a later retry.

  Authorisation failures, missing events or meetings, and rate limiting are
  not: replaying the same write cannot succeed, or must wait on the
  provider's own retry schedule rather than the next sync cycle.
  """
  @spec queueable_error?(term()) :: boolean()
  def queueable_error?(reason) when reason in @non_queueable_errors, do: false
  def queueable_error?(_reason), do: true

  @doc """
  Returns the booking calendar integration info for a user or meeting type (id and path) used for event creation.
  """
  @spec get_booking_integration_info(
          pos_integer()
          | Tymeslot.MeetingTypes.MeetingTypeSchema.t()
        ) ::
          {:ok, %{integration_id: pos_integer(), calendar_path: String.t()}} | {:error, term()}
  def get_booking_integration_info(context) do
    behaviour_module().get_booking_integration_info(context)
  end

  # --- Private helpers ---

  defp behaviour_module do
    mod =
      Application.get_env(
        :tymeslot,
        :calendar_module,
        Tymeslot.Integrations.Calendar.Operations
      )

    if Code.ensure_loaded?(mod) do
      mod
    else
      Logger.warning("Configured calendar_module is not loaded, falling back to Operations",
        calendar_module: inspect(mod)
      )

      Tymeslot.Integrations.Calendar.Operations
    end
  end

  @spec fetch_events_for_booking_window(user_id()) :: {:ok, list()} | {:error, term()}
  defp fetch_events_for_booking_window(user_id) do
    {start_date, end_date} = calculate_booking_window_range(user_id)

    case ProfileQueries.get_by_user_id(user_id) do
      {:ok, _profile} ->
        get_events_for_range_fresh(user_id, start_date, end_date)

      {:error, _reason} ->
        list_events(user_id)
    end
  end

  defp calculate_booking_window_range(user_id, opts \\ []) do
    profile_result =
      case Keyword.get(opts, :organizer_profile) do
        %{} = profile -> {:ok, profile}
        nil -> ProfileQueries.get_by_user_id(user_id)
      end

    case profile_result do
      {:ok, profile} ->
        today = Date.utc_today()
        {today, Date.add(today, booking_window_days(profile))}

      {:error, _reason} ->
        today = Date.utc_today()
        {today, Date.add(today, 30)}
    end
  end

  # The prefetch range must cover the furthest date any of the host's schedules
  # can be booked into: a meeting type on a longer window than the default would
  # otherwise offer slots for dates this range never fetched events for.
  defp booking_window_days(%{id: profile_id}) when is_integer(profile_id) do
    profile_id
    |> Schedules.list_for_profile()
    |> Enum.map(& &1.advance_booking_days)
    |> Enum.max(fn -> 90 end)
  end

  defp booking_window_days(_profile), do: 90
end
