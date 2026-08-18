defmodule TymeslotWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :tymeslot

  alias Plug.Static
  alias Tymeslot.Infrastructure.StaticCompressors

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

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  plug :serve_robots

  # Precompiled `*.zst` and `*.gz` siblings (written by `mix phx.digest`) are
  # served in preference to the plain asset, best-first. The list is empty
  # outside production, where the watchers rebuild the plain file but never its
  # siblings and a stale one would be served instead of fresh CSS.
  plug Plug.Static,
    at: "/",
    from: :tymeslot,
    encodings: StaticCompressors.encodings(Application.compile_env(:tymeslot, :environment)),
    # Files requested without a `?vsn=` fingerprint (esbuild's code-split
    # chunks, and anything referenced by a literal path) otherwise answer with
    # a bare `public`, which browsers treat as "revalidate every time". An
    # hour of freshness plus the ETag revalidation Plug.Static already sends
    # keeps them out of the critical path on repeat visits without risking a
    # stale asset for long.
    cache_control_for_etags: "public, max-age=3600, must-revalidate",
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

  # Resolved at runtime rather than through `compile_env`. The upload root is
  # the one endpoint setting the test suite varies per run: `config/test.exs`
  # suffixes it with `MIX_TEST_PARTITION` so partitioned suites cannot write
  # over each other. Pinned at compile time, that suffix makes every partition
  # but the one the build was compiled for abort at boot on a compile-env
  # mismatch, which rules out `mix test --partitions` entirely.
  #
  # `Plug.Static.init/1` is therefore called on first use instead of at compile
  # time, and its result cached in `:persistent_term` so the cost is paid once
  # per node rather than per request.
  plug :serve_uploads

  @upload_static_key {__MODULE__, :upload_static_opts}

  defp serve_uploads(conn, _opts) do
    Static.call(conn, upload_static_opts())
  end

  defp upload_static_opts do
    case :persistent_term.get(@upload_static_key, nil) do
      nil ->
        opts =
          Static.init(
            at: "/uploads",
            from: Application.get_env(:tymeslot, :upload_directory, "uploads"),
            gzip: false
          )

        :persistent_term.put(@upload_static_key, opts)
        opts

      opts ->
        opts
    end
  end

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    # `:phoenix_live_reload` is declared `only: :dev`, and Mix discards a
    # dependency's dev-only dependencies, so the module is invisible while this
    # endpoint is compiled from inside a parent application's build. It is
    # still present at boot there, supplied by that application's own dev
    # dependency, and `:plug_init_mode` is `:runtime` in dev, so the plug
    # resolves fine. Only the compiler cannot see it, hence the suppression
    # rather than a `Code.ensure_loaded?/1` guard, which would silently compile
    # live reloading out of every such build.
    @compile {:no_warn_undefined, Phoenix.LiveReloader}

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
  def request_log_level(%Plug.Conn{path_info: ["free-busy", _token]}), do: false
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
