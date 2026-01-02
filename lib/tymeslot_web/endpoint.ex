defmodule TymeslotWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :tymeslot

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_tymeslot_key",
    # Use a stable, non-secret salt. secret_key_base is the actual secret.
    signing_salt: "l7NJun+3qhaGqCXhUilh970bEOPhlhaxO/3dDjzzqzMMNLsu07lxymgjDQNGkev+",
    # Changed from "Strict" to "Lax" to allow OAuth callbacks
    same_site: "Lax",
    secure: Application.compile_env(:tymeslot, :secure_cookies, false)
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [
      connect_info: [:peer_data, :x_headers, session: @session_options],
      # 60 seconds keepalive timeout
      timeout: 60_000,
      # Reduce noise from disconnection logs
      transport_log: false
    ],
    longpoll: [
      connect_info: [:peer_data, :x_headers, session: @session_options]
    ]

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  plug Plug.Static,
    at: "/",
    from: :tymeslot,
    gzip: true,
    only: TymeslotWeb.static_paths()

  # Serve uploaded files from the data directory
  if Mix.env() == :prod do
    plug Plug.Static,
      at: "/uploads",
      from: "/app/data/uploads",
      gzip: false
  else
    plug Plug.Static,
      at: "/uploads",
      from: "uploads",
      gzip: false
  end

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
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library(),
    length: 20_000_000

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug TymeslotWeb.Router
end
