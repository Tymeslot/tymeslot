defmodule TymeslotWeb.E2E.FlashAutoDismissTest do
  use TymeslotWeb.BrowserCase, async: false

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

    # The flash outlives Wallaby's default wait, and the assertion that it has
    # gone must be allowed to wait it out.
    previous_wait = Application.get_env(:wallaby, :max_wait_time)
    Application.put_env(:wallaby, :max_wait_time, 10_000)

    on_exit(fn ->
      Application.put_env(:tymeslot, :announcement_catalogs, previous_catalogs)
      restore_env(:wallaby, :max_wait_time, previous_wait)
    end)

    :ok
  end

  feature "the sign-in flash dismisses itself and leaves the announcement modal open",
          %{session: session} do
    {session, user} =
      log_in_via_browser(session, %{
        # Before the test announcement was published, so it is unseen.
        inserted_at: ~N[2025-12-01 00:00:00],
        dashboard_tour_seen_at: DateTime.utc_now(:second)
      })

    session
    |> assert_has(css("#app-flash-group-info"))
    |> assert_has(css("#announcement-modal-modal", text: "Single test announcement"))
    # Removed once the dismissal has reached the server and come back.
    |> assert_has(css("#app-flash-group-info", count: 0, visible: :any))
    |> assert_has(css("#announcement-modal-modal", text: "Single test announcement"))

    assert [%{key: "test_solo"}] = Announcements.list_for(Repo.reload!(user))

    # The modal is still the user's to close, and closing it is what marks the
    # announcement seen.
    session
    |> click(button("Got it"))
    |> assert_has(css("#announcement-modal-modal", count: 0, visible: :any))

    assert Announcements.list_for(Repo.reload!(user)) == []
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
