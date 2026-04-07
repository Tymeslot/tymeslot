defmodule Tymeslot.Integrations.Calendar.Events do
  @moduledoc """
  Public API for calendar event operations.

  Handles listing, creating, updating, and deleting calendar events.
  Adds context validation and normalisation before invoking the
  configured behaviour module (defaults to `Calendar.Operations`).
  """

  alias Tymeslot.DatabaseSchemas.MeetingSchema
  alias Tymeslot.DatabaseSchemas.MeetingTypeSchema
  alias Tymeslot.Integrations.Calendar.Runtime.EventQueries
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Utils.ContextUtils

  require Logger

  @type user_id :: pos_integer()
  @type create_context :: user_id() | MeetingSchema.t() | MeetingTypeSchema.t() | nil
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
      id when is_integer(id) and id > 0 -> EventQueries.list_events(id)
      nil -> EventQueries.list_events(nil)
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
  Get events for a month with user context (preferred variant).
  """
  @spec get_events_for_month(user_id(), pos_integer(), pos_integer(), String.t()) ::
          {:ok, list()} | {:error, term()}
  def get_events_for_month(user_id, year, month, timezone)
      when is_integer(user_id) and is_integer(year) and is_integer(month) and is_binary(timezone) do
    behaviour_module().get_events_for_month(user_id, year, month, timezone)
  end

  @doc """
  Backward-compatible variant without explicit user context.
  """
  @spec get_events_for_month(pos_integer(), pos_integer(), String.t()) ::
          {:ok, list()} | {:error, term()}
  def get_events_for_month(_year, _month, _timezone),
    do: {:error, :user_id_required}

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
  @spec create_event(calendar_event_data(), create_context()) :: {:ok, map()} | {:error, term()}
  def create_event(event_data, context \\ nil) do
    case context do
      id when is_integer(id) and id > 0 ->
        behaviour_module().create_event(event_data, id)

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
  def update_event(uid, event_data, context \\ nil) do
    behaviour_module().update_event(uid, event_data, context)
  end

  @doc """
  Delete an event with optional target integration, meeting context, or user_id.
  """
  @spec delete_event(
          String.t(),
          pos_integer() | MeetingSchema.t() | {pos_integer(), pos_integer()} | nil
        ) ::
          :ok | {:error, term()}
  def delete_event(uid, context \\ nil) do
    behaviour_module().delete_event(uid, context)
  end

  @doc """
  Get a single event by UID.
  """
  @spec get_event(String.t(), user_id() | nil) :: {:ok, map()} | {:error, :not_found | term()}
  def get_event(uid, user_id \\ nil), do: behaviour_module().get_event(uid, user_id)

  @doc """
  Returns the booking calendar integration info for a user or meeting type (id and path) used for event creation.
  """
  @spec get_booking_integration_info(
          pos_integer()
          | Tymeslot.DatabaseSchemas.MeetingTypeSchema.t()
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
        {today, Date.add(today, profile.advance_booking_days)}

      {:error, _reason} ->
        today = Date.utc_today()
        {today, Date.add(today, 30)}
    end
  end
end
