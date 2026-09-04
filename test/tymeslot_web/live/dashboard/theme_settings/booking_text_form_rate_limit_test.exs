defmodule TymeslotWeb.Dashboard.ThemeSettings.BookingTextFormRateLimitTest do
  use TymeslotWeb.LiveCase, async: false

  @moduledoc """
  What the booking-page text form does when the shared theme-customisation rate
  limit refuses a save.

  The form has no save button and autosaves on a debounce, so the refused write
  is typically the last thing the host typed before walking away: dropping it
  loses work that was never theirs to lose, and the indicator promises a save
  that would never happen. The edit is therefore held and retried.

  `async: false` because the rate-limit buckets live in one shared ETS table
  that other modules clear in their own setup.
  """
  @moduletag :themes
  @moduletag :live
  @moduletag :security

  import Ecto.Changeset, only: [change: 2]
  import Tymeslot.DashboardTestHelpers

  alias Phoenix.LiveView
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Dashboard.ThemeSettings.BookingTextForm

  # Matches the bucket in Tymeslot.Security.RateLimiter.Dashboard.
  @writes_per_window 150

  setup do
    RateLimiter.clear_all()
    :ok
  end

  setup :setup_dashboard_user_with_theme

  setup %{profile: profile} do
    profile =
      profile
      |> change(%{
        username: "text-owner",
        full_name: "Sarah",
        booking_text_enabled: true,
        booking_heading: "Ready to grow your business?",
        booking_greeting: "I am Sarah.",
        booking_instruction: "Choose a session."
      })
      |> Repo.update!()

    {:ok, profile: profile}
  end

  describe "an edit the shared limit refuses" do
    test "is written once the bucket clears, not dropped", %{
      conn: conn,
      user: user,
      profile: profile
    } do
      exhaust_theme_customization_bucket(user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      html = edit(view, %{"booking_heading" => "Book a slot that suits you"})

      assert html =~ "saving shortly"
      assert Repo.reload!(profile).booking_heading == "Ready to grow your business?"

      # The bucket is shared with every other theme-customisation write, so it
      # clears on its own while the host is doing nothing.
      RateLimiter.clear_all()

      html = fire_retry(view)

      assert html =~ "All changes saved"
      assert Repo.reload!(profile).booking_heading == "Book a slot that suits you"
    end

    test "survives a retry that is refused as well", %{conn: conn, user: user, profile: profile} do
      exhaust_theme_customization_bucket(user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      edit(view, %{"booking_heading" => "Book a slot that suits you"})

      # Still throttled: the edit has to be kept and tried again rather than
      # spent on the one attempt the backoff happened to land on.
      html = fire_retry(view)

      assert html =~ "saving shortly"
      assert Repo.reload!(profile).booking_heading == "Ready to grow your business?"

      RateLimiter.clear_all()

      assert fire_retry(view) =~ "All changes saved"
      assert Repo.reload!(profile).booking_heading == "Book a slot that suits you"
    end

    test "loses to whatever the host typed after it", %{conn: conn, user: user, profile: profile} do
      exhaust_theme_customization_bucket(user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      edit(view, %{"booking_heading" => "First thought"})
      edit(view, %{"booking_heading" => "Second thought"})

      RateLimiter.clear_all()

      fire_retry(view)

      # The retry must write what the form now says, not the wording that
      # happened to be in hand when the limit hit.
      assert Repo.reload!(profile).booking_heading == "Second thought"
    end

    test "is not resurrected over a later edit that saved normally", %{
      conn: conn,
      user: user,
      profile: profile
    } do
      exhaust_theme_customization_bucket(user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      edit(view, %{"booking_heading" => "Throttled wording"})

      RateLimiter.clear_all()

      # This one is under the limit and writes immediately, which settles the
      # held edit: the scheduled retry that fires afterwards has nothing left
      # to do and must not overwrite the newer wording.
      assert edit(view, %{"booking_heading" => "Wording that saved"}) =~ "All changes saved"

      fire_retry(view)

      assert Repo.reload!(profile).booking_heading == "Wording that saved"
    end
  end

  defp exhaust_theme_customization_bucket(user) do
    for _write <- 1..@writes_per_window do
      assert :ok = RateLimiter.check_theme_customization_rate_limit(user.id)
    end

    assert {:error, :rate_limited, _message} =
             RateLimiter.check_theme_customization_rate_limit(user.id)
  end

  # Delivers the message the component's own backoff timer will deliver. Waiting
  # out the real `Process.send_after/3` would trade a deterministic test for a
  # slow, flaky one; the message itself is the contract under test.
  defp fire_retry(view) do
    LiveView.send_update(view.pid, BookingTextForm,
      id: "booking-text-form",
      retry_save: true
    )

    render(view)
  end

  defp edit(view, params) do
    view
    |> form("#booking-text-form form", profile_schema: params)
    |> render_change()
  end
end
