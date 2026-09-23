defmodule Tymeslot.Test.OAuthProviderStub do
  @moduledoc """
  Scripts a social sign-in provider's HTTP endpoints through `Req.Test`.

  `stub_provider/1` takes the JSON body each request path should answer with.
  Every request is also reported to the calling test as
  `{:provider_request, method, path, params}`, with the form body or query
  string decoded into `params`, so a test can assert what was sent (the PKCE
  verifier on the token exchange, for instance) rather than only what came
  back.

  `sign_in/3` drives the whole browser side of a login: it starts the flow at
  `/auth/:provider`, reads the state from the authorise redirect, and returns
  the conn from the provider's callback.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]
  import Phoenix.ConnTest
  import Plug.Conn

  alias Req.Test, as: ReqTest

  @endpoint TymeslotWeb.Endpoint

  @github %{
    "/login/oauth/access_token" => %{"access_token" => "github-token", "token_type" => "bearer"}
  }

  @google %{
    "/token" => %{"access_token" => "google-token", "token_type" => "Bearer"}
  }

  @sso_config [
    client_id: "sso-client",
    client_secret: "sso-secret",
    site: "https://sso.example.com",
    authorize_url: "https://sso.example.com/authorize",
    token_url: "https://sso.example.com/token",
    userinfo_url: "https://sso.example.com/userinfo",
    scope: "openid email profile"
  ]

  @credential_vars ~w(GITHUB_CLIENT_ID GITHUB_CLIENT_SECRET GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET)

  @doc """
  ExUnit `setup` callback: switches GitHub, Google and SSO sign-in on, gives
  each client credentials (SSO pointing at `sso.example.com`), and restores
  the previous configuration afterwards. Global state, so `async: false`.
  """
  @spec setup_providers(map()) :: :ok
  def setup_providers(_context) do
    social_auth = Application.get_env(:tymeslot, :social_auth, [])
    oauth_provider = Application.get_env(:tymeslot, :oauth_provider, [])

    Application.put_env(
      :tymeslot,
      :social_auth,
      Keyword.merge(social_auth, github_enabled: true, google_enabled: true, oauth_enabled: true)
    )

    Application.put_env(:tymeslot, :oauth_provider, @sso_config)

    originals = Map.new(@credential_vars, &{&1, System.get_env(&1)})
    Enum.each(@credential_vars, &System.put_env(&1, "test-" <> String.downcase(&1)))

    on_exit(fn ->
      Application.put_env(:tymeslot, :social_auth, social_auth)
      Application.put_env(:tymeslot, :oauth_provider, oauth_provider)

      Enum.each(originals, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  @doc """
  Answers the SSO provider's token and userinfo endpoints.
  """
  @spec stub_sso(map()) :: :ok
  def stub_sso(userinfo) do
    stub_provider(%{
      "/token" => %{"access_token" => "sso-token", "token_type" => "Bearer"},
      "/userinfo" => userinfo
    })
  end

  @doc """
  Answers GitHub's token, `/user` and `/user/emails` endpoints.
  """
  @spec stub_github(map(), list(map())) :: :ok
  def stub_github(user, emails \\ []) do
    @github
    |> Map.merge(%{"/user" => user, "/user/emails" => emails})
    |> stub_provider()
  end

  @doc """
  Answers Google's token and v1 userinfo endpoints.
  """
  @spec stub_google(map()) :: :ok
  def stub_google(userinfo) do
    @google
    |> Map.put("/oauth2/v1/userinfo", userinfo)
    |> stub_provider()
  end

  @doc """
  Answers each request path with its JSON body, or hands the conn to a
  one-argument function for anything else (an error status, a transport
  failure); any other path gets a 404.
  """
  @spec stub_provider(%{String.t() => term() | (Plug.Conn.t() -> Plug.Conn.t())}) :: :ok
  def stub_provider(responses) do
    test_pid = self()

    ReqTest.stub(:tymeslot_http, fn conn ->
      {:ok, body, conn} = read_body(conn)
      params = Map.merge(URI.decode_query(conn.query_string), URI.decode_query(body))
      send(test_pid, {:provider_request, conn.method, conn.request_path, params})

      case Map.fetch(responses, conn.request_path) do
        {:ok, respond} when is_function(respond, 1) -> respond.(conn)
        {:ok, response} -> ReqTest.json(conn, response)
        :error -> send_resp(conn, 404, "not found")
      end
    end)
  end

  @doc """
  Starts a sign-in at `/auth/:provider` and follows it back through the
  callback, returning the callback's conn. The state and PKCE values are the
  ones the server itself issued.
  """
  @spec sign_in(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def sign_in(conn, provider, code \\ "provider-code") do
    start = get(conn, "/auth/#{provider}")
    %{"state" => state} = start |> redirected_to(302) |> authorise_params()

    start
    |> recycle()
    |> get("/auth/#{provider}/callback", %{"code" => code, "state" => state})
  end

  @doc """
  Decodes the query string of a provider authorise URL.
  """
  @spec authorise_params(String.t()) :: map()
  def authorise_params(url), do: url |> URI.parse() |> Map.get(:query) |> URI.decode_query()
end
