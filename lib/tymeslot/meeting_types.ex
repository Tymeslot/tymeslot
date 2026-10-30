defmodule Tymeslot.MeetingTypes do
  @moduledoc """
  Context for managing meeting types.
  """
  alias Tymeslot.Availability
  alias Tymeslot.BookingPage.Publication
  alias Tymeslot.Clock
  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.PlannedSessions
  alias Tymeslot.MeetingTypes.BookingCalendar
  alias Tymeslot.MeetingTypes.Defaults
  alias Tymeslot.MeetingTypes.Duration
  alias Tymeslot.MeetingTypes.FixedDates
  alias Tymeslot.MeetingTypes.FormMapper
  alias Tymeslot.MeetingTypes.FormValidation
  alias Tymeslot.MeetingTypes.GroupAccess
  alias Tymeslot.MeetingTypes.LocationChoices
  alias Tymeslot.MeetingTypes.LocationOption
  alias Tymeslot.MeetingTypes.LocationSelection
  alias Tymeslot.MeetingTypes.MeetingTypeQueries
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.MeetingTypes.OneOffEvents
  alias Tymeslot.MeetingTypes.PaymentAccess
  alias Tymeslot.MeetingTypes.ReminderValidation
  alias Tymeslot.MeetingTypes.Slugs
  alias Tymeslot.Repo
  alias Tymeslot.Utils.UriUtils
  alias Tymeslot.Venues

  @doc """
  The locations this meeting type offers, in the host's order.

  See `Tymeslot.MeetingTypes.LocationSelection` for what a meeting type
  with no stored list falls back to.
  """
  @spec location_options(map() | nil) :: [LocationOption.t()]
  defdelegate location_options(meeting_type), to: LocationSelection, as: :options

  @doc """
  Whether `meeting_type` lets several people book the same slot. Anything
  that is not a stored meeting type (`nil`, a demo's plain-map type) is not.
  """
  @spec group_type?(MeetingTypeSchema.t() | map() | nil) :: boolean()
  defdelegate group_type?(meeting_type), to: MeetingTypeSchema, as: :group?

  @doc """
  Resolves a booker's location choice into the meeting fields that follow
  from it, honouring only what the host's current integrations and venues
  still offer; see `Tymeslot.MeetingTypes.LocationChoices.resolve_location/2`.
  """
  @spec resolve_location(map() | nil, LocationChoices.location_choice()) ::
          LocationSelection.resolution()
  defdelegate resolve_location(meeting_type, choice), to: LocationChoices

  @doc """
  The video providers the booker can pick between, per video location; see
  `Tymeslot.MeetingTypes.LocationChoices.location_video_choices/1`.
  """
  @spec location_video_choices(map() | nil) :: %{
          String.t() => [%{id: integer(), name: String.t(), provider: String.t()}]
        }
  defdelegate location_video_choices(meeting_type), to: LocationChoices

  @doc """
  The venues the booker can pick between, per in-person location; see
  `Tymeslot.MeetingTypes.LocationChoices.location_venue_choices/1`.
  """
  @spec location_venue_choices(map() | nil) :: %{String.t() => [Venues.choice()]}
  defdelegate location_venue_choices(meeting_type), to: LocationChoices

  @doc """
  Gets all active meeting types for a user. A pure read: a host may have
  none (the defaults are seeded once, with the profile; see
  `seed_default_meeting_types/2`).
  """
  @spec get_active_meeting_types(integer()) :: [Ecto.Schema.t()]
  def get_active_meeting_types(user_id),
    do: MeetingTypeQueries.list_active_meeting_types(user_id)

  @doc """
  Gets all meeting types for a user (active and inactive). A pure read, like
  `get_active_meeting_types/1`.
  """
  @spec get_all_meeting_types(integer()) :: [Ecto.Schema.t()]
  def get_all_meeting_types(user_id), do: MeetingTypeQueries.list_all_meeting_types(user_id)

  @doc """
  Gets the publicly listed meeting types for a user (active and not private).
  This feeds the public booking overview; private types are excluded and
  reachable only by their direct link.

  A pure read, like the two owner-facing listings above: a host with no
  meeting types shows the booking page's empty state.

  A paused group type (`Tymeslot.MeetingTypes.GroupAccess`) is left out, as an
  inactive one is: it takes no new bookings, so the page must not offer it. So
  is a fixed-date type with no session left to sign up for
  (`Tymeslot.MeetingTypes.FixedDates.reject_unbookable/1`), and so is a paid
  type while its host is not accepting payments
  (`Tymeslot.MeetingTypes.PaymentAccess`), since its booking could never be
  submitted.
  """
  @spec get_public_meeting_types(integer()) :: [Ecto.Schema.t()]
  def get_public_meeting_types(user_id) do
    user_id
    |> MeetingTypeQueries.list_public_meeting_types()
    |> GroupAccess.reject_paused()
    |> FixedDates.reject_unbookable()
    |> PaymentAccess.reject_unsellable()
    |> OneOffEvents.order_for_listing()
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
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def create_meeting_type(attrs, opts \\ []) do
    result =
      Repo.transaction(fn ->
        changeset = MeetingTypeSchema.changeset(%MeetingTypeSchema{}, attrs, opts)

        with {:ok, promotion} <- BookingCalendar.promote(changeset),
             {:ok, meeting_type} <- MeetingTypeQueries.create_meeting_type(attrs, opts) do
          {meeting_type, promotion}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    with {:ok, {meeting_type, promotion}} <- result do
      if promotion == :promoted, do: invalidate_after_commit(meeting_type.user_id)
      Publication.maybe_publish(meeting_type.user_id)
      {:ok, meeting_type}
    end
  end

  @doc """
  Updates a meeting type.

  `opts` are forwarded to the changeset for payment-validation context.
  """
  @spec update_meeting_type(Ecto.Schema.t(), map(), keyword()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def update_meeting_type(meeting_type, attrs, opts \\ []) do
    case Repo.transaction(fn -> do_update_meeting_type(meeting_type, attrs, opts) end) do
      {:ok, updated} ->
        Publication.maybe_publish(updated.user_id)
        maybe_broadcast_seat_change(meeting_type, updated)
        # Offered slots are cached per meeting type, and an edit can change which
        # availability schedule the type resolves to, so the cached answer must go.
        invalidate_after_commit(updated.user_id)
        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_update_meeting_type(meeting_type, attrs, opts) do
    changeset = MeetingTypeSchema.changeset(meeting_type, attrs, opts)

    with :ok <- FixedDates.check_sessions_kept(meeting_type, changeset),
         {:ok, _promotion} <- BookingCalendar.promote(changeset),
         {:ok, updated} <- MeetingTypeQueries.update_meeting_type(meeting_type, attrs, opts) do
      sync_group_capacity(meeting_type, updated)
      updated
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Capacity follows the type: a new seat limit above one applies to the
  # type's future group meetings, in the same transaction as the type itself.
  # A limit below the seats already taken on a meeting leaves that meeting
  # exactly full rather than over capacity, and nobody is cancelled. Solo bookings are never touched, so a
  # one-to-one booking stays private when its type becomes a group type.
  # Turning group bookings off (a limit of one) leaves existing group
  # meetings' capacity alone; they keep their seats but take no new joins,
  # because joins and availability check the type as well.
  defp sync_group_capacity(%{max_participants: before}, %{max_participants: now} = updated)
       when now > 1 and before != now do
    Meetings.set_future_group_capacity(updated.id, now, Clock.utc_now())
  end

  defp sync_group_capacity(_before, _updated), do: 0

  defp maybe_broadcast_seat_change(%{max_participants: same}, %{max_participants: same}), do: :ok

  defp maybe_broadcast_seat_change(_before, updated),
    do: Meetings.broadcast_seat_change(updated.id)

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

  A fixed-date type's upcoming dates are cancelled first, through the host's
  own cancel path, which tells everyone booked on them
  (`Tymeslot.Meetings.PlannedSessions.cancel/2`): deleted with the type, they
  would stay on the calendar and in people's diaries with nothing left to
  manage them from. Should a cancellation fail, the type is kept, so the
  host can try again. `upcoming_sign_ups/1` is what the confirmation shows.
  """
  @spec delete_meeting_type(Ecto.Schema.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t() | term()}
  def delete_meeting_type(meeting_type) do
    with :ok <- cancel_planned_sessions(meeting_type) do
      MeetingTypeQueries.delete_meeting_type(meeting_type)
    end
  end

  @doc """
  The upcoming planned dates of `meeting_type` and how many people are
  booked on them, which deleting the type cancels: `{dates, people}`.
  `{0, 0}` for a type without fixed dates.
  """
  @spec upcoming_sign_ups(map()) :: {non_neg_integer(), non_neg_integer()}
  def upcoming_sign_ups(meeting_type) do
    sessions = PlannedSessions.upcoming(meeting_type)
    {length(sessions), sessions |> Enum.map(&PlannedSessions.participant_count/1) |> Enum.sum()}
  end

  defp cancel_planned_sessions(meeting_type) do
    meeting_type
    |> PlannedSessions.upcoming()
    |> Enum.reduce_while(:ok, fn session, :ok ->
      case PlannedSessions.cancel(session, meeting_type.user_id) do
        {:ok, _cancelled} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
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
  Reorders meeting types for a user.
  """
  @spec reorder_meeting_types(integer(), [integer()]) :: {:ok, any()} | {:error, any()}
  def reorder_meeting_types(user_id, meeting_type_ids) when is_list(meeting_type_ids) do
    MeetingTypeQueries.reorder_meeting_types(user_id, meeting_type_ids)
  end

  @typedoc """
  The health of a meeting type's stored booking target, as of the last
  calendar list refresh.
  """
  @type target_calendar_status :: :ok | :read_only | :missing

  @doc """
  Reports whether the calendar a meeting type books into can still take a
  booking.

  A meeting type may override where its bookings land
  (`calendar_integration_id` plus `target_calendar_id`), and the override is
  chosen once and then used for every booking of that type. The provider can
  withdraw write access at any point afterwards: a shared Google calendar
  downgraded to "see all event details", a CalDAV collection made read-only,
  a calendar deleted outright. Saving the meeting type again would be
  rejected (`Tymeslot.MeetingTypes.FormValidation`), but nothing forces the
  host to save it again, so the dashboard uses this to say so unprompted.

  Returns:

    * `:ok` — the target is still writable, or there is nothing to check:
      no override, or an integration whose `calendar_list` has never been
      populated, which `FormValidation` likewise treats as unverifiable
    * `:read_only` — the calendar is still on the account but the host can no
      longer write to it
    * `:missing` — the calendar is gone from the account altogether

  The answer is only as fresh as the last calendar list refresh, so it is a
  warning for the host, never a booking-time gate: see
  `Tymeslot.Integrations.Calendar.Runtime.BookingIntegrationResolver`.
  """
  @spec target_calendar_status(MeetingTypeSchema.t() | map()) :: target_calendar_status()
  def target_calendar_status(%{calendar_integration: %{calendar_list: calendar_list}} = type),
    do: target_calendar_status(calendar_list, type.target_calendar_id)

  def target_calendar_status(_meeting_type), do: :ok

  @doc """
  The same check against a raw calendar list and target id, for callers
  holding the two apart from a persisted meeting type (the meeting type
  editor, whose selection changes before anything is saved).

  Ids are compared with `Tymeslot.Utils.UriUtils.uri_safe_match?/2`, as
  `FormValidation` does: CalDAV ids are URLs whose percent-encoding varies
  between listings, and `==` would report healthy calendars as `:missing`.
  """
  @spec target_calendar_status([CalendarEntry.t()] | nil, String.t() | nil) ::
          target_calendar_status()
  def target_calendar_status([_entry | _rest] = calendar_list, target_calendar_id)
      when is_binary(target_calendar_id) and target_calendar_id != "" do
    case Enum.find(calendar_list, &UriUtils.uri_safe_match?(&1.id, target_calendar_id)) do
      nil -> :missing
      %{read_only: true} -> :read_only
      _writable -> :ok
    end
  end

  def target_calendar_status(_calendar_list, _target_calendar_id), do: :ok

  # Slug resolution and custom-slug management live in the focused sibling
  # module Tymeslot.MeetingTypes.Slugs; these delegations keep the context's
  # public API stable.
  defdelegate find_by_slug(user_id, slug), to: Slugs
  defdelegate effective_slug(meeting_type), to: Slugs
  defdelegate generate_random_slug(user_id), to: Slugs
  defdelegate update_slug(meeting_type, slug), to: Slugs

  # Which meeting types offer a saved venue, asked by `Tymeslot.Venues` for
  # the Locations page, and the rewrite that takes a deleted venue off them.
  defdelegate list_using_venue(user_id, venue_id), to: MeetingTypeQueries
  defdelegate venue_usage_counts(user_id), to: MeetingTypeQueries
  defdelegate remove_venue_from_locations(user_id, venue_id), to: MeetingTypeQueries

  # Which of `user_ids` have at least one meeting type, active or not.
  defdelegate user_ids_with_meeting_type(user_ids), to: MeetingTypeQueries, as: :user_ids_with_any

  @doc """
  The owner's meeting types, by name, that deleting `venue_id` would leave
  with an in-person location listing no venue: those with a location whose
  only venue it is. Such a location then means "the address is arranged
  after booking", which the Locations page warns about before a delete.
  """
  @spec left_without_venue(integer(), integer()) :: [MeetingTypeSchema.t()]
  def left_without_venue(user_id, venue_id) do
    user_id
    |> list_using_venue(venue_id)
    |> Enum.filter(&MeetingTypeSchema.left_without_venue?(&1, venue_id))
  end

  @doc """
  Of `left_without_venue/2`, the group types. A group type's address is
  fixed in advance (`Tymeslot.MeetingTypes.GroupLocationRule`), so it can
  never be left to be arranged after booking: these keep the venue from
  being deleted until they name another one.
  """
  @spec group_types_left_without_venue(integer(), integer()) :: [MeetingTypeSchema.t()]
  def group_types_left_without_venue(user_id, venue_id) do
    user_id
    |> left_without_venue(venue_id)
    |> Enum.filter(&MeetingTypeSchema.group?/1)
  end

  # Duration parsing, normalisation, and booking-flow validation live in the
  # focused sibling module Tymeslot.MeetingTypes.Duration; these delegations
  # keep the context's public API stable.
  defdelegate normalize_duration_slug(duration), to: Duration
  defdelegate find_by_duration_string(user_id, slug), to: Duration
  defdelegate validate_duration_selection(duration, available_types), to: Duration

  @doc """
  The maximum number of reminders one meeting type may carry.

  The rule itself lives in `Tymeslot.MeetingTypes.ReminderValidation`; it is
  exposed here so callers outside the domain, the form UI in particular, offer
  exactly the number the save path enforces.
  """
  defdelegate max_reminders(), to: ReminderValidation

  # Once the write commits, never inside a caller's transaction, where a read
  # in between would cache the old answer again.
  defp invalidate_after_commit(user_id) do
    unless MeetingTypeQueries.in_transaction?(),
      do: Availability.changed(user_id)
  end

  @doc """
  Creates a meeting type from form parameters with validation.
  """
  @spec create_meeting_type_from_form(integer(), map(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, atom() | Ecto.Changeset.t()}
  def create_meeting_type_from_form(user_id, form_params, ui_state) do
    payment_opts = FormMapper.payment_opts(user_id)

    with {:ok, attrs} <- FormMapper.build_attrs(form_params, ui_state, payment_opts[:currency]),
         :ok <- FormValidation.check(user_id, attrs) do
      create_meeting_type(Map.put(attrs, :user_id, user_id), payment_opts)
    end
  end

  @doc """
  Updates a meeting type from form parameters with validation.
  """
  @spec update_meeting_type_from_form(Ecto.Schema.t(), map(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, atom() | Ecto.Changeset.t()}
  def update_meeting_type_from_form(meeting_type, form_params, ui_state) do
    user_id = meeting_type.user_id

    payment_opts = FormMapper.payment_opts(user_id)

    with {:ok, attrs} <-
           FormMapper.build_attrs(form_params, ui_state, payment_opts[:currency]),
         :ok <- FormValidation.check(user_id, attrs, meeting_type.max_participants || 1) do
      update_meeting_type(meeting_type, attrs, payment_opts)
    end
  end

  @doc """
  Seeds the two default meeting types for a new user, once, as the profile is
  created (`Tymeslot.Profiles.create_profile/1` and the OAuth sign-up, which
  passes its transaction's `repo`). A host who later deletes them keeps none:
  nothing seeds them again.

  A new account has no calendar and no username yet, so the defaults carry
  no booking calendar and there is no booking page to publish. A seed that
  meets types already there (a retried sign-up) inserts nothing.
  """
  @spec seed_default_meeting_types(integer(), Ecto.Repo.t()) :: :ok
  defdelegate seed_default_meeting_types(user_id, repo \\ Repo), to: Defaults
end
