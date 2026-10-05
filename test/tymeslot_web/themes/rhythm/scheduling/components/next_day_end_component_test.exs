defmodule TymeslotWeb.Themes.Rhythm.Scheduling.Components.NextDayEndComponentTest do
  use TymeslotWeb.ConnCase, async: true

  @moduledoc """
  The booking and confirmation steps name the end of a meeting that runs past
  midnight, rendered straight from the step's assigns so no schedule is needed.
  """
  @moduletag :themes
  @moduletag :bookings

  import Phoenix.Component, only: [to_form: 2]
  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias TymeslotWeb.Themes.Rhythm.Scheduling.Components.BookingComponent
  alias TymeslotWeb.Themes.Rhythm.Scheduling.Components.ConfirmationComponent

  @note "[data-testid='booking-next-day-end']"

  defp assigns(time, duration) do
    meeting_type = build(:meeting_type, duration_minutes: duration)

    %{
      id: "step",
      locale: "en",
      duration: "#{duration}min",
      meeting_type: meeting_type,
      selected_date: "2027-06-14",
      selected_time: time,
      user_timezone: "Europe/London",
      organizer_profile: build(:profile),
      username_context: "host",
      selected_duration: "#{duration}min",
      email: "guest@example.com",
      form: to_form(%{"name" => "", "email" => "", "message" => ""}, as: :booking),
      guest_emails: [],
      guest_error: nil,
      guest_input: "",
      guests_open: false,
      is_rescheduling: false,
      location_error: nil,
      location_options: [],
      location_phone: "",
      max_guests: 0,
      selected_location_id: nil,
      selected_venue_id: nil,
      selected_video_id: nil,
      submitting: false,
      validation_errors: %{},
      calendar_ics_path: nil,
      custom_field_answers: %{},
      custom_fields_snapshot: []
    }
  end

  for {name, component} <- [booking: BookingComponent, confirmation: ConfirmationComponent] do
    describe "the #{name} step" do
      test "names the end when the meeting runs past midnight" do
        html = render_component(unquote(component), assigns("11:00 PM", 120))

        assert [note] = html |> Floki.parse_document!() |> Floki.find(@note)
        assert Floki.text(note) =~ "Ends 01:00 AM on Tuesday 15 June"
      end

      test "says nothing for a meeting ending the day it starts" do
        html = render_component(unquote(component), assigns("10:00 PM", 60))

        assert html |> Floki.parse_document!() |> Floki.find(@note) == []
      end
    end
  end
end
