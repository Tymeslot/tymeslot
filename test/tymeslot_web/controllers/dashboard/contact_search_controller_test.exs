defmodule TymeslotWeb.Dashboard.ContactSearchControllerTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :integrations

  import Tymeslot.AuthTestHelpers
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Contacts.Sync
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Test.CardDAVStub

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    :ok
  end

  test "answers the signed-in host with their matching contacts", %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "nextcloud",
        base_url: "https://dav.example.com/remote.php/dav",
        username_encrypted: Encryption.encrypt("ada"),
        password_encrypted: Encryption.encrypt("secret"),
        use_for_contacts: true
      )

    CardDAVStub.stub("ada:secret", %{
      "/addressbooks/user/contacts/" => [{"Grace Hopper", ["grace@example.com"]}]
    })

    {:ok, integration} = CalendarIntegrationQueries.get(integration.id)
    {:ok, _outcome} = Sync.run(integration)

    conn =
      conn
      |> init_test_session(%{})
      |> log_in_user(user)
      |> get(~p"/dashboard/contacts/search?q=grace")

    assert json_response(conn, 200) == %{
             "contacts" => [%{"name" => "Grace Hopper", "email" => "grace@example.com"}]
           }

    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "answers a host without address books with nothing", %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())

    conn =
      conn
      |> init_test_session(%{})
      |> log_in_user(user)
      |> get(~p"/dashboard/contacts/search?q=grace")

    assert json_response(conn, 200) == %{"contacts" => []}
  end

  test "is not open to visitors who are not signed in", %{conn: conn} do
    conn = get(conn, ~p"/dashboard/contacts/search?q=grace")

    assert redirected_to(conn) =~ "/auth/login"
  end
end
