defmodule TymeslotWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :tymeslot

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_tymeslot_key",
    # Use a stable, non-secret salt. secret_key_base is the actual secret.
    signing_salt:
      Application.compile_env(:tymeslot, [TymeslotWeb.Endpoint, :session_signing_salt]),
    # Changed from "Strict" to "Lax" to allow OAuth callbacks
    same_site: "Lax",
    http_only: true,
    secure: Application.compile_env(:tymeslot, :secure_cookies, false)
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [
      connect_info: [
        :peer_data,
        :x_headers,
        :user_agent,
        session: @session_options
      ],
      # 60 seconds keepalive timeout
      timeout: 60_000,
      # Reduce noise from disconnection logs
      transport_log: false
    ],
    longpoll: [
      connect_info: [
        :peer_data,
        :x_headers,
        :user_agent,
        session: @session_options
      ]
    ]

  # Embed socket — no session cookie verification so cross-site iframes
  # work on mobile browsers that block third-party SameSite=Lax cookies.
  # Auth is handled by signed embed tokens in the LiveView session instead.
  socket "/embed-live", Phoenix.LiveView.Socket,
    websocket: [
      connect_info: [
        :peer_data,
        :x_headers,
        :user_agent
      ],
      timeout: 60_000,
      transport_log: false
    ],
    longpoll: [
      connect_info: [
        :peer_data,
        :x_headers,
        :user_agent
      ]
    ]

  # Allow Wallaby browser tests to share the Ecto sandbox connection
  if Application.compile_env(:tymeslot, :environment) == :test do
    plug Phoenix.Ecto.SQL.Sandbox
  end

  if code_reloading? and Code.ensure_loaded?(Tidewave) do
    plug Tidewave
  end

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  plug :serve_robots

  plug Plug.Static,
    at: "/",
    from: :tymeslot,
    gzip: true,
    only: TymeslotWeb.static_paths() ++ ["embed.js"],
    # embed.js is a standalone file at the root (not under /assets/).
    # `only` handles the canonical /embed.js path.
    # `only_matching: ["embed-"]` covers digested /embed-<hash>.js variants
    # without over-matching unrelated paths like /embeddings/... or /embed-anything.
    only_matching: ["embed-"]

  # Static sources contributed by external layers via the
  # :extra_static_sources config key. Empty by default — see the plug.
  plug TymeslotWeb.Plugs.ExtraStatic

  defp serve_robots(%{request_path: "/robots.txt"} = conn, _opts) do
    {app, file} =
      case Application.get_env(:tymeslot, :robots_file, "robots.core.txt") do
        {app, file} when is_atom(app) and is_binary(file) -> {app, file}
        file when is_binary(file) -> {:tymeslot, file}
      end

    conn
    |> put_resp_content_type("text/plain")
    |> send_file(200, Path.join(:code.priv_dir(app), "static/#{file}"))
    |> halt()
  end

  defp serve_robots(conn, _opts), do: conn

  # Serve uploaded files from the data directory.
  # `UploadStaticSecurity` gates the mount to an extension allowlist and
  # sets `X-Content-Type-Options: nosniff` so a stray `evil.html` written
  # under the upload root can never be served as same-origin HTML.
  plug TymeslotWeb.Plugs.UploadStaticSecurity

  plug Plug.Static,
    at: "/uploads",
    from: Application.compile_env(:tymeslot, :upload_directory, "uploads"),
    gzip: false

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Tymeslot.Infrastructure.CorrelationId
  # Derive client IP from proxy headers (options pulled from config :remote_ip)
  plug RemoteIp

  plug Plug.Telemetry,
    event_prefix: [:phoenix, :endpoint],
    log: {__MODULE__, :request_log_level, []}

  # Routes that carry a single-use credential in the path must not appear in
  # request logs — Phoenix.Logger writes the raw request path, so logging them
  # would persist the token. Controller and LiveView logs still fire.
  @doc false
  @spec request_log_level(Plug.Conn.t()) :: Logger.level() | false
  def request_log_level(%Plug.Conn{path_info: ["auth", "verify-complete" | _rest]}), do: false
  def request_log_level(%Plug.Conn{path_info: ["auth", "reset-password", _token]}), do: false
  def request_log_level(%Plug.Conn{path_info: ["email-change", _token]}), do: false
  def request_log_level(%Plug.Conn{path_info: ["guest", _token, _response]}), do: false
  def request_log_level(_conn), do: :info

  # Use custom body reader to cache raw body for webhooks needed for signature verification
  # Length reduced to 5MB for security; webhooks are typically much smaller.
  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    body_reader: {TymeslotWeb.Plugs.WebhookBodyCachePlug, :read_body, []},
    json_decoder: Phoenix.json_library(),
    length: 5_000_000

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options

  defp dynamic_router(conn, _opts) do
    router = Application.get_env(:tymeslot, :router, TymeslotWeb.Router)
    router.call(conn, router.init([]))
  end

  plug :dynamic_router
end
