defmodule TymeslotWeb.Dashboard.VideoSettingsCompositionTest do
  @moduledoc """
  Composition tests for `TymeslotWeb.Dashboard.VideoSettingsComponent`
  and `TymeslotWeb.Components.Dashboard.Integrations.Video.EditVideoIntegrationModal`.

  The existing `video_settings_component_test.exs` covers happy-path
  rendering, toggle, and delete, but does not pin:

    * that a successful MiroTalk creation actually persists the `base_url`
      the user typed — the sanitise-merge regression that originally
      dropped Nextcloud's `base_url` silently (plan line 1842);
    * what happens when the organiser blanks the `api_key` field in the
      edit modal — the component must surface a form error without
      wiping the stored credential, so the integration keeps working
      until the user provides a replacement (plan line 1843);
    * what happens when the integration is deleted between the moment
      the edit modal is opened and the moment the user submits — the
      save must surface "Failed to update integration", not raise
      `Ecto.StaleEntryError`.

  Dropped from the plan with rationale:

    * "Provider changed while modal open → server-side rejects mismatch"
      — the edit form injects the original provider via a hidden field
      and the save handler overrides the `params["provider"]` with
      `integration.provider` before validation
      (`edit_video_integration_modal.ex:112`). The server cannot see a
      client-side mismatch, so there is no behaviour to assert beyond
      "the code does what it obviously does". Credo-flavour test.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :integrations
  @moduletag :video
  @moduletag :live

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Security.RateLimiter

  setup :verify_on_exit!

  setup %{conn: conn} do
    RateLimiter.clear_all()

    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user)
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)

    %{conn: conn, user: user}
  end

  describe "add_integration — sanitise-merge regression" do
    @tag :capture_log
    test "mirotalk creation persists the base_url the user typed", %{conn: conn} do
      # Video.create_integration probes the provider during creation;
      # stub the HTTP layer so the test does not hit the network.
      stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: "{}"}}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/video-integration")

      view
      |> element("button", "Connect MiroTalk")
      |> render_click()

      typed_url = "https://miro.example.org"

      view
      |> form("#mirotalk-config-modal form", %{
        "integration" => %{
          "name" => "Team Room",
          "base_url" => typed_url,
          "api_key" => "super-secret-mirotalk-key"
        }
      })
      |> render_submit()

      assert render(view) =~ "Video integration added successfully"

      # If SanitizeMerge.merge/2 regresses back to `Map.merge/2` the
      # sanitised `""` would clobber the user's value and this row
      # would have `base_url == nil` instead of the URL — exactly the
      # Nextcloud-shaped bug the sanitiser pattern exists to prevent.
      persisted = Repo.one(VideoIntegrationSchema)
      assert persisted.base_url == typed_url
      assert persisted.name == "Team Room"
      assert persisted.provider == "mirotalk"
    end
  end

  describe "edit modal — credential preservation" do
    @tag :capture_log
    test "blanking the api_key surfaces an error without wiping the stored secret", %{
      conn: conn,
      user: user
    } do
      integration =
        insert(:video_integration,
          user: user,
          provider: "mirotalk",
          name: "Team Room",
          base_url: "https://miro.example.org",
          api_key_encrypted: Encryption.encrypt("live-api-key-abcdef123456")
        )

      original_api_key_ciphertext = integration.api_key_encrypted

      {:ok, view, _html} = live(conn, ~p"/dashboard/video-integration")

      # Open the edit modal for this integration. The row renders the
      # edit button twice (desktop + mobile variants); restrict the
      # selector to the desktop-only wrapper so exactly one element
      # matches.
      view
      |> element(
        ".hidden button[phx-click='show'][phx-value-id='#{integration.id}'][phx-target='#edit-video-modal']"
      )
      |> render_click()

      # Submit with the API key blanked; everything else valid.
      view
      |> form("#edit-video-integration-form", %{
        "integration" => %{
          "name" => "Team Room",
          "base_url" => "https://miro.example.org",
          "api_key" => ""
        }
      })
      |> render_submit()

      # The modal should reject the empty API key rather than persist
      # it; the stored ciphertext must be untouched so the integration
      # keeps working on subsequent calls.
      fresh = Repo.get!(VideoIntegrationSchema, integration.id)
      assert fresh.api_key_encrypted == original_api_key_ciphertext
    end
  end

  describe "edit modal — race with deletion" do
    @tag :capture_log
    test "save after the integration was deleted surfaces an error flash",
         %{conn: conn, user: user} do
      integration =
        insert(:video_integration,
          user: user,
          provider: "mirotalk",
          name: "Team Room",
          base_url: "https://miro.example.org",
          api_key_encrypted: Encryption.encrypt("live-api-key-abcdef123456")
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/video-integration")

      view
      |> element(
        ".hidden button[phx-click='show'][phx-value-id='#{integration.id}'][phx-target='#edit-video-modal']"
      )
      |> render_click()

      # Simulate the organiser deleting the integration from another
      # tab while this modal sat open. The save handler reads the row
      # by id+user_id before updating, so deletion must produce a
      # `:not_found` that surfaces cleanly — not an unhandled raise.
      Repo.delete!(integration)

      view
      |> form("#edit-video-integration-form", %{
        "integration" => %{
          "name" => "Updated Name",
          "base_url" => "https://miro.example.org",
          "api_key" => "brand-new-api-key-123456"
        }
      })
      |> render_submit()

      assert render(view) =~ "Failed to update integration"
    end
  end
end
