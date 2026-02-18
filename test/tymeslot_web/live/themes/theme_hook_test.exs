defmodule TymeslotWeb.Live.Themes.ThemeHookTest do
  use TymeslotWeb.ConnCase, async: false
  @moduletag :utils

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  @moduledoc """
  Verifies that theme-specific JS hooks are correctly rendered in the DOM.
  """

  setup tags do
    Mox.set_mox_from_context(tags)
    TestMocks.setup_all_mocks()

    user = insert(:user)
    profile = insert(:profile, user: user, username: "testuser")
    insert(:calendar_integration, user: user, is_active: true)
    insert(:meeting_type, user: user)

    # Enable video background via theme customization
    insert(:theme_customization,
      profile: profile,
      theme_id: "1",
      background_type: "video",
      background_value: "preset:1"
    )

    insert(:theme_customization,
      profile: profile,
      theme_id: "2",
      background_type: "video",
      background_value: "preset:1"
    )

    %{user: user, profile: profile}
  end

  test "quill theme renders QuillVideo hook when video background is active", %{
    conn: conn,
    profile: profile
  } do
    # Theme "1" is Quill
    update_profile(profile, %{booking_theme: "1"})

    {:ok, _view, html} = live(conn, ~p"/#{profile.username}")

    assert html =~ ~s(id="quill-video-container")
    assert html =~ ~s(phx-hook="QuillVideo")
  end

  test "rhythm theme renders RhythmVideo hook when video background is active", %{
    conn: conn,
    profile: profile
  } do
    # Theme "2" is Rhythm
    update_profile(profile, %{booking_theme: "2"})

    {:ok, _view, html} = live(conn, ~p"/#{profile.username}")

    assert html =~ ~s(id="rhythm-video-container")
    assert html =~ ~s(phx-hook="RhythmVideo")
    assert html =~ ~s(id="rhythm-background-video-1")
    assert html =~ ~s(id="rhythm-background-video-2")
  end

  defp update_profile(profile, attrs) do
    profile
    |> Changeset.change(attrs)
    |> Repo.update!()
  end
end
