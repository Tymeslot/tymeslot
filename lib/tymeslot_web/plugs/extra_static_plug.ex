defmodule TymeslotWeb.Plugs.ExtraStatic do
  @moduledoc """
  Serves static files from additional sources configured at runtime.

  External layers deployed alongside Core (overlays with their own OTP
  application) can contribute static assets without those files living in
  Core's `priv/static`. Each entry in `config :tymeslot, :extra_static_sources`
  is a `Plug.Static` options keyword list, e.g.

      config :tymeslot, :extra_static_sources, [
        [at: "/", from: {:other_app, "priv/static"}, gzip: true, only: ["images"]]
      ]

  The default is `[]`, so a standalone Core deployment is unaffected. Sources
  are tried in order after Core's own `Plug.Static`; the first one that serves
  the requested file halts the connection.

  Options are built with `Plug.Static.init/1` on first use and cached in
  `:persistent_term`, keyed by the raw source term — a changed config value
  simply produces a new cache entry. Invalid sources (e.g. a `from:` tuple
  naming an application absent from this deployment) are logged once and
  skipped, so requests degrade to 404s instead of raising.
  """

  @behaviour Plug

  require Logger

  alias Plug.Static

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    :tymeslot
    |> Application.get_env(:extra_static_sources, [])
    |> Enum.reduce_while(conn, fn source, conn ->
      case static_opts(source) do
        {:ok, opts} ->
          conn = Static.call(conn, opts)
          if conn.halted, do: {:halt, conn}, else: {:cont, conn}

        :skip ->
          {:cont, conn}
      end
    end)
  end

  defp static_opts(source) do
    key = {__MODULE__, source}

    case :persistent_term.get(key, nil) do
      nil ->
        result = build_opts(source)
        :persistent_term.put(key, result)
        result

      result ->
        result
    end
  end

  defp build_opts(source) do
    validate_from_app!(source)
    {:ok, Static.init(source)}
  rescue
    error ->
      Logger.warning("ExtraStatic: skipping invalid static source",
        source: inspect(source),
        reason: Exception.message(error)
      )

      :skip
  end

  # `from: {app, path}` is resolved via Application.app_dir/1 on every
  # request, which raises for applications not present in this deployment —
  # validate once here so a stale config entry degrades to 404s, not 500s.
  defp validate_from_app!(source) do
    case Keyword.fetch(source, :from) do
      {:ok, {app, _path}} when is_atom(app) ->
        _app_dir = Application.app_dir(app)
        :ok

      _no_app_tuple ->
        :ok
    end
  end
end
