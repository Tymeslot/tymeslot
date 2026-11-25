defmodule TymeslotWeb.E2E.UnsavedChangesTest do
  @moduledoc """
  The `UnsavedChanges` hook (`assets/js/hooks/unsaved_changes.js`) on its two
  kinds of form:

    * An autosaving form (the display name in profile settings) asks before
      the tab is closed or reloaded while typed text is not yet saved, and
      stops asking once the server confirms the save. A value the server
      refuses keeps the guard up.
    * An explicit-submit editor (an open poll's editor) holds a link to
      another dashboard section while changes are unsaved, and lets it go
      only when the host says so.

  The LiveView tests stand in for the hook by sending its events by hand;
  these prove the hook itself holds, sends and follows them.

  The tab-close prompt is the browser's own dialog, which a driven browser
  does not show, so the guard is read where the browser decides: a
  cancellable `beforeunload` dispatched on the page, and whether a listener
  cancelled it.
  """

  use TymeslotWeb.BrowserCase, async: false

  @moduletag :e2e
  @moduletag :profiles
  @moduletag :polls

  alias Tymeslot.Polls
  alias Tymeslot.Profiles

  @display_name "#display-name-form input[name='full_name']"
  @display_name_status "#display-name-form-status"

  @editor "[data-testid='poll-editor']"
  @leave_modal "#leave-poll-editor-modal"
  @locations_link "a[data-phx-link][href='/dashboard/locations']"

  feature "the display name asks before the tab closes until its text is saved",
          %{session: session} do
    {session, user} = log_in_via_browser(session)

    session =
      session
      |> visit("/dashboard/settings")
      |> wait_for_live()
      |> assert_has(css(@display_name))

    refute leaving_held?(session), "a form with nothing typed held the tab"

    # Typed, still in the field: nothing has reached the server.
    session = fill_in(session, css(@display_name), with: "Ada Lovelace")
    assert leaving_held?(session), "typed text not yet saved did not hold the tab"

    # Leaving the field saves it, and the server's confirmation lets go.
    session =
      session
      |> send_keys([:tab])
      |> assert_has(css("#{@display_name_status}[data-autosave-status='saved']"))

    assert Profiles.get_profile(user.id).full_name == "Ada Lovelace"
    refute leaving_held?(session), "a saved display name still held the tab"

    # A value the server refuses stays unsaved, and so stays guarded. Typed
    # over the selected name, as a person would: `fill_in/3` clears the field
    # first, and the change event that sends saves an empty name.
    session
    |> execute_script("document.querySelector(arguments[0]).select()", [@display_name])
    |> send_keys(["12345", :tab])
    |> assert_has(css("#display-name-form", text: "Name cannot be only numbers"))

    assert leaving_held?(session), "a refused display name let the tab close"
    assert Profiles.get_profile(user.id).full_name == "Ada Lovelace"
  end

  feature "an open poll's editor holds a link elsewhere until the host chooses to leave",
          %{session: session} do
    {session, user} = log_in_via_browser(session)
    insert(:calendar_integration, user: user, is_active: true)
    poll = insert_open_poll(user)

    session =
      session
      |> visit("/dashboard/polls")
      |> wait_for_live()
      |> click(css("button[phx-click='select_poll'][phx-value-id='#{poll.id}']"))
      |> click(css("[data-testid='poll-edit-details']"))
      |> assert_has(css(@editor))
      |> fill_in(css("#{@editor} input[name='poll[title]']"), with: "Team offsite")

    # The link is held and the host asked; keeping on editing keeps the text
    # and the page.
    session =
      session
      |> click(css(@locations_link))
      |> assert_has(css(@leave_modal, text: "Leave without saving?"))
      |> click(css("#leave-poll-editor-cancel"))
      |> assert_has(css(@leave_modal, count: 0, visible: :any))
      |> assert_has(css("#{@editor} input[name='poll[title]']"))

    assert current_path(session) == "/dashboard/polls"
    assert has_value?(session, css("#{@editor} input[name='poll[title]']"), "Team offsite")

    # Asked again, leaving follows the link that was held, and saves nothing.
    session
    |> click(css(@locations_link))
    |> assert_has(css(@leave_modal))
    |> click(css("[data-testid='confirm-leave-poll-editor']"))
    |> assert_has(css("[data-testid='locations-page']"))

    assert current_path(session) == "/dashboard/locations"
    assert {:ok, %{title: "Offsite"}} = Polls.get_poll_for_host(poll.id, user.id)
  end

  defp insert_open_poll(user) do
    deadline = DateTime.add(DateTime.utc_now(:second), 3, :day)

    poll =
      insert(:poll,
        user: user,
        status: :open,
        title: "Offsite",
        timezone: "Etc/UTC",
        meeting_type_id: nil,
        deadline_at: deadline
      )

    insert(:poll_time_slot, poll: poll, start_time: DateTime.add(deadline, 4, :day))
    poll
  end

  # Whether closing the tab now would ask first: a listener cancelled the
  # `beforeunload` the browser sends before it leaves.
  defp leaving_held?(session) do
    evaluate_script(session, """
    const event = new Event("beforeunload", {cancelable: true});
    window.dispatchEvent(event);
    return event.defaultPrevented;
    """)
  end
end
