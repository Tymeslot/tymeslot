defmodule TymeslotWeb.Themes.NextDayEndComponentTest do
  use TymeslotWeb.ConnCase, async: true

  @moduledoc """
  The booking and confirmation steps of every shipped theme
  (`ThemeTestMatrix.all/0`; on Paper, the details part of its schedule
  screen in the booking step's place) name the end of a meeting that runs
  past midnight, rendered straight from the step's assigns so no schedule
  is needed.
  """
  @moduletag :themes
  @moduletag :bookings

  import Phoenix.Component, only: [to_form: 2]
  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias TymeslotWeb.Themes.Paper.Scheduling.Details
  alias TymeslotWeb.ThemeTestMatrix

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
      seat_calendar_url: nil,
      custom_field_answers: %{},
      custom_fields_snapshot: [],
      theme_tokens: nil,
      host_currency: nil
    }
  end

  # A shipped theme's step component follows from its key, as its theme
  # module does (`Themes.Core.Registry`).
  defp step(slug, name),
    do:
      Module.safe_concat([
        "TymeslotWeb.Themes",
        Macro.camelize(slug),
        "Scheduling.Components",
        name
      ])

  # Paper books on its schedule screen, whose details part (`Details.book/1`,
  # a function component given the screen's assigns and its target) holds
  # what the classic journey's booking step does.
  defp render_step("paper", "BookingComponent", assigns),
    do: render_component(&Details.book/1, Map.put(assigns, :target, nil))

  defp render_step(slug, name, assigns), do: render_component(step(slug, name), assigns)

  for theme <- ThemeTestMatrix.all(),
      {stage, component} <- [booking: "BookingComponent", confirmation: "ConfirmationComponent"] do
    describe "#{theme.name}'s #{stage} step" do
      @component {theme.slug, component}

      test "names the end when the meeting runs past midnight" do
        {slug, name} = @component
        html = render_step(slug, name, assigns("11:00 PM", 120))

        assert [note] = html |> Floki.parse_document!() |> Floki.find(@note)
        assert Floki.text(note) =~ "Ends 01:00 AM on Tuesday 15 June"
      end

      test "says nothing for a meeting ending the day it starts" do
        {slug, name} = @component
        html = render_step(slug, name, assigns("10:00 PM", 60))

        assert html |> Floki.parse_document!() |> Floki.find(@note) == []
      end
    end
  end
end
