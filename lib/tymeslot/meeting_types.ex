defmodule Tymeslot.MeetingTypes do
  @moduledoc """
  Context for managing meeting types.
  """
  alias Tymeslot.BookingPage.Publication
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.CalendarPrimary
  alias Tymeslot.MeetingTypes.Duration
  alias Tymeslot.MeetingTypes.FormMapper
  alias Tymeslot.MeetingTypes.FormValidation
  alias Tymeslot.MeetingTypes.MeetingTypeQueries
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.MeetingTypes.Slugs
  require Logger

  @doc """
  Gets all active meeting types for a user, creating defaults if none exist.
  """
  @spec get_active_meeting_types(integer()) :: [Ecto.Schema.t()]
  def get_active_meeting_types(user_id) do
    list_seeding_defaults(user_id, &MeetingTypeQueries.list_active_meeting_types/1)
  end

  @doc """
  Gets all meeting types for a user (active and inactive).
  """
  @spec get_all_meeting_types(integer()) :: [Ecto.Schema.t()]
  def get_all_meeting_types(user_id) do
    list_seeding_defaults(user_id, &MeetingTypeQueries.list_all_meeting_types/1)
  end

  @doc """
  Gets the publicly listed meeting types for a user (active and not private).
  This feeds the public booking overview; private types are excluded and
  reachable only by their direct link.

  Deliberately a pure read: unlike the two owner-facing listings above it never
  seeds the default meeting types. An anonymous page view must not write to the
  host's account, and a host with no meeting types must show the booking page's
  empty state rather than be given two bookable durations they never created
  (which would also silently resurrect defaults a host had deleted on purpose).
  """
  @spec get_public_meeting_types(integer()) :: [Ecto.Schema.t()]
  def get_public_meeting_types(user_id) do
    MeetingTypeQueries.list_public_meeting_types(user_id)
  end

  # The two owner-facing listings above differ only in which query they run;
  # each seeds the user's default meeting types first if they have none yet.
  # The public listing deliberately does not go through here.
  defp list_seeding_defaults(user_id, list_fun) do
    ensure_default_meeting_types(user_id)
    list_fun.(user_id)
  end

  defp ensure_default_meeting_types(user_id) do
    if MeetingTypeQueries.has_meeting_types?(user_id) do
      :ok
    else
      Logger.info("Creating default meeting types for user", user_id: user_id)
      create_default_meeting_types(user_id)
      :ok
    end
  end

  @doc """
  Gets a meeting type by ID and user ID.
  """
  @spec get_meeting_type(integer(), integer()) :: Ecto.Schema.t() | nil
  def get_meeting_type(id, user_id) do
    MeetingTypeQueries.get_meeting_type(id, user_id)
  end

  @doc """
  Returns true if the user has at least one active meeting type.
  """
  @spec has_active_meeting_types?(integer()) :: boolean()
  def has_active_meeting_types?(user_id) do
    MeetingTypeQueries.has_active_meeting_types?(user_id)
  end

  @doc """
  Creates a new meeting type.

  `opts` are forwarded to the changeset for payment-validation context.
  """
  @spec create_meeting_type(map(), keyword()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def create_meeting_type(attrs, opts \\ []) do
    with {:ok, meeting_type} <- MeetingTypeQueries.create_meeting_type(attrs, opts) do
      Publication.maybe_publish(meeting_type.user_id)
      {:ok, meeting_type}
    end
  end

  @doc """
  Updates a meeting type.

  `opts` are forwarded to the changeset for payment-validation context.
  """
  @spec update_meeting_type(Ecto.Schema.t(), map(), keyword()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def update_meeting_type(meeting_type, attrs, opts \\ []) do
    with {:ok, updated} <- MeetingTypeQueries.update_meeting_type(meeting_type, attrs, opts) do
      Publication.maybe_publish(updated.user_id)
      # Offered slots are cached per meeting type, and an edit can change which
      # availability schedule the type resolves to, so the cached answer must go.
      AvailabilityCache.invalidate_for_user(updated.user_id)
      {:ok, updated}
    end
  end

  @doc """
  Toggles the active status of a meeting type without validating video integration.
  """
  @spec toggle_meeting_type_status(Ecto.Schema.t(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def toggle_meeting_type_status(meeting_type, attrs) do
    with {:ok, updated} <- MeetingTypeQueries.toggle_meeting_type_status(meeting_type, attrs) do
      Publication.maybe_publish(updated.user_id)
      {:ok, updated}
    end
  end

  @doc """
  Deletes a meeting type.
  """
  @spec delete_meeting_type(Ecto.Schema.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def delete_meeting_type(meeting_type) do
    MeetingTypeQueries.delete_meeting_type(meeting_type)
  end

  @doc """
  Sets whether a meeting type is private. A private type is excluded from the
  organiser's public booking page but stays reachable by its direct link.
  """
  @spec set_private(Ecto.Schema.t(), boolean()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def set_private(meeting_type, is_private) when is_boolean(is_private) do
    MeetingTypeQueries.set_visibility(meeting_type, %{is_private: is_private})
  end

  @doc """
  Toggles the active status of a meeting type.
  """
  @spec toggle_meeting_type(integer(), integer()) ::
          {:ok, Ecto.Schema.t()} | {:error, atom() | Ecto.Changeset.t()}
  def toggle_meeting_type(id, user_id) do
    case get_meeting_type(id, user_id) do
      nil ->
        {:error, :not_found}

      meeting_type ->
        update_meeting_type(meeting_type, %{is_active: !meeting_type.is_active})
    end
  end

  @doc """
  Reorders meeting types for a user.
  """
  @spec reorder_meeting_types(integer(), [integer()]) :: {:ok, any()} | {:error, any()}
  def reorder_meeting_types(user_id, meeting_type_ids) when is_list(meeting_type_ids) do
    MeetingTypeQueries.reorder_meeting_types(user_id, meeting_type_ids)
  end

  # Slug resolution and custom-slug management live in the focused sibling
  # module Tymeslot.MeetingTypes.Slugs; these delegations keep the context's
  # public API stable.
  defdelegate find_by_slug(user_id, slug), to: Slugs
  defdelegate effective_slug(meeting_type), to: Slugs
  defdelegate to_slug(meeting_type), to: Slugs
  defdelegate to_duration_string(meeting_type), to: Slugs
  defdelegate generate_random_slug(user_id), to: Slugs
  defdelegate normalize_slug(slug), to: Slugs
  defdelegate update_slug(meeting_type, slug), to: Slugs

  # Duration parsing, normalisation, and booking-flow validation live in the
  # focused sibling module Tymeslot.MeetingTypes.Duration; these delegations
  # keep the context's public API stable.
  defdelegate normalize_duration_slug(duration), to: Duration
  defdelegate find_by_duration_string(user_id, slug), to: Duration
  defdelegate validate_duration_selection(duration, available_types), to: Duration
  defdelegate duration_valid?(duration, available_types), to: Duration

  @doc """
  Lists all meeting types for a user.
  """
  @spec list_meeting_types(integer()) :: [Ecto.Schema.t()]
  def list_meeting_types(user_id) do
    get_all_meeting_types(user_id)
  end

  @doc """
  Gets a meeting type by ID, raising if not found.
  """
  @spec get_meeting_type!(integer()) :: Ecto.Schema.t()
  def get_meeting_type!(id) do
    MeetingTypeQueries.get_meeting_type!(id)
  end

  @doc """
  Creates a meeting type from form parameters with validation.
  """
  @spec create_meeting_type_from_form(integer(), map(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, atom() | Ecto.Changeset.t()}
  def create_meeting_type_from_form(user_id, form_params, ui_state) do
    with {:ok, attrs} <- FormMapper.build_attrs(form_params, ui_state),
         :ok <- FormValidation.check(user_id, attrs) do
      create_meeting_type(Map.put(attrs, :user_id, user_id), FormMapper.payment_opts(user_id))
    end
  end

  @doc """
  Updates a meeting type from form parameters with validation.
  """
  @spec update_meeting_type_from_form(Ecto.Schema.t(), map(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, atom() | Ecto.Changeset.t()}
  def update_meeting_type_from_form(meeting_type, form_params, ui_state) do
    user_id = meeting_type.user_id

    with {:ok, attrs} <- FormMapper.build_attrs(form_params, ui_state),
         :ok <- FormValidation.check(user_id, attrs) do
      update_meeting_type(meeting_type, attrs, FormMapper.payment_opts(user_id))
    end
  end

  @doc """
  Creates default meeting types for a new user.
  Fetches the user's primary calendar integration, builds default templates,
  deduplicates against existing names, then bulk-inserts.
  """
  @spec create_default_meeting_types(integer()) ::
          {:ok, [MeetingTypeSchema.t()]} | {:error, term()}
  def create_default_meeting_types(user_id) when is_integer(user_id) do
    {calendar_integration_id, target_calendar_id} = resolve_primary_calendar(user_id)
    existing = MeetingTypeQueries.existing_names(user_id)
    now = DateTime.utc_now(:second)

    result =
      user_id
      |> default_meeting_type_templates(calendar_integration_id, target_calendar_id, now)
      |> Enum.reject(fn type -> MapSet.member?(existing, type.name) end)
      |> MeetingTypeQueries.bulk_insert_meeting_types()

    with {:ok, _meeting_types} <- result do
      Publication.maybe_publish(user_id)
    end

    result
  end

  @spec create_default_meeting_types(term()) :: {:error, :invalid_user_id}
  def create_default_meeting_types(_invalid_user_id), do: {:error, :invalid_user_id}

  # Private functions

  defp resolve_primary_calendar(user_id) do
    case CalendarPrimary.get_primary_calendar_integration(user_id) do
      {:ok, %{default_booking_calendar_id: cal_id} = integration}
      when is_binary(cal_id) ->
        {integration.id, cal_id}

      _other ->
        {nil, nil}
    end
  end

  defp default_meeting_type_templates(
         user_id,
         calendar_integration_id,
         target_calendar_id,
         now
       ) do
    [
      %{
        user_id: user_id,
        name: "15 Minutes",
        description: "Quick chat or brief consultation",
        duration_minutes: 15,
        icon: "hero-bolt",
        sort_order: 0,
        is_active: true,
        allow_video: false,
        calendar_integration_id: calendar_integration_id,
        target_calendar_id: target_calendar_id,
        reminder_config: [%{value: 30, unit: "minutes"}],
        inserted_at: now,
        updated_at: now
      },
      %{
        user_id: user_id,
        name: "30 Minutes",
        description: "In-depth discussion or detailed review",
        duration_minutes: 30,
        icon: "hero-rocket-launch",
        sort_order: 1,
        is_active: true,
        allow_video: false,
        calendar_integration_id: calendar_integration_id,
        target_calendar_id: target_calendar_id,
        reminder_config: [%{value: 30, unit: "minutes"}],
        inserted_at: now,
        updated_at: now
      }
    ]
  end
end
