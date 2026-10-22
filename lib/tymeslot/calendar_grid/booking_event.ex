defmodule Tymeslot.CalendarGrid.BookingEvent do
  @moduledoc """
  A Tymeslot booking projected into the calendar grid's event shape.

  The grid renders cached provider events; this struct mirrors the fields that
  rendering path reads (`summary`, `start_at`, `end_at`, `all_day`, `uid`,
  `created_by_tymeslot`, …) so bookings flow through the same layout, colour
  and badge code without a second rendering path. `kind: :booking`
  distinguishes it where behaviour must differ: booking entries are read-only
  on the grid (no drag, resize or inline edit) and open a booking detail
  modal instead of the provider-event editor.

  The calendar keeps this projection and drops the calendar copy Tymeslot
  wrote for it (`Tymeslot.CalendarGrid.EventWindow`),
  recording in `copy` which calendar the copy sits in
  (`%{calendar_integration_id, provider_calendar_id, calendar_name}`).

  `meeting_type` is the meeting type's name as booked, the second half of
  the grid's "Anna Kowalski · Intro call". `request` says the booking is a
  request still awaiting the organiser's answer, and `expired` that it can
  no longer be answered (the deadline or its start has passed, or the sweep
  has already expired it), with `approval_deadline_at` beside them.

  A group meeting has no attendee: its people are its live participants,
  carried in `participants` (empty for a one-to-one booking), with its
  `capacity` and the `seats_taken` (participants plus their guests) beside
  them. A one-to-one booking keeps a capacity of 1 and no seat count.

  `move_offer` is the time the booking can follow its calendar event to
  (`Tymeslot.Meetings.calendar_move_offers/1`), when the host moved that
  event in their own calendar, and nil otherwise.

  `guests` are the people invited to the meeting through Tymeslot whose
  invitation still stands, each with the answer they gave (`status`:
  `"pending"`, `"accepted"` or `"declined"`), read by the preview
  (`Tymeslot.CalendarGrid.GuestReplies`).
  """

  @enforce_keys [:id, :meeting_id, :summary, :start_at, :end_at]
  defstruct [
    :id,
    :meeting_id,
    :uid,
    :summary,
    :location,
    :start_at,
    :end_at,
    :attendee_name,
    :attendee_email,
    :join_url,
    :provider_event_id,
    :meeting_type,
    :approval_deadline_at,
    :move_offer,
    participants: [],
    guests: [],
    capacity: 1,
    planned: false,
    seats_taken: 0,
    all_day: false,
    calendar_integration_id: nil,
    provider_calendar_id: nil,
    colour: nil,
    status: "confirmed",
    transparency: "opaque",
    created_by_tymeslot: true,
    kind: :booking,
    request: false,
    expired: false,
    copy: nil
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          meeting_id: Ecto.UUID.t(),
          uid: String.t() | nil,
          summary: String.t(),
          location: String.t() | nil,
          start_at: DateTime.t(),
          end_at: DateTime.t(),
          attendee_name: String.t() | nil,
          attendee_email: String.t() | nil,
          join_url: String.t() | nil,
          provider_event_id: String.t() | nil,
          meeting_type: String.t() | nil,
          approval_deadline_at: DateTime.t() | nil,
          move_offer: nil | %{start_time: DateTime.t(), end_time: DateTime.t()},
          participants: [%{name: String.t() | nil, email: String.t()}],
          guests: [%{name: String.t() | nil, email: String.t(), status: String.t()}],
          capacity: pos_integer(),
          planned: boolean(),
          seats_taken: non_neg_integer(),
          all_day: false,
          calendar_integration_id: nil,
          provider_calendar_id: nil,
          colour: nil,
          status: String.t(),
          transparency: String.t(),
          created_by_tymeslot: true,
          kind: :booking,
          request: boolean(),
          expired: boolean(),
          copy:
            nil
            | %{
                calendar_integration_id: pos_integer(),
                provider_calendar_id: String.t() | nil,
                calendar_name: String.t() | nil
              }
        }
end
