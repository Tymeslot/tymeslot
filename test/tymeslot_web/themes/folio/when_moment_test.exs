defmodule TymeslotWeb.Themes.Folio.WhenMomentTest do
  @moduledoc """
  Folio's time section rendered alone: a fully booked month says so and
  offers the way to the first free day the page landed on, and says there
  are no free times when it landed on none.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :components

  import Phoenix.LiveViewTest, only: [render_component: 2]
  import Tymeslot.Factory

  alias TymeslotWeb.Themes.Folio.Scheduling.Components.WhenMoment

  setup do
    Gettext.put_locale(TymeslotWeb.Gettext, "en")
    :ok
  end

  # March 2030 on show with nothing free in it.
  defp when_moment(overrides) do
    assigns =
      Map.merge(
        %{
          id: "when-step",
          moment: :when,
          moment_state: :current,
          locale: "en",
          organizer_profile: build(:profile, full_name: "Mia Laurent", username: "mia"),
          meeting_type:
            build(:meeting_type, name: "Quick Chat", slug: "quick-chat", duration_minutes: 30),
          user_timezone: "Etc/UTC",
          current_year: 2030,
          current_month: 3,
          week_start: :monday,
          booking_window_days: 90,
          month_availability_map: %{},
          availability_status: :loaded,
          calendar_landing: nil,
          selected_date: nil,
          selected_time: nil,
          available_slots: [],
          loading_slots: false,
          calendar_error: nil,
          slot_interval_minutes: 30,
          duration_minutes: 30,
          expanded_hour: nil,
          timezone_dropdown_open: false,
          timezone_search: ""
        },
        Map.new(overrides)
      )

    WhenMoment |> render_component(assigns) |> Floki.parse_fragment!()
  end

  defp text(doc, selector),
    do: doc |> Floki.find(selector) |> Floki.text() |> String.split() |> Enum.join(" ")

  test "a fully booked month offers the first free day elsewhere" do
    landing = %{
      current_year: 2030,
      current_month: 4,
      current_week_start: ~D[2030-04-01],
      selected_date: "2030-04-02"
    }

    doc = when_moment(calendar_landing: landing)

    assert text(doc, "[data-testid='folio-month-empty'] p") == "I'm fully booked this month."
    assert [button] = Floki.find(doc, "[data-testid='folio-next-free-day']")
    assert Floki.attribute(button, "phx-click") == ["first_available_week"]
  end

  test "says nothing of the kind while the month has a free day" do
    doc = when_moment(month_availability_map: %{"2030-03-20" => true})

    assert Floki.find(doc, "[data-testid='folio-month-empty']") == []
  end

  test "with no free day anywhere, says there are no free times and offers no way" do
    doc = when_moment(calendar_landing: nil)

    assert text(doc, "[data-testid='folio-month-empty']") == "I have no free times at the moment."
    assert Floki.find(doc, "[data-testid='folio-next-free-day']") == []
  end
end
