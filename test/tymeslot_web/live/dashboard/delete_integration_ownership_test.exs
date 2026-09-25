defmodule TymeslotWeb.Dashboard.DeleteIntegrationOwnershipTest do
  @moduledoc """
  The remove-integration dialog takes its id straight from a client-pushed
  event, so it must confirm the integration exists and belongs to the person
  looking at it before it opens. A forged or stale id gets a "not found"
  flash, not a confirmation dialog for something that is not theirs.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :integrations
  @moduletag :live

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Floki

  setup :setup_dashboard_user

  # The modal overlay the component renders under `"#{@id}-modal"`; it is always
  # in the markup and switches on the inline display style.
  defp dialog_open?(view, modal_id) do
    view
    |> element("##{modal_id}-modal")
    |> render()
    |> Floki.parse_document!()
    |> Floki.attribute("##{modal_id}-modal", "style")
    |> Enum.any?(&(&1 =~ "display: flex"))
  end

  defp push_show(view, modal_id, id) do
    view
    |> with_target("##{modal_id}")
    |> render_click("show", %{"id" => to_string(id)})
  end

  describe "calendar integrations" do
    test "the dialog opens for the user's own integration", %{conn: conn, user: user} do
      mine = insert(:calendar_integration, user: user, provider: "google")

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

      push_show(view, "delete-calendar-modal", mine.id)

      assert dialog_open?(view, "delete-calendar-modal")
    end

    test "the dialog stays closed for another user's integration", %{conn: conn, user: user} do
      stranger = insert(:user)
      theirs = insert(:calendar_integration, user: stranger, provider: "google")
      insert(:calendar_integration, user: user, provider: "google")

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

      push_show(view, "delete-calendar-modal", theirs.id)

      refute dialog_open?(view, "delete-calendar-modal")
      assert render(view) =~ "Integration not found"
    end

    test "the dialog stays closed for an id that does not exist", %{conn: conn, user: user} do
      mine = insert(:calendar_integration, user: user, provider: "google")

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

      push_show(view, "delete-calendar-modal", mine.id + 10_000)

      refute dialog_open?(view, "delete-calendar-modal")
      assert render(view) =~ "Integration not found"
    end
  end

  describe "video integrations" do
    test "the dialog opens for the user's own integration", %{conn: conn, user: user} do
      mine = insert(:video_integration, user: user, provider: "zoom", is_active: true)

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

      push_show(view, "delete-video-modal", mine.id)

      assert dialog_open?(view, "delete-video-modal")
    end

    test "the dialog stays closed for another user's integration", %{conn: conn, user: user} do
      # The two contexts take `(id, user_id)` in opposite orders, so the ids
      # here are deliberately unrelated to either user id: a swapped lookup
      # would match nothing rather than accidentally passing.
      stranger = insert(:user)
      theirs = insert(:video_integration, user: stranger, provider: "zoom", is_active: true)
      insert(:video_integration, user: user, provider: "zoom", is_active: true)

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

      push_show(view, "delete-video-modal", theirs.id)

      refute dialog_open?(view, "delete-video-modal")
      assert render(view) =~ "Integration not found"
    end

    test "the dialog stays closed for an id that does not exist", %{conn: conn, user: user} do
      mine = insert(:video_integration, user: user, provider: "zoom", is_active: true)

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

      push_show(view, "delete-video-modal", mine.id + 10_000)

      refute dialog_open?(view, "delete-video-modal")
      assert render(view) =~ "Integration not found"
    end

    test "the dialog opens for an owned integration whose credentials no longer decrypt", %{
      conn: conn,
      user: user
    } do
      # Undecryptable bytes stand in for a credential whose key is gone. The
      # integration is still the user's, and deleting it is how they recover,
      # so the ownership gate must not treat it as missing.
      stale =
        insert(:video_integration,
          user: user,
          provider: "mirotalk",
          is_active: true,
          api_key_encrypted: :crypto.strong_rand_bytes(40)
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

      push_show(view, "delete-video-modal", stale.id)

      assert dialog_open?(view, "delete-video-modal")
    end
  end
end
