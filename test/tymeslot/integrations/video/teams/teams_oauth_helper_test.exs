defmodule Tymeslot.Integrations.Video.Teams.TeamsOAuthHelperTest do
  @moduletag :integrations
  use Tymeslot.DataCase, async: false

  alias Tymeslot.Integrations.Common.OAuth.State
  alias Tymeslot.Integrations.Video.Teams.TeamsOAuthHelper
  import Mox

  setup :verify_on_exit!
  @moduletag :integrations

  setup do
    # Teams helper reuses Outlook config in the code
    Application.put_env(:tymeslot, :outlook_oauth,
      client_id: "teams-id",
      client_secret: "teams-secret",
      state_secret: "teams-state"
    )

    :ok
  end

  describe "authorization_url/2" do
    test "generates valid Teams OAuth URL" do
      url = TeamsOAuthHelper.authorization_url(1, "http://uri")
      assert url =~ "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
      assert url =~ "client_id=teams-id"
      assert url =~ "scope=https%3A%2F%2Fgraph.microsoft.com%2FCalendars.ReadWrite"
    end
  end

  describe "exchange_code_for_tokens/3" do
    test "exchanges code and validates state" do
      %{user_id: user_id, state: state, resp_body: resp_body} = oauth_test_data()

      profile_body =
        Jason.encode!(%{
          "id" => "microsoft-user-123",
          "displayName" => "Microsoft User"
        })

      # Mock token exchange
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _headers, _body, _opts ->
        {:ok, %{status: 200, body: resp_body}}
      end)

      # Mock profile fetch
      expect(Tymeslot.HTTPClientMock, :get, fn url, _headers, _opts ->
        assert url == "https://graph.microsoft.com/v1.0/me"
        {:ok, %Req.Response{status: 200, body: profile_body}}
      end)

      assert {:ok, tokens} =
               TeamsOAuthHelper.exchange_code_for_tokens("code", "http://uri", state)

      assert tokens.access_token == "at-123"
      assert tokens.user_id == user_id
      assert tokens.teams_user_id == "microsoft-user-123"
      assert tokens.tenant_id == "common"
    end

    test "extracts tenant_id from id_token claims" do
      %{state: state} = oauth_test_data()

      # Mock id_token with tid claim
      header = Base.url_encode64(Jason.encode!(%{alg: "RS256"}), padding: false)
      payload = Base.url_encode64(Jason.encode!(%{tid: "real-tenant-id"}), padding: false)
      id_token = "#{header}.#{payload}.sig"

      resp_body =
        Jason.encode!(%{
          "access_token" => "at-123",
          "id_token" => id_token,
          "expires_in" => 3600,
          "scope" => "Calendars.ReadWrite"
        })

      profile_body =
        Jason.encode!(%{
          "id" => "microsoft-user-123"
        })

      # Mock token exchange
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _headers, _body, _opts ->
        {:ok, %{status: 200, body: resp_body}}
      end)

      # Mock profile fetch
      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: profile_body}}
      end)

      assert {:ok, tokens} =
               TeamsOAuthHelper.exchange_code_for_tokens("code", "http://uri", state)

      assert tokens.tenant_id == "real-tenant-id"
    end

    test "fails if profile is missing id" do
      %{state: state, resp_body: resp_body} = oauth_test_data()

      profile_body = Jason.encode!(%{"displayName" => "Microsoft User"})

      # Mock token exchange
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _headers, _body, _opts ->
        {:ok, %{status: 200, body: resp_body}}
      end)

      # Mock profile fetch
      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: profile_body}}
      end)

      assert {:error, "Microsoft profile missing unique ID"} =
               TeamsOAuthHelper.exchange_code_for_tokens("code", "http://uri", state)
    end

    test "retries profile fetch on transient error" do
      %{state: state, resp_body: resp_body} = oauth_test_data()

      profile_body =
        Jason.encode!(%{
          "id" => "microsoft-user-123"
        })

      # Mock token exchange
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _headers, _body, _opts ->
        {:ok, %{status: 200, body: resp_body}}
      end)

      # Mock profile fetch: failure then success
      Tymeslot.HTTPClientMock
      |> expect(:get, fn _url, _headers, _opts ->
        {:error, %Mint.TransportError{reason: :timeout}}
      end)
      |> expect(:get, fn _url, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: profile_body}}
      end)

      assert {:ok, tokens} =
               TeamsOAuthHelper.exchange_code_for_tokens("code", "http://uri", state)

      assert tokens.teams_user_id == "microsoft-user-123"
    end
  end

  describe "refresh_access_token/2" do
    test "refreshes token successfully" do
      resp_body =
        Jason.encode!(%{
          "access_token" => "new-at",
          "expires_in" => 3600
        })

      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _headers, _body, _opts ->
        {:ok, %{status: 200, body: resp_body}}
      end)

      assert {:ok, tokens} = TeamsOAuthHelper.refresh_access_token("old-rt")
      assert tokens.access_token == "new-at"
    end
  end

  describe "validate_token/1" do
    test "returns :valid when token is not expired" do
      future = DateTime.add(DateTime.utc_now(), 1, :hour)
      assert {:ok, :valid} = TeamsOAuthHelper.validate_token(%{token_expires_at: future})
    end

    test "returns :needs_refresh when token is close to expiry" do
      soon = DateTime.add(DateTime.utc_now(), 2, :minute)
      assert {:ok, :needs_refresh} = TeamsOAuthHelper.validate_token(%{token_expires_at: soon})
    end

    test "returns error when expiration info is missing" do
      assert {:error, _reason} = TeamsOAuthHelper.validate_token(%{})
    end
  end

  defp oauth_test_data do
    user_id = 123
    state = State.generate(user_id, "teams-state")

    resp_body =
      Jason.encode!(%{
        "access_token" => "at-123",
        "refresh_token" => "rt-123",
        "expires_in" => 3600,
        "scope" => "Calendars.ReadWrite"
      })

    %{user_id: user_id, state: state, resp_body: resp_body}
  end
end
