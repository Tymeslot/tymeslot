defmodule Tymeslot.BookingApi do
  @moduledoc """
  Creates bookings on an organiser's behalf from an external system.

  The endpoint is `POST /api/v1/bookings`, described in `docs/API.md`. An
  organiser opts in by generating a secret token (`enable/1`); clearing it
  (`disable/1`) closes the endpoint for that organiser alone, leaving everyone
  else on the instance untouched.

  The token travels in an `Authorization: Bearer` header and the attendee's
  details in the request body, never in the URL. That is the same reasoning
  that has the booking page resolve a reschedule through an opaque
  `reschedule_meeting_uid` rather than carrying the attendee's name and address
  in the query string: a URL puts both into access logs, browser history and
  `Referer` headers, none of which the organiser controls.

  A booking made here is the organiser's own, on the same footing as one
  created from the dashboard calendar. `Tymeslot.Bookings.CreateAdHoc` persists
  it and the attendee receives the usual invitation carrying its cancel and
  reschedule links. Unlike the dashboard, which books over anything because the
  organiser is looking at the grid while they decide, this path enforces the
  organiser's notice period, booking horizon and connected-calendar conflicts
  by default — a caller cannot see the grid. `force` waives those checks for
  the case where the organiser has agreed the slot with the attendee directly.
  """

  require Logger

  alias Tymeslot.BookingApi.Params
  alias Tymeslot.BookingApi.RequestQueries
  alias Tymeslot.Bookings.CreateAdHoc
  alias Tymeslot.Features
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.MeetingTypeQueries
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Profiles.ProfileSchema

  @token_bytes 24

  @typedoc """
  Why a booking was refused. `{:invalid_params, violations}` carries one entry
  per offending field; every other reason is a single condition.
  """
  @type error ::
          {:invalid_params, [Params.violation()]}
          | Features.access_error()
          | :meeting_type_not_found
          | :meeting_type_requires_payment
          | :slot_unavailable
          | :time_conflict
          | :in_progress
          | String.t()

  @typedoc """
  `:created` means this call booked the meeting; `:replayed` means an earlier
  call with the same idempotency key did, and this one changed nothing.
  """
  @type outcome :: {:ok, :created | :replayed, MeetingSchema.t()} | {:error, error()}

  # ============================================================================
  # Token lifecycle
  # ============================================================================

  @doc "Whether the organiser has an active booking API token."
  @spec enabled?(ProfileSchema.t()) :: boolean()
  def enabled?(%ProfileSchema{booking_api_token: token}),
    do: is_binary(token) and token != ""

  @doc """
  Ensures the profile has a token, generating one if absent. Idempotent — an
  organiser who has already enabled the endpoint keeps the token their callers
  are configured with.
  """
  @spec enable(ProfileSchema.t()) :: {:ok, ProfileSchema.t()} | {:error, Ecto.Changeset.t()}
  def enable(%ProfileSchema{} = profile) do
    if enabled?(profile) do
      {:ok, profile}
    else
      ProfileQueries.update_booking_api_token(profile, generate_token())
    end
  end

  @doc "Issues a fresh token, invalidating the previous one immediately."
  @spec regenerate_token(ProfileSchema.t()) ::
          {:ok, ProfileSchema.t()} | {:error, Ecto.Changeset.t()}
  def regenerate_token(%ProfileSchema{} = profile),
    do: ProfileQueries.update_booking_api_token(profile, generate_token())

  @doc "Closes the endpoint for this organiser by clearing the token."
  @spec disable(ProfileSchema.t()) :: {:ok, ProfileSchema.t()} | {:error, Ecto.Changeset.t()}
  def disable(%ProfileSchema{} = profile),
    do: ProfileQueries.update_booking_api_token(profile, nil)

  @doc "Returns the profile owning `token`, or `{:error, :not_found}`."
  @spec authenticate(String.t()) :: {:ok, ProfileSchema.t()} | {:error, :not_found}
  def authenticate(token), do: ProfileQueries.get_by_booking_api_token(token)

  # ============================================================================
  # Booking
  # ============================================================================

  @doc """
  Creates a booking for `profile`'s organiser from an already-decoded JSON body.

  `idempotency_key` is the request's `Idempotency-Key` header, or `nil` when it
  was absent. Supplying one makes the call safe to retry: a second attempt
  returns `{:ok, :replayed, meeting}` carrying the meeting the first attempt
  created, rather than booking the attendee twice.
  """
  @spec create_booking(ProfileSchema.t(), map(), String.t() | nil) :: outcome()
  def create_booking(%ProfileSchema{} = profile, body, idempotency_key \\ nil) do
    with {:ok, params} <- Params.parse(body),
         :ok <- Features.check_access(profile.user_id, :automations_allowed),
         {:ok, meeting_type} <- resolve_meeting_type(profile.user_id, params.meeting_type) do
      book(profile, params, meeting_type, idempotency_key)
    end
  end

  # Private — booking

  defp book(profile, params, meeting_type, nil) do
    with {:ok, meeting} <- create(profile, params, meeting_type) do
      {:ok, :created, meeting}
    end
  end

  defp book(profile, params, meeting_type, key) do
    # The claim is inserted before the booking, so two concurrent retries of one
    # request cannot both reach CreateAdHoc: the unique index on
    # (user_id, idempotency_key) admits exactly one of them, and the loser is
    # answered from the winner's outcome instead of booking a second meeting.
    case RequestQueries.claim(profile.user_id, key) do
      {:ok, claim} ->
        settle(claim, profile, params, meeting_type)

      {:error, :already_claimed} ->
        replay(profile.user_id, key)

      {:error, %Ecto.Changeset{}} ->
        {:error, {:invalid_params, [idempotency_key_violation()]}}
    end
  end

  # The only ways the claim changeset fails are a blank or over-long key,
  # both of which are the caller's to fix.
  defp idempotency_key_violation do
    %{field: "idempotency_key", message: "must be 1 to 255 characters"}
  end

  defp settle(claim, profile, params, meeting_type) do
    case create(profile, params, meeting_type) do
      {:ok, meeting} ->
        record_meeting(claim, meeting)
        {:ok, :created, meeting}

      {:error, reason} ->
        # A rejected booking must not hold the key hostage: the caller has to be
        # able to correct the request and retry it under the same key.
        release(claim)
        {:error, reason}
    end
  end

  # The meeting exists either way. Failing the response here would invite the
  # caller to retry a request that has already booked the attendee, so a lost
  # claim is logged and the booking still reported.
  defp record_meeting(claim, meeting) do
    case RequestQueries.attach_meeting(claim, meeting.id) do
      {:ok, _claim} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to record booking API idempotency key against its meeting",
          meeting_id: meeting.id,
          error: inspect(reason)
        )

        :ok
    end
  end

  defp release(claim) do
    case RequestQueries.release(claim) do
      {:ok, _claim} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to release a booking API idempotency claim",
          user_id: claim.user_id,
          error: inspect(reason)
        )

        :ok
    end
  end

  defp replay(user_id, key) do
    case RequestQueries.get_meeting(user_id, key) do
      {:ok, meeting} ->
        {:ok, :replayed, meeting}

      # The winning request holds the key but has not recorded a meeting against
      # it yet. Retrying resolves it either way, which is what the caller is told.
      {:error, :not_found} ->
        {:error, :in_progress}
    end
  end

  defp create(profile, params, meeting_type) do
    profile.user_id
    |> ad_hoc_params(params, meeting_type)
    |> CreateAdHoc.execute(enforce_availability: not params.force)
  end

  defp ad_hoc_params(user_id, params, meeting_type) do
    {calendar_integration_id, calendar_path} = calendar_target(meeting_type || user_id)

    %{
      title: title(params, meeting_type),
      start_time: params.start_time,
      end_time: end_time(params, meeting_type),
      attendee_name: params.attendee_name,
      attendee_email: params.attendee_email,
      attendee_timezone: params.attendee_timezone,
      organizer_user_id: user_id,
      calendar_integration_id: calendar_integration_id,
      calendar_path: calendar_path,
      video_integration_id: meeting_type && meeting_type.video_integration_id,
      guest_emails: params.guest_emails
    }
  end

  # Mirrors the title the public booking page composes for the same meeting
  # type, so a booking made through the API is indistinguishable from one the
  # attendee made themselves in the organiser's calendar and inbox.
  defp title(%{title: title}, _meeting_type) when is_binary(title), do: title

  defp title(%{attendee_name: attendee_name}, %MeetingTypeSchema{name: name}),
    do: "#{name} with #{attendee_name}"

  defp end_time(%{end_time: %DateTime{} = end_time}, _meeting_type), do: end_time

  defp end_time(%{start_time: start_time, duration_minutes: minutes}, _meeting_type)
       when is_integer(minutes),
       do: DateTime.add(start_time, minutes, :minute)

  defp end_time(%{start_time: start_time}, %MeetingTypeSchema{duration_minutes: minutes}),
    do: DateTime.add(start_time, minutes, :minute)

  defp resolve_meeting_type(_user_id, nil), do: {:ok, nil}

  defp resolve_meeting_type(user_id, slug) do
    case MeetingTypeQueries.get_active_by_slug(user_id, slug) do
      {:ok, %MeetingTypeSchema{payment_required: true}} ->
        # Booking one of these outside the payment flow would confirm a meeting
        # the attendee has not paid for, and no checkout session would ever be
        # raised against it. Refusing is the only honest answer.
        {:error, :meeting_type_requires_payment}

      {:ok, meeting_type} ->
        {:ok, meeting_type}

      {:error, :not_found} ->
        {:error, :meeting_type_not_found}
    end
  end

  defp calendar_target(context) do
    case CalendarEvents.get_booking_integration_info(context) do
      {:ok, %{integration_id: integration_id, calendar_path: calendar_path}} ->
        {integration_id, calendar_path}

      _other ->
        {nil, nil}
    end
  end

  defp generate_token do
    @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
