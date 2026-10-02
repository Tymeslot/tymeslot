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

  Bookings already mirrored into a connected calendar are deduplicated at load
  time against the synced copy, so this struct chiefly represents bookings
  with no provider-side counterpart — most importantly every booking of a
  user with no calendar integration at all.

  A group meeting has no attendee: its people are its live participants,
  carried in `participants` (empty for a one-to-one booking), with its
  `capacity` and the `seats_taken` (participants plus their guests) beside
  them. A one-to-one booking keeps a capacity of 1 and no seat count.
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
    participants: [],
    capacity: 1,
    seats_taken: 0,
    all_day: false,
    calendar_integration_id: nil,
    provider_calendar_id: nil,
    colour: nil,
    status: "confirmed",
    transparency: "opaque",
    created_by_tymeslot: true,
    kind: :booking
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
          participants: [%{name: String.t() | nil, email: String.t()}],
          capacity: pos_integer(),
          seats_taken: non_neg_integer(),
          all_day: false,
          calendar_integration_id: nil,
          provider_calendar_id: nil,
          colour: nil,
          status: String.t(),
          transparency: String.t(),
          created_by_tymeslot: true,
          kind: :booking
        }
end
