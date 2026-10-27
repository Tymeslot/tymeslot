defmodule TymeslotWeb.Live.Scheduling.PaidTypeUnsellablePageTest do
  @moduledoc """
  The public booking page of a host with a paid meeting type who cannot take
  payments right now (Stripe disconnected, or a plan without payments): the
  paid type is not offered at all, neither on the listing nor through its
  direct link, since the submit would refuse every booking on it. Their free
  types are unaffected, and a host who can take payments offers both.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :payments
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.AvailabilityTestHelpers, only: [open_schedule_for: 1]
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Profiles
  alias Tymeslot.TestMocks
  alias TymeslotWeb.ThemeTestMatrix

  setup tags do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    # Core leaves payments off for self-hosters; on here, so the only thing
    # deciding whether the host can take payments is their Stripe account.
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      meeting_payments_enabled: true
    )

    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: "unsellable-#{System.unique_integer([:positive])}",
        timezone: "Etc/UTC"
      )

    # A host the page is ready for: a schedule and a connected calendar.
    open_schedule_for(profile)
    insert(:calendar_integration, user: user, is_active: true)

    insert(:meeting_type,
      user: user,
      name: "Paid Consult",
      payment_required: true,
      price_cents: 5000
    )

    insert(:meeting_type, user: user, name: "Free Call")

    %{profile: profile, user: user}
  end

  defp duration_option(slug),
    do: "[data-testid='duration-option'][phx-value-duration='#{slug}']"

  defp connect_stripe(user, charges_enabled) do
    insert(:connect_account,
      user: user,
      default_currency: "eur",
      charges_enabled: charges_enabled
    )
  end

  describe "a host who can take payments" do
    setup %{user: user}, do: %{account: connect_stripe(user, true)}

    @tag :capture_log
    test "offers the paid type on the listing and by its link",
         %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=UTC")

      assert has_element?(view, duration_option("paid-consult"))
      assert has_element?(view, duration_option("free-call"))
      assert {:ok, _view, _html} = live(conn, "/#{profile.username}/paid-consult")
    end
  end

  describe "a host whose Stripe account cannot take charges" do
    setup %{user: user}, do: %{account: connect_stripe(user, false)}

    for theme <- ThemeTestMatrix.all() do
      @theme theme

      @tag :capture_log
      test "#{theme.slug}'s overview leaves the paid type out",
           %{conn: conn, profile: profile} do
        {:ok, profile} = Profiles.update_booking_theme(profile, @theme.id)

        {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=UTC")

        assert has_element?(view, duration_option("free-call"))
        refute has_element?(view, duration_option("paid-consult"))
      end
    end

    @tag :capture_log
    test "its direct link sends the visitor back to the host's page",
         %{conn: conn, profile: profile} do
      assert {:error, {:redirect, %{to: to, flash: flash}}} =
               live(conn, "/#{profile.username}/paid-consult")

      assert to == "/#{profile.username}"
      assert flash["error"] =~ "Invalid meeting type"
    end
  end

  describe "a host with no Stripe account at all" do
    @tag :capture_log
    test "leaves the paid type out", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=UTC")

      assert has_element?(view, duration_option("free-call"))
      refute has_element?(view, duration_option("paid-consult"))
    end
  end
end
