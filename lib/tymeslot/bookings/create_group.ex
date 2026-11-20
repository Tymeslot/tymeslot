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
  alias Tymeslot.Bookings.Telemetry
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingPayments.Checkout
  alias Tymeslot.Meetings.GroupScheduling
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Meetings.SeatHoldSchema
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.FixedDates
  alias Tymeslot.MeetingTypes.GroupAccess
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Notifications.Events.Seats

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

  On a paid type the booker's seats are held instead (`SeatHolds`) for as
  long as the Stripe Checkout opened for them stays open, and
  `{:ok, :payment_required, %{meeting:, seat_hold:, checkout_url:}}` is
  returned. Nothing is enqueued for a hold: the seat's jobs and emails
  follow its payment. The checkout is opened once the hold has committed,
  never inside the seat transaction, which holds the organiser's schedule
  lock; a checkout that cannot be opened releases the hold at once.

  Options are the same ones `Tymeslot.Bookings.Create.execute/3` accepts;
  only `:with_video_room` matters here (see `SeatEffects.schedule_new_slot_effects/2`),
  and only for a free seat: a held seat's jobs follow its payment.
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
      # A held seat schedules nothing, so takes no options; a paid group
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
    |> GroupScheduling.book_seat(build_seat_request(meeting_attrs, booking_data),
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

    meeting_attrs
    |> SeatEffects.slot_attrs(meeting_type.name)
    |> GroupScheduling.book_seat(build_seat_request(meeting_attrs, booking_data),
      on_booked: &schedule_seat_jobs(&1, opts),
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
  again where it still has room, on a new meeting when nobody holds it,
  except on a fixed-date type, whose sessions only its host plans.

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
      on_booked: &schedule_seat_jobs(&1, []),
      new_slot: &late_slot/2
    )
  end

  # The type as it stands now decides whether it takes a new meeting, and
  # its limit is the new meeting's capacity.
  defp late_slot(hold, meeting) do
    case meeting.meeting_type_id &&
           MeetingTypes.get_meeting_type(meeting.meeting_type_id, meeting.organizer_user_id) do
      %MeetingTypeSchema{} = type ->
        if FixedDates.sessions?(type),
          do: :none,
          else: {:ok, fn -> late_slot_attrs(meeting, hold) end, type.max_participants}

      _deleted ->
        :none
    end
  end

  defp late_slot_attrs(meeting, hold) do
    times = %{
      start_time: meeting.start_time,
      end_time: meeting.end_time,
      duration_minutes: div(DateTime.diff(meeting.end_time, meeting.start_time), 60)
    }

    SeatEffects.rebuilt_slot_attrs(meeting, times, hold)
  end

  defp map_result({:ok, %{meeting: meeting, on_booked_result: pending}}, _booking_data) do
    :ok = Activation.after_commit(pending)
    Telemetry.booking_created()
    SeatEffects.broadcast_and_invalidate(meeting)

    {:ok, meeting}
  end

  defp map_result({:error, :slot_full}, _booking_data), do: {:error, :slot_taken}

  # The booker's email already has a seat or a hold on the slot, found under
  # the lock before the insert (see `GroupScheduling.book_seat/3`).
  defp map_result({:error, :already_booked}, _booking_data), do: {:error, :already_booked}

  # `book_seat/3` exhausts its retry on a rare first-booker index collision
  # and surfaces the raw changeset. Its `organizer_user_id` error is worded
  # for an organiser double-booking themselves, which a group booker must
  # never see, so this collapses to the same `:slot_taken` outcome as every
  # other lost-race case. A duplicate seat is worth naming: the booker has
  # this slot already, most likely from a second tab, and "try again" is the
  # wrong advice.
  defp map_result({:error, %Ecto.Changeset{} = changeset}, booking_data) do
    cond do
      MeetingSchema.unique_slot_violation?(changeset) -> {:error, :slot_taken}
      ParticipantSchema.duplicate_seat?(changeset) -> {:error, :already_booked}
      true -> {:error, Errors.classify_creation_error(changeset, booking_data)}
    end
  end

  defp map_result({:error, reason}, booking_data),
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
  # A seat sending no emails (`emails: false`) has no confirmation for a
  # room to hold back, so a room it creates is scheduled without one. It is
  # a seat of a booking series, so it owes no integration fan-out either:
  # the series is announced whole (`Tymeslot.BookingSeries.Automation`).
  defp schedule_seat_jobs(booking, opts) do
    %{meeting: meeting, participant: participant, created_meeting?: created?} = booking
    emails? = Keyword.get(opts, :emails, true)

    with {:ok, _job} <- SeatEffects.schedule_calendar_job(meeting, created?),
         {:ok, defer_emails?} <- schedule_new_slot_jobs(created?, meeting, emails?, opts),
         {{:ok, _scheduled}, pending} <-
           Seats.seat_booked_deferred(meeting, participant,
             defer_emails?: defer_emails?,
             emails: emails?,
             integrations: emails?
           ) do
      {:ok, pending}
    else
      {{:error, reason}, _pending} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp schedule_new_slot_jobs(false, _meeting, _emails?, _opts), do: {:ok, false}

  defp schedule_new_slot_jobs(true, meeting, emails?, opts),
    do: SeatEffects.schedule_new_slot_effects(meeting, Keyword.put(opts, :announce, emails?))

  defp build_seat_request(meeting_attrs, booking_data) do
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
