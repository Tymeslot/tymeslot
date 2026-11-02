defmodule TymeslotWeb.OnboardingCompositionTest do
  @moduledoc """
  Composition tests for the onboarding LiveView: a host with a calendar
  already connected sees it as a read-only row, and that connection alone
  enables Continue on the calendar step.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :onboarding
  @moduletag :live

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory
  import TymeslotWeb.OnboardingTestHelpers

  alias Tymeslot.Integrations.Calendar

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    {:ok, conn: setup_onboarding_session(tags.conn)}
  end

  describe "connected calendar row" do
    test "renders connected calendars read-only and enables Continue",
         %{conn: conn} do
      user = insert(:user, onboarding_completed_at: nil)

      existing_calendar =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          provider_account_email: "work@example.com",
          name: "Existing Work Calendar"
        )

      insert(:profile, user: user, username: "existing#{System.unique_integer([:positive])}")

      # Skip the fixture helper because we need a pre-existing
      # integration — setup_onboarding inserts none by default.
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/onboarding/connect_calendar")

      html = render(view)

      # The connected calendar renders as a read-only row, not a button.
      assert has_element?(view, "div.onboarding-connected-calendar")
      assert html =~ "work@example.com"
      assert html =~ "Caldav · Connected"

      # An existing connection enables Continue (it is not disabled), even
      # without selecting a provider choice.
      refute has_element?(view, "button[phx-click='next_step'][disabled]")

      # The connected calendar still exists in the DB.
      assert {:ok, _refreshed} = Calendar.get_integration(existing_calendar.id, user.id)
      assert length(Calendar.list_integrations(user.id)) == 1
    end
  end
end
