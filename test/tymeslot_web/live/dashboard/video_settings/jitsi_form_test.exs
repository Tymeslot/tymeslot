defmodule TymeslotWeb.Dashboard.VideoSettings.JitsiFormTest do
  use TymeslotWeb.LiveCase, async: true

  @moduletag :video
  @moduletag :integrations
  @moduletag :live

  import Mox
  import Tymeslot.Factory
  import Tymeslot.AuthTestHelpers
  import Tymeslot.TestHelpers.Eventually

  alias Ecto.Changeset
  alias Plug.Test
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Repo

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user)
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  describe "the Jitsi connect form" do
    test "connects Jitsi with a server URL and no credentials", %{conn: conn, user: user} do
      stub_jitsi_server(200)

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

      view
      |> element("button[phx-click='setup_provider'][phx-value-provider='jitsi']")
      |> render_click()

      html = render(view)
      assert html =~ "Jitsi Meet"

      assert has_element?(
               view,
               "#jitsi-video-integration-form input[name='integration[base_url]']"
             )

      assert html =~ "requires whoever hosts the meeting to sign in"

      view
      |> form("#jitsi-video-integration-form",
        integration: %{name: "Our Jitsi", base_url: "https://meet.example.com"}
      )
      |> render_submit()

      assert [%{provider: "jitsi", base_url: "https://meet.example.com"} = integration] =
               Video.list_integrations(user.id)

      assert is_nil(integration.client_id_encrypted)
      assert is_nil(integration.client_secret_encrypted)

      eventually(fn -> assert render(view) =~ "Video integration added successfully" end)
      assert render(view) =~ "https://meet.example.com · Jitsi"
    end

    test "stores only the Jitsi form's own fields when the browser sends more", %{
      conn: conn,
      user: user
    } do
      stub_jitsi_server(200)

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

      view
      |> element("button[phx-click='setup_provider'][phx-value-provider='jitsi']")
      |> render_click()

      view
      |> element("#jitsi-video-integration-form")
      |> render_submit(%{
        integration: %{
          name: "Our Jitsi",
          base_url: "https://meet.example.com",
          custom_meeting_url: "https://elsewhere.example.com"
        }
      })

      assert [%{provider: "jitsi", custom_meeting_url: nil}] = Video.list_integrations(user.id)
    end

    test "saves a Jitsi server URL carrying a null byte without it", %{conn: conn, user: user} do
      stub_jitsi_server(200)

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

      view
      |> element("button[phx-click='setup_provider'][phx-value-provider='jitsi']")
      |> render_click()

      view
      |> form("#jitsi-video-integration-form",
        integration: %{name: "Our Jitsi", base_url: "https://meet.example.com\0"}
      )
      |> render_submit()

      assert [%{base_url: "https://meet.example.com"}] = Video.list_integrations(user.id)
    end

    # Each save probes under its own task name. The first server's probe is
    # held until the second save has started its own, so a shared name would
    # drop the first result and its warning.
    test "two quick Jitsi saves each get their own connection feedback", %{
      conn: conn,
      user: user
    } do
      test_pid = self()

      stub(Tymeslot.HTTPClientMock, :head, fn
        "https://slow.example.com", _headers, _opts ->
          send(test_pid, {:probing, self()})

          receive do
            :answer -> {:ok, %Req.Response{status: 503}}
          end

        "https://fast.example.com", _headers, _opts ->
          {:ok, %Req.Response{status: 200}}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

      for {name, base_url} <- [
            {"Slow", "https://slow.example.com"},
            {"Fast", "https://fast.example.com"}
          ] do
        view
        |> element("button[phx-click='setup_provider'][phx-value-provider='jitsi']")
        |> render_click()

        view
        |> form("#jitsi-video-integration-form", integration: %{name: name, base_url: base_url})
        |> render_submit()

        assert render(view) =~ "Video integration added successfully"
      end

      assert_receive {:probing, slow_probe}
      send(slow_probe, :answer)

      eventually(fn ->
        assert render(view) =~ "Saved, but the server did not answer as expected"
      end)

      assert length(Video.list_integrations(user.id)) == 2
    end

    test "the Jitsi server URL field starts empty rather than defaulting to the public instance",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

      view
      |> element("button[phx-click='setup_provider'][phx-value-provider='jitsi']")
      |> render_click()

      assert has_element?(view, "#jitsi_base_url[placeholder='https://meet.example.com']")
      assert has_element?(view, "#jitsi_base_url[aria-describedby='jitsi_base_url-help']")
      refute has_element?(view, "#jitsi_base_url[value]:not([value=''])")
    end

    test "connects Jitsi with token authentication and never renders the secret back", %{
      conn: conn,
      user: user
    } do
      stub_jitsi_server(200)
      secret = String.duplicate("k", 40)

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

      view
      |> element("button[phx-click='setup_provider'][phx-value-provider='jitsi']")
      |> render_click()

      assert has_element?(
               view,
               "#jitsi_client_secret[type='password'][autocomplete='off']:not([value])"
             )

      params = %{
        name: "Our Jitsi",
        base_url: "https://meet.example.com",
        client_id: "tymeslot",
        client_secret: secret
      }

      # The typed values reach the socket through phx-change; the re-render
      # must still leave the secret out of the page.
      refute view |> form("#jitsi-video-integration-form", integration: params) |> render_change() =~
               secret

      view |> form("#jitsi-video-integration-form", integration: params) |> render_submit()

      assert [%{} = integration] = Video.list_integrations(user.id)
      assert integration.client_id == "tymeslot"
      assert integration.client_secret == secret
    end

    test "shows the Jitsi provider's message for a short secret and saves nothing", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

      view
      |> element("button[phx-click='setup_provider'][phx-value-provider='jitsi']")
      |> render_click()

      html =
        view
        |> form("#jitsi-video-integration-form",
          integration: %{
            name: "Our Jitsi",
            base_url: "https://meet.example.com",
            client_id: "tymeslot",
            client_secret: String.duplicate("k", 31)
          }
        )
        |> render_submit()

      assert html =~ "The App secret must be at least 32 bytes long"

      assert has_element?(
               view,
               "#jitsi-video-integration-form [role='alert']",
               "The App secret must be at least 32 bytes long"
             )

      refute has_element?(view, "#jitsi-video-integration-form p.form-error")
      assert Video.list_integrations(user.id) == []
    end

    test "refuses a Jitsi server that is already connected with a clear message", %{
      conn: conn,
      user: user
    } do
      {:ok, _first} =
        Video.create_integration(user.id, :jitsi, %{
          name: "Our Jitsi",
          base_url: "https://meet.example.com"
        })

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

      view
      |> element("button[phx-click='setup_provider'][phx-value-provider='jitsi']")
      |> render_click()

      html =
        view
        |> form("#jitsi-video-integration-form",
          integration: %{name: "Again", base_url: "https://meet.example.com"}
        )
        |> render_submit()

      assert html =~ "This server is already connected"
      assert [%{name: "Our Jitsi"}] = Video.list_integrations(user.id)
    end

    test "keeps a Jitsi integration whose server does not answer, with a warning", %{
      conn: conn,
      user: user
    } do
      stub_jitsi_server(503)

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

      view
      |> element("button[phx-click='setup_provider'][phx-value-provider='jitsi']")
      |> render_click()

      view
      |> form("#jitsi-video-integration-form",
        integration: %{name: "Our Jitsi", base_url: "https://meet.example.com"}
      )
      |> render_submit()

      assert [%{provider: "jitsi"}] = Video.list_integrations(user.id)

      assert render(view) =~ "Video integration added successfully"

      eventually(fn ->
        assert render(view) =~ "Saved, but the server did not answer as expected"
      end)
    end

    test "edits a Jitsi integration and keeps the stored secret when it is left blank", %{
      conn: conn,
      user: user
    } do
      secret = String.duplicate("s", 32)
      integration = create_jitsi_with_credentials(user, secret)

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")
      open_edit_dialog(view, integration)

      assert has_element?(view, "#edit_jitsi_base_url[value='https://meet.example.com']")
      assert has_element?(view, "#edit_jitsi_client_id[value='tymeslot']")
      assert has_element?(view, "#edit_jitsi_client_secret[type='password']:not([value])")
      assert render(view) =~ "Leave blank to keep the current secret."
      refute render(view) =~ secret

      view
      |> form("#edit-video-integration-form",
        integration: %{
          name: "Team Jitsi",
          base_url: "https://jitsi.example.com",
          client_id: "tymeslot",
          client_secret: ""
        }
      )
      |> render_submit()

      assert render(view) =~ "Integration updated successfully"

      assert {:ok, stored} = Video.get_integration(user.id, integration.id)
      assert stored.name == "Team Jitsi"
      assert stored.base_url == "https://jitsi.example.com"
      assert stored.client_secret == secret
    end

    test "shows the Jitsi provider's message when an edit sets a short secret", %{
      conn: conn,
      user: user
    } do
      secret = String.duplicate("s", 32)
      integration = create_jitsi_with_credentials(user, secret)

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")
      open_edit_dialog(view, integration)

      view
      |> form("#edit-video-integration-form",
        integration: %{client_secret: String.duplicate("n", 31)}
      )
      |> render_submit()

      assert render(view) =~ "The App secret must be at least 32 bytes long"
      refute render(view) =~ "Failed to update integration"
      assert {:ok, %{client_secret: ^secret}} = Video.get_integration(user.id, integration.id)
    end

    test "removes token authentication from a Jitsi integration through the edit dialog", %{
      conn: conn,
      user: user
    } do
      integration = create_jitsi_with_credentials(user, String.duplicate("s", 32))

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")
      open_edit_dialog(view, integration)

      view
      |> form("#edit-video-integration-form",
        integration: %{remove_token_authentication: "true"}
      )
      |> render_change()

      assert has_element?(view, "#edit_jitsi_client_id[disabled]")
      assert has_element?(view, "#edit_jitsi_client_secret[disabled]")

      # `is_active` is not a field of the dialog, so it must not reach the save.
      view
      |> element("#edit-video-integration-form")
      |> render_submit(%{integration: %{remove_token_authentication: "true", is_active: "false"}})

      assert render(view) =~ "Integration updated successfully"

      row = Repo.get!(VideoIntegrationSchema, integration.id)
      assert row.is_active
      assert is_nil(row.client_id_encrypted)
      assert is_nil(row.client_secret_encrypted)
    end

    test "restores the stored App ID and the keep-secret note when removal is unticked", %{
      conn: conn,
      user: user
    } do
      integration = create_jitsi_with_credentials(user, String.duplicate("s", 32))

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")
      open_edit_dialog(view, integration)

      view
      |> element("#edit-video-integration-form")
      |> render_change(%{integration: %{remove_token_authentication: "true"}})

      refute has_element?(view, "#edit_jitsi_client_secret_keep")

      # A disabled input is not submitted, so the App ID is absent from this change.
      view
      |> element("#edit-video-integration-form")
      |> render_change(%{
        integration: %{name: "Our Jitsi", remove_token_authentication: "false"}
      })

      assert has_element?(view, "#edit_jitsi_client_id[value='tymeslot']:not([disabled])")
      assert has_element?(view, "#edit_jitsi_client_secret_keep")
    end

    test "renaming a Jitsi integration that needs attention leaves the flag set", %{
      conn: conn,
      user: user
    } do
      {:ok, integration} =
        Video.create_integration(user.id, :jitsi, %{
          name: "Open Jitsi",
          base_url: "https://meet.example.com"
        })

      integration |> Changeset.change(needs_reauth: true) |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")
      open_edit_dialog(view, integration)

      view
      |> form("#edit-video-integration-form", integration: %{name: "Renamed Jitsi"})
      |> render_submit()

      assert render(view) =~ "Integration updated successfully"

      row = Repo.get!(VideoIntegrationSchema, integration.id)
      assert row.name == "Renamed Jitsi"
      assert row.needs_reauth
    end

    test "shows the first changeset error when an edit is refused by the schema", %{
      conn: conn,
      user: user
    } do
      {:ok, integration} =
        Video.create_integration(user.id, :jitsi, %{
          name: "Open Jitsi",
          base_url: "https://meet.example.com"
        })

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")
      open_edit_dialog(view, integration)

      view
      |> form("#edit-video-integration-form", integration: %{base_url: "https://10.0.0.1"})
      |> render_submit()

      refute render(view) =~ "Failed to update integration"
      assert render(view) =~ "Base url"

      assert Repo.get!(VideoIntegrationSchema, integration.id).base_url ==
               "https://meet.example.com"
    end

    test "offers no credential removal for a Jitsi integration without credentials", %{
      conn: conn,
      user: user
    } do
      {:ok, integration} =
        Video.create_integration(user.id, :jitsi, %{
          name: "Open Jitsi",
          base_url: "https://meet.example.com"
        })

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")
      open_edit_dialog(view, integration)

      assert has_element?(view, "#edit_jitsi_client_secret")
      refute has_element?(view, "#edit_jitsi_remove_token_authentication")
      refute render(view) =~ "Leave blank to keep the current secret."
    end
  end

  defp stub_jitsi_server(status) do
    stub(Tymeslot.HTTPClientMock, :head, fn "https://meet.example.com", _headers, _opts ->
      {:ok, %Req.Response{status: status}}
    end)
  end

  defp create_jitsi_with_credentials(user, secret) do
    {:ok, integration} =
      Video.create_integration(user.id, :jitsi, %{
        name: "Our Jitsi",
        base_url: "https://meet.example.com",
        client_id: "tymeslot",
        client_secret: secret
      })

    integration
  end

  defp open_edit_dialog(view, integration) do
    view
    |> element(
      "button[phx-click='show'][phx-value-id='#{integration.id}'][phx-target='#edit-video-modal']"
    )
    |> render_click()
  end
end
