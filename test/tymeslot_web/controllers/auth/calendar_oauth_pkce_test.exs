defmodule TymeslotWeb.CalendarOAuthPkceTest do
  @moduledoc """
  Connecting Outlook Calendar end to end with the real OAuth helper: the
  authorisation URL carries a PKCE challenge and a single-use state, the
  callback redeems the code with the matching verifier, and the same callback
  replayed connects nothing.
  """

  # async: false: OAuth client configuration is application-wide.
  use TymeslotWeb.ConnCase, async: false

  @moduletag :integrations
  @moduletag :calendar

  import Mox
  import Tymeslot.AuthTestHelpers, only: [log_in_user: 2]
  import Tymeslot.Factory

  alias Phoenix.Flash
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Outlook.OAuthHelper
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Test.LogCapture

  setup :verify_on_exit!

  setup do
    RateLimiter.clear_all()
    put_env(:outlook_calendar_oauth_helper, OAuthHelper)

    put_env(:outlook_oauth,
      client_id: "outlook-client",
      client_secret: "outlook-secret",
      state_secret: "outlook-state-secret"
    )

    user = insert(:user)
    insert(:profile, user: user)
    %{user: user}
  end

  test "redeems the code with the flow's verifier, and only once", %{conn: conn, user: user} do
    {:ok, url} = Calendar.initiate_oauth(:outlook, user.id)
    query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert query["code_challenge_method"] == "S256"
    challenge = query["code_challenge"]

    expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, body, _headers, _opts ->
      verifier = URI.decode_query(body)["code_verifier"]
      assert Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false) == challenge

      {:ok,
       %Req.Response{
         status: 200,
         body: ~s({"access_token":"at","refresh_token":"rt","expires_in":3600})
       }}
    end)

    expect(OutlookCalendarAPIMock, :list_calendars, fn _integration ->
      {:ok, [%{"id" => "cal1", "name" => "Calendar", "isDefaultCalendar" => true}]}
    end)

    conn = log_in_user(conn, user)
    params = %{"code" => "code", "state" => query["state"]}

    first = get(conn, ~p"/auth/outlook/calendar/callback", params)
    assert Flash.get(first.assigns.flash, :info) =~ "Outlook Calendar connected successfully"

    # The same callback again: the state's flow is spent, so no second token
    # request is made (the single expectation above) and nothing is connected.
    LogCapture.attach()
    replay = get(conn, ~p"/auth/outlook/calendar/callback", params)
    assert Flash.get(replay.assigns.flash, :error) =~ "Failed to connect Outlook Calendar"

    # Expected now and then (a reloaded callback, a connect started before a
    # deploy), so it is a warning, not an error that pages someone.
    assert %{level: :warning} = LogCapture.await_log("OAuth callback for a spent or expired flow")

    assert [_one] = Repo.all(CalendarIntegrationSchema)
  end

  defp put_env(key, value) do
    prior = Application.fetch_env(:tymeslot, key)
    Application.put_env(:tymeslot, key, value)

    on_exit(fn ->
      case prior do
        {:ok, prior_value} -> Application.put_env(:tymeslot, key, prior_value)
        :error -> Application.delete_env(:tymeslot, key)
      end
    end)
  end
end
