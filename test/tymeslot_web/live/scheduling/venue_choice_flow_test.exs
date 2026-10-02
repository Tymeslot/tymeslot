defmodule TymeslotWeb.Live.Scheduling.VenueChoiceFlowTest do
  @moduledoc """
  The booker's side of saved locations, on every theme: choosing between an
  in-person location's venues, being told a single venue, and being told the
  address will be arranged when the location has none, on the booking step
  and on the confirmation. Each booking is read back from the database.

  Picker events are driven by clicking the rendered radios, so the theme's
  own booking component relays them; `location_choice_flow_test.exs` covers
  the location row itself.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :scheduling
  @moduletag :live

  import Mox
  import Tymeslot.BookingTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias Tymeslot.Venues

  @themes [{"Quill", "1"}, {"Rhythm", "2"}]
  @note "The address will be arranged with you after booking."

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()

    old_cfg = Application.get_env(:tymeslot, :recaptcha, [])
    Application.put_env(:tymeslot, :recaptcha, Keyword.put(old_cfg, :booking_enabled, false))
    on_exit(fn -> Application.put_env(:tymeslot, :recaptcha, old_cfg) end)

    TestMocks.setup_all_mocks()

    %{user: insert(:user)}
  end

  defp submit(view, email) do
    view
    |> form("form[phx-submit='submit']", %{
      "booking" => %{"name" => "Booker", "email" => email, "message" => ""}
    })
    |> render_submit()

    _drain = :sys.get_state(view.pid)
    render(view)
  end

  defp pick_venue(view, venue) do
    view
    |> element("[data-testid='venue-option'][data-venue-id='#{venue.id}'] input")
    |> render_click()

    _drain = :sys.get_state(view.pid)
  end

  defp description_text(view, selector) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.find(selector)
    |> Floki.text()
  end

  for {theme_name, theme_id} <- @themes do
    describe "#{theme_name}: an in-person location offering two saved locations" do
      setup %{user: user} do
        berlin =
          insert(:venue,
            user: user,
            name: "Berlin office",
            description: "Friedrichstrasse 1\n3rd floor"
          )

        munich = insert(:venue, user: user, name: "Munich office", description: "Marienplatz 8")

        insert(:meeting_type,
          user: user,
          duration_minutes: 30,
          name: "Consultation",
          is_active: true,
          locations: [
            in_person_location([berlin, munich], id: "loc-offices", label: "Our offices")
          ]
        )

        %{
          profile: bookable_profile(user, unquote(theme_id), "venuebooker#{unquote(theme_id)}"),
          berlin: berlin,
          munich: munich
        }
      end

      @tag :capture_log
      test "asks which location, each with its address, the first preselected", ctx do
        view = navigate_to_booking_form(ctx.conn, ctx.profile, nil)

        assert has_element?(view, "[data-testid='venue-field']")

        offered =
          view
          |> render()
          |> Floki.parse_document!()
          |> Floki.attribute("[data-testid='venue-option']", "data-venue-id")

        assert offered == [to_string(ctx.berlin.id), to_string(ctx.munich.id)]
        assert has_element?(view, "[data-venue-id='#{ctx.berlin.id}'] input[checked]")

        # Exact, line break included: themes show it with `pre-line`, so any
        # whitespace around it would render as blank lines.
        assert description_text(
                 view,
                 "[data-venue-id='#{ctx.berlin.id}'] .location-venue__description"
               ) ==
                 "Friedrichstrasse 1\n3rd floor"

        assert has_element?(view, "[data-testid='venue-option']", "Marienplatz 8")
        refute has_element?(view, "[data-testid='location-arranged-note']")
      end

      @tag :capture_log
      test "books the location the booker picked and confirms it", ctx do
        view = navigate_to_booking_form(ctx.conn, ctx.profile, nil)

        pick_venue(view, ctx.munich)

        assert has_element?(view, "[data-venue-id='#{ctx.munich.id}'] input[checked]")

        submit(view, "munich@example.com")

        assert [meeting] = Repo.all_by(MeetingSchema, attendee_email: "munich@example.com")
        assert meeting.venue_id == ctx.munich.id
        assert meeting.location == "Munich office (Marienplatz 8)"

        assert has_element?(
                 view,
                 "[data-testid='confirmation-location']",
                 "Munich office (Marienplatz 8)"
               )

        refute has_element?(view, "[data-testid='location-arranged-note']")
      end

      @tag :capture_log
      test "confirms where the meeting was booked when the pick is deleted meanwhile", ctx do
        view = navigate_to_booking_form(ctx.conn, ctx.profile, nil)

        pick_venue(view, ctx.munich)

        # The host deletes Munich while the booker is on the booking step.
        assert {:ok, _deleted} = Venues.delete_venue(ctx.munich)

        submit(view, "moved@example.com")

        assert [meeting] = Repo.all_by(MeetingSchema, attendee_email: "moved@example.com")
        assert meeting.venue_id == ctx.berlin.id

        confirmed = description_text(view, "[data-testid='confirmation-location']")
        assert confirmed =~ "Berlin office"
        refute confirmed =~ "Munich"
      end
    end

    describe "#{theme_name}: an in-person location with one saved location" do
      setup %{user: user} do
        berlin =
          insert(:venue,
            user: user,
            name: "Berlin office",
            description: "Friedrichstrasse 1\n3rd floor"
          )

        insert(:meeting_type,
          user: user,
          duration_minutes: 30,
          name: "Consultation",
          is_active: true,
          locations: [in_person_location([berlin], id: "loc-office", label: "Our office")]
        )

        %{
          profile: bookable_profile(user, unquote(theme_id), "venuebooker#{unquote(theme_id)}"),
          berlin: berlin
        }
      end

      @tag :capture_log
      test "states the location and its address without asking, and books it", ctx do
        view = navigate_to_booking_form(ctx.conn, ctx.profile, nil)

        refute has_element?(view, "[data-testid='venue-field']")

        assert has_element?(
                 view,
                 "[data-testid='location-stated'] [data-testid='location-detail']",
                 "Friedrichstrasse 1"
               )

        assert description_text(
                 view,
                 "[data-testid='location-stated'] .location-field__venue-description"
               ) == "Friedrichstrasse 1\n3rd floor"

        refute has_element?(view, "[data-testid='location-arranged-note']")

        submit(view, "berlin@example.com")

        assert [meeting] = Repo.all_by(MeetingSchema, attendee_email: "berlin@example.com")
        assert meeting.venue_id == ctx.berlin.id
        assert meeting.location == "Berlin office (Friedrichstrasse 1, 3rd floor)"

        assert has_element?(
                 view,
                 "[data-testid='confirmation-location']",
                 "Berlin office (Friedrichstrasse 1, 3rd floor)"
               )

        refute has_element?(view, "[data-testid='location-arranged-note']")
      end
    end

    describe "#{theme_name}: an in-person location without an address" do
      setup %{user: user} do
        insert(:meeting_type,
          user: user,
          duration_minutes: 30,
          name: "Consultation",
          is_active: true,
          locations: [in_person_location([], id: "loc-in-person", label: "In person")]
        )

        %{profile: bookable_profile(user, unquote(theme_id), "venuebooker#{unquote(theme_id)}")}
      end

      @tag :capture_log
      test "says the address will be arranged, on the booking step and after booking", ctx do
        view = navigate_to_booking_form(ctx.conn, ctx.profile, nil)

        assert has_element?(view, "[data-testid='location-stated']", @note)

        submit(view, "arranged@example.com")

        assert has_element?(view, "[data-testid='confirmation-location']", "In person")
        assert has_element?(view, "[data-testid='location-arranged-note']", @note)

        assert [meeting] = Repo.all_by(MeetingSchema, attendee_email: "arranged@example.com")
        assert meeting.venue_id == nil
        assert meeting.location == "In person"
      end
    end
  end
end
