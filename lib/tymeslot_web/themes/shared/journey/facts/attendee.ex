defmodule TymeslotWeb.Themes.Shared.Journey.Facts.Attendee do
  @moduledoc """
  The attendee: the booking form, its location answer and its guests, and
  the submit that ends the booking.

  Needs the slot, and the answers when the meeting type has questions.
  Showing a moment that collects it sets the form up
  (`StepEntry.handle_booking_entry/2`): the submission token, the reschedule
  prefill, and for a `/book` link without a day and a time the redirect to
  the schedule step. Known once a booking was made for the attendee. Its
  guests are part of it, not a fact of their own: they are fields of one
  form.
  """

  use TymeslotWeb.Themes.Shared.Journey.Fact

  import Phoenix.Component, only: [assign: 2]

  alias TymeslotWeb.Live.Scheduling.OrganizerHelpers
  alias TymeslotWeb.Themes.Shared.BookingFlow
  alias TymeslotWeb.Themes.Shared.BookingLocation
  alias TymeslotWeb.Themes.Shared.GuestBooking
  alias TymeslotWeb.Themes.Shared.Journey.Fact
  alias TymeslotWeb.Themes.Shared.Journey.Facts.Answers
  alias TymeslotWeb.Themes.Shared.Journey.Runtime
  alias TymeslotWeb.Themes.Shared.LiveHelpers.StepEntry

  @events [
    :validate,
    :field_blur,
    :select_location,
    :select_video_provider,
    :select_venue,
    :location_phone,
    :toggle_guests,
    :close_guests,
    :guest_input,
    :add_guest,
    :remove_guest,
    :submit
  ]

  @impl Fact
  def key, do: :attendee

  @impl Fact
  def requires(assigns),
    do: if(Answers.required?(assigns), do: [:slot, :answers], else: [:slot])

  @impl Fact
  def required?(_assigns), do: true

  # A booking was made: its meeting's uid, or, for a seat on a group
  # meeting, whose uid names the shared slot and is never the booker's, the
  # seat's own calendar link (`BookingSubmissionHandlerComponent`).
  @impl Fact
  def known?(assigns), do: booked?(assigns[:meeting_uid]) or booked?(assigns[:seat_calendar_url])

  @impl Fact
  def events, do: @events

  @impl Fact
  def handle(socket, :validate, data), do: BookingFlow.handle_form_validation(socket, data)

  def handle(socket, :field_blur, field),
    do: {:noreply, OrganizerHelpers.mark_field_touched(socket, field)}

  def handle(socket, event, data)
      when event in [:select_location, :select_video_provider, :select_venue, :location_phone],
      do: {:noreply, BookingLocation.apply_event(socket, event, data)}

  def handle(socket, :toggle_guests, _data), do: {:noreply, GuestBooking.open(socket)}
  def handle(socket, :close_guests, _data), do: {:noreply, GuestBooking.close(socket)}
  def handle(socket, :guest_input, data), do: {:noreply, GuestBooking.set_input(socket, data)}
  def handle(socket, :add_guest, data), do: {:noreply, GuestBooking.add(socket, data)}
  def handle(socket, :remove_guest, data), do: {:noreply, GuestBooking.remove(socket, data)}

  def handle(socket, :submit, data),
    do: BookingFlow.submit_booking(socket, data, &Runtime.transition_to/3)

  @impl Fact
  def enter(socket, params), do: StepEntry.handle_booking_entry(socket, params)

  # The submit ends this fact; a "next" sent from the form moves nothing.
  @impl Fact
  def continue(socket), do: {:stay, socket}

  # The attendee moment makes a fresh token each time it opens again, and
  # forgetting the attendee forgets the booking made (`meeting_uid`, or a
  # seat's `seat_calendar_url`).
  @impl Fact
  def clear(socket),
    do:
      assign(socket,
        submission_token: nil,
        submission_processed: false,
        meeting_uid: nil,
        seat_calendar_url: nil
      )

  defp booked?(value), do: is_binary(value) and value != ""
end
