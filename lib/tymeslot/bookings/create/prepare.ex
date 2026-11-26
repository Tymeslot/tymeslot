defmodule Tymeslot.Bookings.Create.Prepare do
  @moduledoc """
  The steps every new booking takes before its time is judged: turning the
  submission into booking data, checking the custom-field answers, and the
  admission checks (host accepting bookings, type active, invitation, seats,
  payments).

  Shared by `Tymeslot.Bookings.Create`, for one meeting, and
  `Tymeslot.BookingSeries.Create`, for a series, so the two cannot drift.
  A series has many times, so `booking_data/2` is split: `common/2` is what
  every occurrence shares, and the time is added to it per booking.
  """

  alias Ecto.UUID
  alias Tymeslot.Auth
  alias Tymeslot.Availability.Offer
  alias Tymeslot.BookingPages
  alias Tymeslot.Bookings.{CreateGroup, Validation}
  alias Tymeslot.CustomFields
  alias Tymeslot.Invitations
  alias Tymeslot.Locales
  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.Lengths
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.MeetingTypes.SeriesSettings

  @doc """
  The booking data for one booking at the submitted date and time: `common/2`
  plus the start and end in UTC, a fresh meeting uid, and the group slot the
  booking would join.
  """
  @spec booking_data(map(), map()) :: {:ok, map()} | {:error, atom()}
  def booking_data(meeting_params, form_data) do
    common = common(meeting_params, form_data)

    with {:ok, date_string} <- normalize_date_input(meeting_params.date),
         {:ok, {start_datetime, end_datetime}} <-
           Validation.parse_meeting_times(
             date_string,
             meeting_params.time,
             common.duration_minutes,
             meeting_params.user_timezone
           ),
         {:ok, date} <- Date.from_iso8601(date_string) do
      booking_data =
        Map.merge(common, %{
          meeting_uid: UUID.generate(),
          start_datetime: start_datetime,
          end_datetime: end_datetime,
          date: date
        })

      # Read once, here, so the booking-limit pre-check and the calendar
      # check agree on whether this booking joins a live group slot.
      {:ok, Map.put(booking_data, :join_target, CreateGroup.join_target(booking_data))}
    else
      {:error, :invalid_date_input} -> {:error, :invalid_datetime}
      {:error, :invalid_format} -> {:error, :invalid_datetime}
      error -> error
    end
  end

  @doc """
  What a booking is, apart from its time: the resolved meeting type, the
  session length, the booker's answers and every attribution the submission
  carries.

  The duration comes from the resolved meeting type, never the request,
  whenever a type is known (the request only picks among the lengths the
  type offers, see `Offer.duration_minutes/3`), as Reschedule pins it to the
  persisted meeting. Only an unresolvable type, which the active check
  refuses a few steps later, falls back to the client-supplied value,
  bounded exactly as the booking page bounds it. The resolved record
  is kept on the data for everything downstream, which then reads it from
  memory instead of each issuing the same query again.
  """
  @spec common(map(), map()) :: map()
  def common(meeting_params, form_data) do
    meeting_type = resolve_meeting_type(meeting_params)
    duration = Map.get(meeting_params, :duration)
    organizer_user_id = Map.get(meeting_params, :organizer_user_id)

    %{
      duration_minutes: Offer.duration_minutes(meeting_type, duration, Lengths.parse(duration)),
      meeting_type: meeting_type,
      user_timezone: Map.get(meeting_params, :user_timezone),
      form_data: form_data,
      organizer_user_id: organizer_user_id,
      meeting_type_id: Map.get(meeting_params, :meeting_type_id),
      video_integration_id: Map.get(meeting_params, :video_integration_id),
      location_option_id: Map.get(meeting_params, :location_option_id),
      location_phone: Map.get(meeting_params, :location_phone),
      location_video_integration_id: Map.get(meeting_params, :location_video_integration_id),
      location_venue_id: Map.get(meeting_params, :location_venue_id),
      attendee_locale:
        Map.get(meeting_params, :attendee_locale) || Locales.booking_default_locale(),
      custom_fields_snapshot: Map.get(meeting_params, :custom_fields_snapshot, []),
      custom_field_answers: Map.get(meeting_params, :custom_field_answers, %{}),
      guest_emails: Map.get(meeting_params, :guest_emails, []),
      utm_source: Map.get(meeting_params, :utm_source),
      utm_medium: Map.get(meeting_params, :utm_medium),
      utm_campaign: Map.get(meeting_params, :utm_campaign),
      utm_content: Map.get(meeting_params, :utm_content),
      utm_term: Map.get(meeting_params, :utm_term),
      referrer_host: Map.get(meeting_params, :referrer_host),
      tracking_params: Map.get(meeting_params, :tracking_params, %{}),
      visitor_hash: Map.get(meeting_params, :visitor_hash),
      booking_page_id:
        BookingPages.existing_id(Map.get(meeting_params, :booking_page_id), organizer_user_id),
      invitation_id: invitation_id(meeting_type, meeting_params)
    }
  end

  @doc "Checks the booker's custom-field answers against the type's fields."
  @spec validate_custom_field_answers(map()) :: :ok | {:error, {:custom_field_errors, term()}}
  def validate_custom_field_answers(%{
        custom_fields_snapshot: snapshot,
        custom_field_answers: answers
      }) do
    case CustomFields.validate_answers(snapshot, answers) do
      {:ok, _normalised} -> :ok
      {:error, errors} -> {:error, {:custom_field_errors, errors}}
    end
  end

  @doc """
  Whether the booking may be taken at all, whatever its time: an organiser,
  who is still taking bookings, an active type, an invitation where the type
  asks for one, a group type still taking seats, and payments where the type
  charges.
  """
  @spec validate_admission(map()) :: :ok | {:error, atom()}
  def validate_admission(%{organizer_user_id: nil}), do: {:error, :organizer_required}

  def validate_admission(%{organizer_user_id: user_id} = booking_data) do
    with :ok <- validate_taking_bookings(booking_data),
         do: validate_payments_available(booking_data, user_id)
  end

  @doc """
  `validate_admission/1` without the payments check, for a booking whose
  payment has already been taken: an organiser still taking bookings, an
  active type, an invitation where the type asks for one, and a group type
  still taking seats.
  """
  @spec validate_taking_bookings(map()) :: :ok | {:error, atom()}
  def validate_taking_bookings(%{organizer_user_id: nil}), do: {:error, :organizer_required}

  def validate_taking_bookings(%{organizer_user_id: user_id} = booking_data) do
    with :ok <- validate_host_accepting(user_id),
         :ok <- validate_meeting_type_active(booking_data),
         :ok <- validate_invitation(booking_data),
         do: CreateGroup.ensure_taking_seats(booking_data)
  end

  @doc """
  Whether the booking's meeting type takes a single session: a type booked
  as a series takes none unless the host lets it (`series_required: false`);
  a series is booked through `Tymeslot.BookingSeries`. A reschedule moves
  one existing session and never asks.
  """
  @spec validate_single_allowed(map()) :: :ok | {:error, :series_required}
  def validate_single_allowed(%{meeting_type: %MeetingTypeSchema{} = type}) do
    if SeriesSettings.single_allowed?(type), do: :ok, else: {:error, :series_required}
  end

  def validate_single_allowed(_booking_data), do: :ok

  @doc "Whether the booking's meeting type charges for it."
  @spec paid?(map()) :: boolean()
  def paid?(%{meeting_type: %{payment_required: true}}), do: true
  def paid?(_booking_data), do: false

  # An invitation is recorded only on the type that asks for one: an id sent
  # with a booking on an open type is ignored, so the meeting never counts
  # against an invitation it did not need.
  defp invitation_id(%{invitation_only: true}, meeting_params),
    do: Map.get(meeting_params, :invitation_id)

  defp invitation_id(_meeting_type, _meeting_params), do: nil

  defp resolve_meeting_type(meeting_params) do
    type_id = Map.get(meeting_params, :meeting_type_id)
    user_id = Map.get(meeting_params, :organizer_user_id)

    if is_integer(type_id) and is_integer(user_id) do
      MeetingTypes.get_meeting_type(type_id, user_id)
    end
  end

  defp normalize_date_input(%Date{} = date), do: {:ok, Date.to_iso8601(date)}
  defp normalize_date_input(date) when is_binary(date), do: {:ok, date}
  defp normalize_date_input(_arg), do: {:error, :invalid_date_input}

  # A host whose account waits to be deleted takes no new bookings, even from
  # a booking page that was already open when the deletion was requested.
  defp validate_host_accepting(user_id) do
    if Auth.deletion_pending?(user_id), do: {:error, :host_not_found}, else: :ok
  end

  # A nil record with a meeting_type_id set means the type doesn't exist (or
  # belongs to another host).
  #
  # A booking is always made under a meeting type: approval, email
  # confirmation, payment, the type's schedule, buffers, limits and questions
  # are all read from it, so one saved without it skips every one of them.
  # An untyped meeting has routes of its own (`CreateAdHoc`, a confirmed
  # poll), so a booking page reaching here without a type is refused rather
  # than saved under nobody's rules.
  defp validate_meeting_type_active(%{meeting_type_id: nil}), do: {:error, :meeting_type_missing}
  defp validate_meeting_type_active(%{meeting_type: %{is_active: true}}), do: :ok

  defp validate_meeting_type_active(%{meeting_type: %{is_active: false}}),
    do: {:error, :meeting_type_inactive}

  defp validate_meeting_type_active(%{meeting_type: nil}), do: {:error, :meeting_type_not_found}

  # An invitation-only type is booked only through one of its own invitations,
  # still available. This is the friendly pre-check; the invitation index
  # (`Tymeslot.Meetings.UniqueInvitation`) is what keeps two bookings racing
  # on one invitation from both landing, see `Create.create_meeting/1`.
  defp validate_invitation(%{meeting_type: %{invitation_only: true} = type, invitation_id: id})
       when is_integer(id) do
    # `CreateGroup` would book a group type without recording the invitation,
    # leaving it unspent, so such a type is never claimable.
    if MeetingTypeSchema.group?(type),
      do: {:error, :invitation_unavailable},
      else: Invitations.check_claimable(id, type.id)
  end

  defp validate_invitation(%{meeting_type: %{invitation_only: true}}),
    do: {:error, :invitation_required}

  defp validate_invitation(_booking_data), do: :ok

  # A paid meeting type outlives its host's Stripe connection: the price is
  # kept so it resumes when they reconnect, rather than being cleared behind
  # their back. Refusing here is what stops the booking being taken anyway:
  # without it the meeting was created in `awaiting_payment`, `CheckoutSessions`
  # then refused for want of a charges-enabled account, and the booker was left
  # with the same message on top of a half-made booking that had to expire.
  # The same holds when the host's plan no longer grants payments.
  defp validate_payments_available(booking_data, user_id) do
    if paid?(booking_data) and not MeetingPayments.accepting_payments?(user_id),
      do: {:error, :payments_unavailable},
      else: :ok
  end
end
