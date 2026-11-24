defmodule TymeslotWeb.E2E.FlashAutoDismissTest do
  use TymeslotWeb.BrowserCase, async: false

  alias Fluffy.Playwright.Clock
  alias Tymeslot.Announcements
  alias Tymeslot.AnnouncementsSingleTestCatalog
  alias Tymeslot.Repo

  @moduletag :e2e
  @moduletag :notifications

  # A flash dismisses itself after six seconds. It used to do so by clicking
  # itself, and that synthetic click reached every open `<.modal>` as a click
  # outside it, so signing in with an unseen announcement lost the "What's new"
  # modal, and marked the announcement seen, without the user touching anything.
  #
  # Only a browser runs the Flash hook, LiveView's click-away and the modal
  # together, which is why this lives here rather than in a LiveView test.

  setup do
    previous_catalogs = Application.get_env(:tymeslot, :announcement_catalogs)
    Application.put_env(:tymeslot, :announcement_catalogs, [AnnouncementsSingleTestCatalog])

    on_exit(fn ->
      Application.put_env(:tymeslot, :announcement_catalogs, previous_catalogs)
    end)

    :ok
  end

  test "the sign-in flash dismisses itself and leaves the announcement modal open",
       %{session: session} do
    # The page's timers run on a fake clock, so the test moves the flash's six
    # seconds on rather than waiting them out.
    {session, user} =
      session
      |> Clock.install()
      |> log_in_via_browser(%{
        # Before the test announcement was published, so it is unseen.
        inserted_at: ~N[2025-12-01 00:00:00],
        dashboard_tour_seen_at: DateTime.utc_now(:second)
      })

    session
    |> assert_has(by_css("#app-flash-group-info"))
    |> assert_has(
      filter(by_css("#announcement-modal-modal"), has_text: "Single test announcement")
    )
    # Removed once the dismissal has reached the server and come back.
    |> Clock.run_for(6_000)
    |> assert(count(by_css("#app-flash-group-info"), 0))
    |> assert_has(
      filter(by_css("#announcement-modal-modal"), has_text: "Single test announcement")
    )

    assert [%{key: "test_solo"}] = Announcements.list_for(Repo.reload!(user))

    # The modal is still the user's to close, and closing it is what marks the
    # announcement seen.
    session
    |> click(by_role(:button, name: "Got it"))
    |> assert(count(by_css("#announcement-modal-modal"), 0))

    assert Announcements.list_for(Repo.reload!(user)) == []
  end
end
