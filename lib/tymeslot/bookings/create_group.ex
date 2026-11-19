defmodule Tymeslot.Bookings.CreateGroup do
  @moduledoc """
  Books a seat on a group meeting type (`max_participants > 1`) through
  `Tymeslot.Meetings.GroupScheduling.book_seat/3`.

  Kept apart from `Tymeslot.Bookings.Create`, which remains the sole entry point
  booking callers use: it resolves the meeting type and builds the (pre-booker)
  meeting attributes, then dispatches here once `applicable?/1` says the meeting
  type holds more than one seat.
  """

  alias Tymeslot.Bookings.Activation
  alias Tymeslot.Bookings.Errors
  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Bookings.SeatEffects
  alias Tymeslot.Bookings.Telemetry
  alias Tymeslot.Meetings.GroupScheduling
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantSchema
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

  Options are the same ones `Tymeslot.Bookings.Create.execute/3` accepts;
  only `:with_video_room` matters here (see `SeatEffects.schedule_new_slot_effects/2`).
  """
  @spec create(map(), map(), keyword()) :: {:ok, map()} | {:error, Errors.classified_error()}
  def create(meeting_attrs, booking_data, opts \\ []) do
    meeting_attrs
    |> book_seat(booking_data, opts)
    |> map_result(booking_data)
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

  defp map_result({:ok, %{meeting: meeting, on_booked_result: pending}}, _booking_data) do
    :ok = Activation.after_commit(pending)
    Telemetry.booking_created()
    SeatEffects.broadcast_and_invalidate(meeting)

    {:ok, meeting}
  end

  defp map_result({:error, :slot_full}, _booking_data), do: {:error, :slot_taken}

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
  def guest_emails(booking_data) do
    if Policy.guests_allowed?(booking_data) do
      %{form_data: form_data} = booking_data

      booking_data
      |> Map.get(:guest_emails, [])
      |> Guests.sanitize_emails(form_data["email"], Guests.limit_for(booking_data.meeting_type))
    else
      []
    end
  end
end
