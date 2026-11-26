defmodule Tymeslot.Bookings.CreateGroup do
  @moduledoc """
  Books a seat on a group meeting type (`max_participants > 1`) through
  `Tymeslot.Meetings.GroupScheduling.book_seat/3`.

  Kept apart from `Tymeslot.Bookings.Create`, which remains the sole entry point
  booking callers use: it resolves the meeting type and builds the (pre-booker)
  meeting attributes, then dispatches here once `applicable?/1` says the meeting
  type holds more than one seat.
  """

  require Logger

  alias Tymeslot.Bookings.Activation
  alias Tymeslot.Bookings.Create.Prepare
  alias Tymeslot.Bookings.Errors
  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Bookings.SeatEffects
  alias Tymeslot.Bookings.SeatRelease
  alias Tymeslot.Bookings.SlotActivation
  alias Tymeslot.Bookings.Telemetry
  alias Tymeslot.Clock
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingPayments.Checkout
  alias Tymeslot.Meetings.EmailVerification
  alias Tymeslot.Meetings.EmailVerificationJobs
  alias Tymeslot.Meetings.GroupScheduling
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Meetings.SeatHoldSchema
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.FixedDates
  alias Tymeslot.MeetingTypes.GroupAccess
  alias Tymeslot.MeetingTypes.MeetingTypeSchema

  @doc "True when the booking's meeting type holds more than one seat."
  @spec applicable?(map()) :: boolean()
  def applicable?(%{meeting_type: %MeetingTypeSchema{} = meeting_type}),
    do: MeetingTypeSchema.group?(meeting_type)

  def applicable?(_booking_data), do: false

  @doc """
  Refuses a seat on a paused group type (see `Tymeslot.MeetingTypes.GroupAccess`):
  its host has lost access to group bookings since saving it, so it takes no
  new seats, whether the first on a slot or a join. Everything else passes.

  The booking page does not offer a paused type, so this refuses only a
  page left open from before the host lost access. The reason reads to the
  booker as the type having become unavailable, as it has.
  """
  @spec ensure_taking_seats(map()) :: :ok | {:error, :group_bookings_paused}
  def ensure_taking_seats(%{meeting_type: meeting_type}) do
    if GroupAccess.paused?(meeting_type), do: {:error, :group_bookings_paused}, else: :ok
  end

  def ensure_taking_seats(_booking_data), do: :ok

  @doc """
  The live group meeting this booking would join, or `nil` when it would
  create a new slot, be refused as full, or is not a group booking at all.

  Decided by `GroupScheduling.join_target/3`, the seat transaction's own
  joinability rule, for this booker's seats (themselves plus their guests).
  `Create` reads it to exempt a join from the booking-limit pre-check and to
  drop the meeting's own event from the calendar check; neither exemption can
  outlive the slot, because the seat transaction re-decides under its lock.
  """
  @spec join_target(map()) :: MeetingSchema.t() | nil
  def join_target(%{meeting_type: meeting_type, start_datetime: start} = booking_data) do
    if applicable?(booking_data) do
      GroupScheduling.join_target(meeting_type.id, start, 1 + length(guest_emails(booking_data)))
    end
  end

  def join_target(_booking_data), do: nil

  # `:attendee_locale` is deliberately kept off `SeatEffects.slot_attrs/2`'s
  # drop list: the first booker's locale seeds the (attendee-less) meeting
  # row, used to localise content built straight from the meeting rather
  # than through a participant recipient.

  @doc """
  Routes a group meeting type's booking through the seat transaction instead
  of the solo/paid meeting-row transaction: the slot is a shared meeting row
  and each booker becomes a `meeting_participants` record rather than the
  meeting's sole attendee.

  Every job the seat owes is enqueued inside that transaction, as
  `Tymeslot.Bookings.Create` does for a one-to-one booking: the calendar
  job, the seat's confirmation emails and, for the seat that creates the
  slot, its reminders and video room. A job that cannot be enqueued rolls
  the seat back, so a seat never commits without the emails and jobs it
  owes, and no job outlives a seat that rolled back. The integration fan-out
  (webhooks, Telegram, Slack), the broadcast, the cache invalidation and the
  telemetry run once the seat has committed: none is durable, and a
  database error in a best-effort dispatcher must not cost the seat.

  On a paid type the booker's seats are reserved by a seat hold instead
  (`SeatHolds`) for as long as the Stripe Checkout opened for them stays open, and
  `{:ok, :payment_required, %{meeting:, seat_hold:, checkout_url:}}` is
  returned. Nothing is enqueued for a hold: the seat's jobs and emails
  follow its payment. The checkout is opened once the hold has committed,
  never inside the seat transaction, which holds the organiser's schedule
  lock; a checkout that cannot be opened releases the hold at once.

  On a type requiring email verification (`EmailVerification.required?/1`)
  the seat is held instead: it takes its place, so it counts against the
  slot's capacity, but carries a verification deadline and owes only its
  verification email and its expiry job. A slot this seat creates is held
  too, with the seat's deadline, which only keeps it from the organiser: it
  expires through its seats (`Tymeslot.Meetings.EmailVerification.Seats`).
  A later held seat joining a held slot moves the slot's deadline to its own.
  Verifying the seat later schedules everything an ungated seat schedules
  now. An ungated seat that finds a held slot (the host turned verification
  off during a hold) counts at once, so it brings the slot to life.

  Options are the same ones `Tymeslot.Bookings.Create.execute/3` accepts;
  only `:with_video_room` matters here (see `SeatEffects.schedule_new_slot_effects/2`),
  and only for a free seat: a paid seat hold's jobs follow its payment.
  """
  @spec create(map(), map(), keyword()) ::
          {:ok, map()}
          | {:ok, :payment_required,
             %{
               meeting: MeetingSchema.t(),
               seat_hold: SeatHoldSchema.t(),
               checkout_url: String.t()
             }}
          | {:error, Errors.classified_error()}
  def create(meeting_attrs, booking_data, opts \\ []) do
    if Prepare.paid?(booking_data) do
      # A paid seat hold schedules nothing, so takes no options; a paid group
      # series is out of scope (Decision 9) and never books through here.
      create_paid(meeting_attrs, booking_data)
    else
      meeting_attrs
      |> book_seat(booking_data, opts)
      |> map_result(booking_data)
    end
  end

  defp create_paid(meeting_attrs, booking_data) do
    with {:ok, %{meeting: meeting, seat_hold: hold}} <- hold_seats(meeting_attrs, booking_data),
         {:ok, url} <- checkout_or_release(meeting, hold) do
      # A held seat is the booking; its payment completing must not count it
      # again.
      Telemetry.booking_created()
      SeatEffects.broadcast_and_invalidate(meeting)
      {:ok, :payment_required, %{meeting: meeting, seat_hold: hold, checkout_url: url}}
    else
      error -> map_result(error, booking_data)
    end
  end

  # The hold outlives the checkout opened for it once it commits.
  defp hold_seats(meeting_attrs, %{meeting_type: meeting_type} = booking_data) do
    expires_at =
      Clock.utc_now()
      |> DateTime.truncate(:second)
      |> DateTime.add(Checkout.hold_expiry_seconds())

    meeting_attrs
    |> SeatEffects.slot_attrs(meeting_type.name)
    |> GroupScheduling.book_seat(build_seat_request(meeting_attrs, booking_data, nil),
      hold: %{expires_at: expires_at},
      join_only: FixedDates.sessions?(meeting_type)
    )
  end

  defp checkout_or_release(meeting, hold) do
    case Checkout.create_seat_checkout_session(hold) do
      {:ok, %{checkout_url: url}} ->
        {:ok, url}

      {:error, reason} ->
        release_failed_hold(meeting, hold, reason)
        {:error, {:checkout_failed, reason}}
    end
  end

  # Frees the seats of a hold whose checkout never opened and fails the
  # payment opened for it (Stripe may have created the session even though
  # the call failed), settling its meeting as every lapsed hold's is
  # (`SeatRelease.release_unpaid_hold/1`): a slot the hold alone created is
  # expired. A release that fails is logged and left, as the booking has
  # already failed; the hold then lapses and the sweeper releases it.
  defp release_failed_hold(meeting, hold, reason) do
    case SeatRelease.release_unpaid_hold(hold) do
      {:ok, _released} -> :ok
      failed -> log_release_failure(meeting, reason, failed)
    end
  end

  defp log_release_failure(meeting, reason, failed) do
    Logger.warning("Failed to release a seat hold after checkout failure",
      meeting_id: meeting.id,
      checkout_error: LogFormat.reason(reason),
      release_error: LogFormat.reason(failed)
    )
  end

  @doc """
  Takes the seat `create/3` takes, with every job it owes enqueued in the
  seat's transaction, and returns `GroupScheduling.book_seat/3`'s result
  unmapped: the integration fan-out the seat owes is its
  `:on_booked_result`, for the caller to run once its transaction commits.

  For a caller booking several seats in one transaction of its own (a
  booking series, `Tymeslot.BookingSeries.Create`). The seat is the series'
  when `meeting_attrs` carries a `:series_id` and `:series_position`: they
  go on the booker's participant row, never on the shared slot.

  Options, besides `:with_video_room`:

    * `:emails` - `false` sends no confirmation for the seat, to the booker
      or the host: a series confirms all its seats in one email. A session
      the seat creates still gets its reminders and video room, the room
      holding nothing back.
    * `:in_outer_transaction` - passed on to `GroupScheduling.book_seat/3`.
  """
  @spec book_seat(map(), map(), keyword()) ::
          {:ok, GroupScheduling.booking()} | {:error, term()}
  def book_seat(meeting_attrs, booking_data, opts \\ []) do
    %{meeting_type: meeting_type} = booking_data
    deadline = verification_deadline(meeting_type, meeting_attrs.start_time)

    meeting_attrs
    |> group_meeting_attrs(meeting_type, deadline)
    |> GroupScheduling.book_seat(build_seat_request(meeting_attrs, booking_data, deadline),
      on_booked: &schedule_seat_jobs(&1, deadline, opts),
      join_only: FixedDates.sessions?(meeting_type),
      in_outer_transaction: Keyword.get(opts, :in_outer_transaction, false)
    )
  end

  @doc """
  Turns the paid seat hold `hold_id` into its booker's seat
  (`GroupScheduling.convert_hold/2`), inside the payment webhook's
  transaction, with every job the seat owes enqueued as for a free seat:
  its calendar job, its confirmation emails and, for the seat that
  confirms its slot, the slot's reminders and video room. The integration
  fan-out is the booking's `:on_booked_result`, for the caller to run once
  committed (`Activation.after_commit/1`).

  A hold whose meeting lapsed before the payment landed takes the slot
  again where it still has room, on a new meeting when nobody holds it while
  its type would take the booking now and the slot has not started; never
  on a fixed-date type, whose sessions only its host plans.

  Returns `GroupScheduling.convert_hold/2`'s result: a `{:refused, reason}`
  leaves the webhook's transaction usable, an `{:error, reason}` has rolled
  it back.
  """
  @spec complete_paid_hold(Ecto.UUID.t()) ::
          {:ok, GroupScheduling.seat_booking()}
          | {:refused, :slot_full | :hold_not_convertible}
          | {:error, term()}
  def complete_paid_hold(hold_id) do
    GroupScheduling.convert_hold(hold_id,
      on_booked: &schedule_seat_jobs(&1, nil, []),
      new_slot: &late_slot/2
    )
  end

  # The type as it stands now decides whether it takes a new meeting, and
  # its limit is the new meeting's capacity. It must take this booking were
  # it made now (`Prepare.validate_taking_bookings/1`,
  # `validate_single_allowed/1`: its host still taking bookings, the type
  # active and not paused, single sessions allowed), still charge for a group
  # seat, and the slot must not have started. Whether the host can take a
  # payment now is not asked: this one has already been taken, and refusing
  # the seat would only hand it back (or, on a disconnected account, leave a
  # refund nobody can make). Its schedule, notice and limits are not asked
  # again either: the booker chose the slot while they held, and paid for it.
  defp late_slot(hold, meeting) do
    with %MeetingTypeSchema{} = type <- late_slot_type(meeting),
         true <- late_slot_bookable?(type, meeting) do
      {:ok, fn -> late_slot_attrs(meeting, hold) end, type.max_participants}
    else
      _not_bookable -> :none
    end
  end

  defp late_slot_type(%MeetingSchema{meeting_type_id: type_id, organizer_user_id: user_id})
       when is_integer(type_id) and is_integer(user_id),
       do: MeetingTypes.get_meeting_type(type_id, user_id)

  defp late_slot_type(_meeting), do: nil

  defp late_slot_bookable?(type, meeting) do
    booking_data = %{
      organizer_user_id: meeting.organizer_user_id,
      meeting_type_id: type.id,
      meeting_type: type
    }

    MeetingTypeSchema.group?(type) and Prepare.paid?(booking_data) and
      not FixedDates.sessions?(type) and
      DateTime.after?(meeting.start_time, Clock.utc_now()) and
      Prepare.validate_taking_bookings(booking_data) == :ok and
      Prepare.validate_single_allowed(booking_data) == :ok
  end

  defp late_slot_attrs(meeting, hold) do
    times = %{
      start_time: meeting.start_time,
      end_time: meeting.end_time,
      duration_minutes: div(DateTime.diff(meeting.end_time, meeting.start_time), 60)
    }

    SeatEffects.rebuilt_slot_attrs(meeting, times, hold)
  end

  # `nil` for an ungated seat.
  defp verification_deadline(meeting_type, start_time) do
    if EmailVerification.required?(meeting_type),
      do: EmailVerification.deadline_for(Clock.utc_now(), start_time)
  end

  # The broadcast is still owed for a held seat: the slot's capacity changed.
  defp map_result({:ok, %{meeting: meeting, on_booked_result: pending} = booking}, _booking_data) do
    :ok = Activation.after_commit(pending)
    record_booking(booking.participant)
    SeatEffects.broadcast_and_invalidate(meeting)

    {:ok, meeting}
  end

  defp map_result(error, booking_data), do: map_error(error, booking_data)

  # A held seat is not a booking yet; it is counted when it is verified.
  defp record_booking(participant) do
    if not ParticipantSchema.unverified?(participant), do: Telemetry.booking_created()
    :ok
  end

  defp map_error({:error, :slot_full}, _booking_data), do: {:error, :slot_taken}

  # The booker's email already has a seat (`:already_booked`) or a checkout
  # still open (`:seat_held`) on the slot, found under the lock before the
  # insert (see `GroupScheduling.book_seat/3`).
  defp map_error({:error, reason}, _booking_data) when reason in [:already_booked, :seat_held],
    do: {:error, reason}

  # `book_seat/3` exhausts its retry on a rare first-booker index collision
  # and surfaces the raw changeset. Its `organizer_user_id` error is worded
  # for an organiser double-booking themselves, which a group booker must
  # never see, so this collapses to the same `:slot_taken` outcome as every
  # other lost-race case. A duplicate seat is worth naming: the booker has
  # this slot already, most likely from a second tab, and "try again" is the
  # wrong advice.
  defp map_error({:error, %Ecto.Changeset{} = changeset}, booking_data) do
    cond do
      MeetingSchema.unique_slot_violation?(changeset) -> {:error, :slot_taken}
      ParticipantSchema.duplicate_seat?(changeset) -> {:error, :already_booked}
      true -> {:error, Errors.classify_creation_error(changeset, booking_data)}
    end
  end

  defp map_error({:error, reason}, booking_data),
    do: {:error, Errors.classify_creation_error(reason, booking_data)}

  # Runs inside the seat transaction (see `create/3`); any error rolls the
  # seat back. Runs again from scratch on `book_seat/3`'s retry, whose
  # rolled-back attempt took its jobs with it. Returns the seat's integration
  # fan-out, which `map_result/2` runs once the seat has committed.
  #
  # The first seat on a slot with an API-created video provider owns the room:
  # it schedules creation and lets `VideoRoomWorker` release the confirmation
  # emails once the join link exists, exactly as the solo path does. Later
  # seats find the room already there (or on its way), so their emails go out
  # immediately and still carry the link when it lands in time. Either way
  # the job sending them is the one the seat's `confirmation_sent_at` and
  # `organizer_notified_at` markers keep from sending twice.
  #
  # A seat sending no emails (`emails: false`) is a seat of a booking series;
  # see `SlotActivation.schedule_seat_effects/4`.
  #
  # A held seat owes only its verification email (rolled back with the seat
  # if it cannot be queued) and its expiry job; nothing tells anyone else of
  # it. An ungated seat on a held slot is the slot's first counting seat, so
  # `SlotActivation` confirms the slot and gives this seat the first-seat
  # effects.
  #
  # A held seat ignores `opts`, `:emails` included: it is never a series'
  # seat, because a type asking invitees to confirm their email cannot offer
  # a series (`Tymeslot.MeetingTypes.SeriesSettings.offered?/1`). Relaxing
  # that rule needs a held series seat to be designed first.
  #
  # A held slot's deadline is its latest held seat's, which is what the
  # retention prune measures from, so a held seat joining one moves it on.
  defp schedule_seat_jobs(
         %{meeting: meeting, participant: participant} = booking,
         %DateTime{},
         _opts
       ) do
    :ok = hold_slot_until(booking, participant.verification_deadline_at)

    with :ok <- EmailScheduler.schedule_seat_verification_email(meeting.id, participant.id) do
      :ok = EmailVerificationJobs.schedule_seat_expiry(participant)
      {:ok, []}
    end
  end

  defp schedule_seat_jobs(
         %{meeting: %MeetingSchema{status: :awaiting_verification} = meeting} = booking,
         nil,
         opts
       ),
       do: SlotActivation.activate_seat_in_transaction(meeting, booking.participant, opts)

  defp schedule_seat_jobs(booking, nil, opts) do
    %{meeting: meeting, participant: participant, created_meeting?: created?} = booking

    SlotActivation.schedule_seat_effects(meeting, participant, created?, opts)
  end

  defp hold_slot_until(
         %{
           created_meeting?: false,
           meeting: %MeetingSchema{status: :awaiting_verification} = slot
         },
         deadline
       ),
       do: MeetingQueries.extend_verification_deadline(slot.id, deadline)

  defp hold_slot_until(_booking, _deadline), do: :ok

  # Used only when this seat creates the slot.
  defp group_meeting_attrs(meeting_attrs, meeting_type, nil),
    do: SeatEffects.slot_attrs(meeting_attrs, meeting_type.name)

  defp group_meeting_attrs(meeting_attrs, meeting_type, %DateTime{} = deadline) do
    meeting_attrs
    |> SeatEffects.slot_attrs(meeting_type.name)
    |> Map.merge(%{status: :awaiting_verification, verification_deadline_at: deadline})
  end

  defp build_seat_request(meeting_attrs, booking_data, deadline) do
    %{form_data: form_data, meeting_type: meeting_type} = booking_data

    %{
      participant: %{
        name: form_data["name"],
        email: form_data["email"],
        phone: Map.get(form_data, "phone"),
        company: Map.get(form_data, "company"),
        message: Map.get(form_data, "message"),
        timezone: booking_data.user_timezone,
        locale: booking_data.attendee_locale,
        custom_field_answers: booking_data.custom_field_answers,
        verification_deadline_at: deadline,
        series_id: Map.get(meeting_attrs, :series_id),
        series_position: Map.get(meeting_attrs, :series_position)
      },
      guest_emails: guest_emails(booking_data),
      max_participants: meeting_type.max_participants
    }
  end

  @doc """
  The guests the booker brings to the seat: those submitted, cleaned and
  capped by the type's guest limit, or none on a type that takes no guests.
  Each takes a seat of their own.
  """
  @spec guest_emails(map()) :: [String.t()]
  def guest_emails(%{meeting_type: meeting_type, form_data: form_data} = booking_data) do
    booker_guests(Map.get(booking_data, :guest_emails, []), form_data["email"], meeting_type)
  end

  @doc """
  The seats a booking of `meeting_type` takes: the booker's, and one for
  each guest they bring, counted by the rule the booking is held and
  charged by (`guest_emails/1`): the booker's own address, a repeat or an
  invalid address takes no seat, and guests past the type's limit or on a
  type that takes none are dropped. The booking form shows its total from
  this, so the submit never promises a price the checkout does not charge.
  """
  @spec seats_for([String.t()] | nil, String.t() | nil, map() | nil) :: pos_integer()
  def seats_for(guest_emails, booker_email, meeting_type),
    do: 1 + length(booker_guests(guest_emails, booker_email, meeting_type))

  defp booker_guests(guest_emails, booker_email, meeting_type) do
    if Policy.guests_allowed?(%{meeting_type: meeting_type}) do
      Guests.sanitize_emails(guest_emails, booker_email, Guests.limit_for(meeting_type))
    else
      []
    end
  end
end
