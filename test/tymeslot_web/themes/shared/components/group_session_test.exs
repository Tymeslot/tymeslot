defmodule TymeslotWeb.Themes.Shared.Components.GroupSessionTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :themes
  @moduletag :components
  @moduletag :bookings

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Themes.Shared.Components.GroupSession

  # A demo organiser's types are plain maps, so the component reads them as such.
  @group %{max_participants: 4}
  @solo %{max_participants: 1}

  describe "hint/1" do
    test "names how many people a group type takes" do
      html = render_component(&GroupSession.hint/1, %{meeting_type: @group})

      assert html =~ ~s(data-testid="group-session-hint")
      assert html =~ "Group session · up to 4 people"
    end

    test "renders nothing for a one-to-one type, or none" do
      assert render_component(&GroupSession.hint/1, %{meeting_type: @solo}) == ""
      assert render_component(&GroupSession.hint/1, %{meeting_type: nil}) == ""
    end
  end

  describe "confirmation_line/1" do
    test "says the booking is one of the session's spots" do
      html = render_component(&GroupSession.confirmation_line/1, %{meeting_type: @group})

      assert html =~ "Group session: you have one of 4 spots."
    end

    test "renders nothing for a one-to-one type" do
      assert render_component(&GroupSession.confirmation_line/1, %{meeting_type: @solo}) == ""
    end
  end

  describe "seat_move_notice/1" do
    test "states the spot's current time in the visitor's timezone" do
      html =
        render_component(&GroupSession.seat_move_notice/1, %{
          from: ~U[2030-10-05 17:00:00Z],
          timezone: "Europe/London"
        })

      assert html =~ ~s(data-testid="seat-move-notice")
      assert html =~ "Moving your spot on 5 October 2030 at 06:00 PM BST"
    end

    test "renders nothing when no spot is moving" do
      assert render_component(&GroupSession.seat_move_notice/1, %{from: nil}) == ""
    end
  end
end
