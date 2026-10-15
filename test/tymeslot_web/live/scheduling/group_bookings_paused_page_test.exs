defmodule TymeslotWeb.Live.Scheduling.GroupBookingsPausedPageTest do
  @moduledoc """
  The public booking page of a host who has lost access to group bookings:
  their group type is not offered at all, neither on the listing nor through
  its direct link, since the submit would refuse every seat on it. Their
  one-to-one types are unaffected, and Core's default checker offers both.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :bookings
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.AvailabilityTestHelpers, only: [open_schedule_for: 1]
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.TestMocks

  defmodule DenyGroupBookingsChecker do
    @moduledoc false
    @behaviour Tymeslot.Features.CheckerBehaviour

    @impl Tymeslot.Features.CheckerBehaviour
    def check_access(_user_id, :group_bookings_allowed), do: {:error, :insufficient_plan}
    def check_access(_user_id, _feature), do: :ok
  end

  setup tags do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: "paused-#{System.unique_integer([:positive])}",
        timezone: "Etc/UTC"
      )

    # A host the page is ready for: a schedule and a connected calendar.
    open_schedule_for(profile)
    insert(:calendar_integration, user: user, is_active: true)

    venue = insert(:venue, user: user, name: "Main Hall")

    insert(:meeting_type,
      user: user,
      name: "Workshop",
      max_participants: 3,
      locations: [in_person_location([venue])]
    )

    insert(:meeting_type, user: user, name: "Solo Call")

    %{profile: profile}
  end

  defp duration_option(slug),
    do: "[data-testid='duration-option'][phx-value-duration='#{slug}']"

  @tag :capture_log
  test "Core's default offers the group type", %{conn: conn, profile: profile} do
    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=UTC")

    assert has_element?(view, duration_option("workshop"))
    assert has_element?(view, duration_option("solo-call"))
    assert {:ok, _view, _html} = live(conn, "/#{profile.username}/workshop")
  end

  describe "once the host has lost access to group bookings" do
    setup do
      setup_config(:tymeslot, :feature_access_checker, DenyGroupBookingsChecker)
    end

    @tag :capture_log
    test "the listing leaves the group type out", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=UTC")

      assert has_element?(view, duration_option("solo-call"))
      refute has_element?(view, duration_option("workshop"))
    end

    @tag :capture_log
    test "its direct link sends the visitor back to the host's page",
         %{conn: conn, profile: profile} do
      assert {:error, {:redirect, %{to: to, flash: flash}}} =
               live(conn, "/#{profile.username}/workshop")

      assert to == "/#{profile.username}"
      assert flash["error"] =~ "Invalid meeting type"
    end
  end
end
