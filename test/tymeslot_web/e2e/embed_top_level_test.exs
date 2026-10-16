defmodule TymeslotWeb.E2E.EmbedTopLevelTest do
  @moduledoc """
  A booking page's embed URL opened in its own tab must connect like any
  other page.

  Opened top-level (a copied iframe URL, a developer debugging an embed), the
  page is not framed, so `core.js` connects to `/live`, which needs the
  session. It used to be served as an embed, which writes no session cookie,
  so a visitor without one got a stale-session reply and the page reloaded
  itself for ever. The browser session here starts with no cookie, which is
  exactly that visitor.
  """
  use TymeslotWeb.BrowserCase, async: false

  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles

  @moduletag :e2e
  @moduletag :themes

  feature "the embed URL opened in its own tab connects its LiveView", %{session: session} do
    user = create_onboarded_user()
    insert(:calendar_integration, user_id: user.id, user: user)

    {:ok, _meeting_type} =
      MeetingTypes.create_meeting_type(%{
        user_id: user.id,
        name: "Top-level Embed Check",
        duration_minutes: 30,
        is_active: true
      })

    profile = Profiles.get_profile(user.id)

    session
    |> visit("/#{profile.username}?embed=1")
    |> assert_has(css("[data-phx-main].phx-connected"))
    |> refute_has(css("html[data-embedded]"))
  end
end
